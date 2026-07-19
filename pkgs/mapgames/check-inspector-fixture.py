#!/usr/bin/env python3

import argparse
import gzip
import sqlite3
import struct
import subprocess
import tempfile
from pathlib import Path
import zlib


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7


def protobuf_fields(data: bytes):
    offset = 0
    while offset < len(data):
        key, offset = read_varint(data, offset)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, offset = read_varint(data, offset)
        elif wire == 1:
            value, offset = data[offset : offset + 8], offset + 8
        elif wire == 2:
            length, offset = read_varint(data, offset)
            value, offset = data[offset : offset + length], offset + length
        elif wire == 5:
            value, offset = data[offset : offset + 4], offset + 4
        else:
            raise AssertionError(f"unsupported protobuf wire type {wire}")
        yield number, wire, value


def packed_varints(data: bytes) -> list[int]:
    values = []
    offset = 0
    while offset < len(data):
        value, offset = read_varint(data, offset)
        values.append(value)
    return values


def decode_value(data: bytes):
    for number, wire, value in protobuf_fields(data):
        if number == 1 and wire == 2:
            return value.decode("utf-8")
        if number == 2 and wire == 5:
            return struct.unpack("<f", value)[0]
        if number == 3 and wire == 1:
            return struct.unpack("<d", value)[0]
        if number in (4, 5, 6, 7) and wire == 0:
            return value
    return None


def decode_layer(data: bytes) -> tuple[str, list[dict]]:
    name = ""
    keys = []
    values = []
    encoded_features = []
    for number, wire, value in protobuf_fields(data):
        if number == 1 and wire == 2:
            name = value.decode("utf-8")
        elif number == 2 and wire == 2:
            encoded_features.append(value)
        elif number == 3 and wire == 2:
            keys.append(value.decode("utf-8"))
        elif number == 4 and wire == 2:
            values.append(decode_value(value))

    features = []
    for encoded in encoded_features:
        indexes = []
        geometry_type = None
        for number, wire, value in protobuf_fields(encoded):
            if number == 2 and wire == 2:
                indexes.extend(packed_varints(value))
            elif number == 3 and wire == 0:
                geometry_type = value
        assert len(indexes) % 2 == 0
        feature = {
            keys[indexes[index]]: values[indexes[index + 1]]
            for index in range(0, len(indexes), 2)
        }
        feature["_geometry_type"] = geometry_type
        features.append(feature)
    return name, features


def decode_features(database: Path) -> tuple[list[dict], set[int]]:
    features = []
    zooms = set()
    with sqlite3.connect(database) as connection:
        blobs = connection.execute("SELECT zoom_level, tile_data FROM tiles").fetchall()
    for zoom, blob in blobs:
        zooms.add(zoom)
        try:
            tile = gzip.decompress(blob)
        except gzip.BadGzipFile:
            tile = zlib.decompress(blob)
        for number, wire, layer in protobuf_fields(tile):
            if number != 3 or wire != 2:
                continue
            name, layer_features = decode_layer(layer)
            if name not in {"inspect_points", "inspect_lines", "inspect_areas", "hiking_routes"}:
                continue
            for feature in layer_features:
                feature["_layer"] = name
                features.append(feature)
    return features, zooms


def read_metadata(database: Path) -> dict[str, str]:
    with sqlite3.connect(database) as connection:
        return dict(connection.execute("SELECT name, value FROM metadata").fetchall())


def one(features: list[dict], layer: str, osm_type: str, osm_id: str) -> dict:
    matches = [
        feature for feature in features
        if feature["_layer"] == layer
        and feature.get("osm_type") == osm_type
        and feature.get("osm_id") == osm_id
    ]
    assert matches, f"missing {layer} {osm_type}/{osm_id}"
    assert all(isinstance(feature["osm_id"], str) for feature in matches), (
        f"osm_id for {osm_type}/{osm_id} was not encoded as an exact string"
    )
    return matches[0]


def absent(features: list[dict], osm_type: str, osm_id: str) -> None:
    matches = [
        feature for feature in features
        if feature.get("osm_type") == osm_type and feature.get("osm_id") == osm_id
    ]
    assert not matches, f"unexpected inspector feature {osm_type}/{osm_id}: {matches[0]}"


def main() -> None:
    parser = argparse.ArgumentParser()
    package = Path(__file__).resolve().parent
    parser.add_argument("--config", type=Path, default=package / "inspector.json")
    parser.add_argument("--fixture", type=Path, default=package / "testdata/inspector.osm")
    parser.add_argument("--osmium", default="osmium")
    parser.add_argument("--process", type=Path, default=package / "inspector.lua")
    parser.add_argument("--tilemaker", default="tilemaker")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="mapgames-inspector-fixture-") as temporary:
        temporary = Path(temporary)
        pbf = temporary / "inspector.osm.pbf"
        mbtiles = temporary / "inspector.mbtiles"
        subprocess.run([args.osmium, "cat", args.fixture, "-o", pbf], check=True)
        subprocess.run(
            [
                args.tilemaker,
                "--quiet",
                "--input", pbf,
                "--output", mbtiles,
                "--config", args.config,
                "--process", args.process,
                "--bbox", "24.99,54.99,25.02,55.02",
                "--threads", "2",
            ],
            check=True,
        )
        features, zooms = decode_features(mbtiles)
        metadata = read_metadata(mbtiles)

    assert zooms == {15, 16}, f"inspector archive was not native z15-16: {zooms}"
    assert metadata.get("description", "").startswith("High-zoom OpenStreetMap geometries")
    for scope in ("practical", "accessibility", "outdoor", "civic", "business", "tourism"):
        assert scope in metadata["description"], f"inspector description omits {scope} coverage"

    point = one(features, "inspect_points", "node", "101")
    assert point["_geometry_type"] == 1
    assert point.get("category") == "tourism" and point.get("kind") == "viewpoint"
    assert point.get("foot_access") == "permissive" and point.get("ele") == "188"

    disused = one(features, "inspect_points", "node", "102")
    assert disused.get("category") == "amenity" and disused.get("kind") == "toilets"
    assert disused.get("status") == "disused"

    cafe = one(features, "inspect_points", "node", "103")
    assert cafe.get("foot_access") == "restricted"
    assert cafe.get("opening_hours") == "Sa-Su 10:00-18:00"
    shop = one(features, "inspect_points", "node", "104")
    assert shop.get("category") == "retail" and shop.get("kind") == "clothes"

    conditional_only = one(features, "inspect_points", "node", "105")
    assert conditional_only.get("foot_access") == "conditional"
    denied_with_exception = one(features, "inspect_points", "node", "106")
    assert denied_with_exception.get("foot_access") == "conditional"
    assert denied_with_exception.get("locked") == "yes"
    foot_overrides_generic = one(features, "inspect_points", "node", "107")
    assert foot_overrides_generic.get("foot_access") == "allowed"
    night_restriction = one(features, "inspect_points", "node", "108")
    assert night_restriction.get("foot_access") == "conditional"
    foot_conditional = one(features, "inspect_points", "node", "124")
    assert foot_conditional.get("foot_access") == "conditional"

    unrelated_lifecycle = one(features, "inspect_points", "node", "109")
    assert unrelated_lifecycle.get("kind") == "cafe"
    assert unrelated_lifecycle.get("status") == "active"

    lifecycle_cases = {
        "110": ("retail", "books", "abandoned", "abandoned:shop"),
        "111": ("amenity", "bank", "closed", "closed:amenity"),
        "112": ("tourism", "hotel", "construction", "construction:tourism"),
        "113": ("building", "house", "removed", "demolished:building"),
        "114": ("historic", "castle", "removed", "destroyed:historic"),
        "115": ("business", "company", "disused", "disused:office"),
        "116": ("leisure", "park", "proposed", "proposed:leisure"),
        "117": ("building", "church", "removed", "razed:building"),
        "118": ("barrier", "gate", "removed", "removed:barrier"),
    }
    for osm_id, (category, kind, status, source_key) in lifecycle_cases.items():
        lifecycle = one(features, "inspect_points", "node", osm_id)
        assert (lifecycle.get("category"), lifecycle.get("kind"), lifecycle.get("status")) == (
            category, kind, status
        )
        assert lifecycle.get(source_key) == kind, f"missing copied lifecycle key {source_key}"
    assert one(features, "inspect_points", "node", "118").get("locked") == "yes"

    assert one(features, "inspect_points", "node", "119").get("kind") == "fountain"
    assert one(features, "inspect_points", "node", "120").get("kind") == "water_tower"
    assert one(features, "inspect_points", "node", "121").get("kind") == "yes"
    rail_crossing = one(features, "inspect_points", "node", "122")
    assert rail_crossing.get("category") == "crossing"
    assert rail_crossing.get("kind") == "level_crossing"
    assert rail_crossing.get("crossing:barrier") == "yes"
    assert rail_crossing.get("crossing:signals") == "yes"
    assert rail_crossing.get("tactile_paving") == "no"
    road_crossing = one(features, "inspect_points", "node", "123")
    assert road_crossing.get("category") == "crossing" and road_crossing.get("kind") == "crossing"
    assert road_crossing.get("crossing:markings") == "zebra"
    assert road_crossing.get("crossing:island") == "yes"

    assert one(features, "inspect_points", "node", "125").get("foot_access") == "unknown"
    assert one(features, "inspect_points", "node", "126").get("foot_access") == "unknown"
    object_lifecycle_cases = {
        "127": "disused",
        "128": "abandoned",
        "129": "proposed",
        "130": "active",
    }
    for osm_id, status in object_lifecycle_cases.items():
        assert one(features, "inspect_points", "node", osm_id).get("status") == status

    construction_crossing = one(features, "inspect_points", "node", "131")
    assert construction_crossing.get("category") == "crossing"
    assert construction_crossing.get("kind") == "crossing"
    assert construction_crossing.get("status") == "construction"
    disused_rail_crossing = one(features, "inspect_points", "node", "132")
    assert disused_rail_crossing.get("category") == "crossing"
    assert disused_rail_crossing.get("kind") == "level_crossing"
    assert disused_rail_crossing.get("status") == "disused"

    absent(features, "node", "190")
    absent(features, "node", "191")
    absent(features, "node", "192")

    path = one(features, "inspect_lines", "way", "301")
    assert path["_geometry_type"] == 2
    assert path.get("category") == "transport" and path.get("kind") == "path"
    assert path.get("foot_access") == "restricted"
    assert path.get("surface") == "ground"
    assert path.get("tracktype") == "grade2"
    assert path.get("trail_visibility") == "intermediate"

    area = one(features, "inspect_areas", "way", "302")
    assert area["_geometry_type"] == 3
    assert area.get("category") == "leisure" and area.get("kind") == "nature_reserve"
    assert area.get("foot_access") == "allowed"

    construction_road = one(features, "inspect_lines", "way", "304")
    assert construction_road.get("kind") == "primary"
    assert construction_road.get("status") == "construction"
    proposed_road = one(features, "inspect_lines", "way", "305")
    assert proposed_road.get("kind") == "path"
    assert proposed_road.get("status") == "proposed"
    steps = one(features, "inspect_lines", "way", "306")
    assert steps.get("kind") == "steps" and steps.get("step_count") == "87"

    protected = one(features, "inspect_areas", "way", "307")
    assert protected.get("category") == "protected" and protected.get("kind") == "protected_area"
    assert protected.get("protect_class") == "5"
    assert protected.get("protection_title") == "Landscape reserve"

    riverbank = one(features, "inspect_areas", "way", "308")
    assert riverbank.get("category") == "water" and riverbank.get("kind") == "riverbank"
    assert riverbank["_geometry_type"] == 3

    relation_area = one(features, "inspect_areas", "relation", "401")
    assert relation_area["_geometry_type"] == 3
    assert relation_area.get("kind") == "camp_site" and relation_area.get("fee") == "yes"

    route = one(features, "hiking_routes", "relation", "402")
    assert route["_geometry_type"] == 2
    assert route.get("category") == "route" and route.get("kind") == "hiking"
    assert route.get("network") == "lwn" and route.get("ref") == "MG1"
    assert route.get("osmc:symbol") == "red:white:red_bar"

    future_route = one(features, "hiking_routes", "relation", "403")
    assert future_route.get("kind") == "hiking" and future_route.get("status") == "proposed"
    assert future_route.get("proposed:route") == "hiking"

    former_route = one(features, "hiking_routes", "relation", "404")
    assert former_route.get("kind") == "walking" and former_route.get("status") == "removed"

    assert {feature["_layer"] for feature in features} == {
        "inspect_points", "inspect_lines", "inspect_areas", "hiking_routes"
    }
    print(f"inspector fixture OK ({len(features)} encoded tile features)")


if __name__ == "__main__":
    main()
