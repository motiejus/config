#!/usr/bin/env python3

import argparse
import gzip
import re
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
    result = []
    offset = 0
    while offset < len(data):
        value, offset = read_varint(data, offset)
        result.append(value)
    return result


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
            if name not in {"inspect_points", "inspect_lines", "inspect_areas"}:
                continue
            for feature in layer_features:
                feature["_layer"] = name
                features.append(feature)
    return features, zooms


def one(features: list[dict], layer: str, osm_type: str, osm_id: str) -> dict:
    matches = [
        feature for feature in features
        if feature["_layer"] == layer
        and feature.get("osm_type") == osm_type
        and feature.get("osm_id") == osm_id
    ]
    assert matches, f"missing {layer} {osm_type}/{osm_id}"
    assert all(isinstance(feature["osm_id"], str) for feature in matches)
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
    process_source = args.process.read_text(encoding="utf-8")
    for lifecycle_value in (
        "abandoned", "closed", "demolished", "destroyed", "disused", "proposed", "razed", "removed"
    ):
        assert f"{lifecycle_value} = true" in process_source
    expected_highways = {
        "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
        "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
        "residential", "living_street", "service", "pedestrian", "track", "road",
        "path", "footway", "cycleway", "bridleway", "steps", "corridor",
    }
    lua_allowlist = process_source[process_source.index("local usable_highways"):
                                   process_source.index("local function current_object")]
    assert set(re.findall(r"\b([a-z_]+) = true", lua_allowlist)) == expected_highways
    index_source = (args.process.parent / "index.html").read_text(encoding="utf-8")
    client_allowlist = index_source[index_source.index("const roadDirectionHighways"):
                                    index_source.index("function isRoadDirectionCandidate")]
    assert set(re.findall(r'"([a-z_]+)"', client_allowlist)) == expected_highways, (
        "tile and client road-direction allowlists have drifted"
    )
    with tempfile.TemporaryDirectory(prefix="mapgames-inspector-fixture-") as temporary:
        temporary = Path(temporary)
        pbf = temporary / "inspector.osm.pbf"
        mbtiles = temporary / "inspector.mbtiles"
        subprocess.run([args.osmium, "cat", args.fixture, "-o", pbf], check=True)
        subprocess.run([
            args.tilemaker, "--quiet", "--input", pbf, "--output", mbtiles,
            "--config", args.config, "--process", args.process,
            "--bbox", "24.99,54.99,25.02,55.02", "--threads", "2",
        ], check=True)
        features, zooms = decode_features(mbtiles)
        with sqlite3.connect(mbtiles) as connection:
            metadata = dict(connection.execute("SELECT name, value FROM metadata").fetchall())

    assert zooms == {15, 16}
    assert "configured search-family destinations" in metadata.get("description", "")
    expected_destinations = {
        "103": ("coffee", "cafe"), "127": ("coffee", "cafe"),
        "140": ("coffee", "restaurant"), "141": ("coffee", "coffee_shop"),
        "142": ("hospital", "hospital"), "143": ("hospital", "hospital"),
        "144": ("supermarket", "supermarket"), "145": ("fuel", "fuel"),
    }
    for osm_id, (service, kind) in expected_destinations.items():
        destination = one(features, "inspect_points", "node", osm_id)
        assert destination.get("search_service") == service
        assert destination.get("kind") == kind
    # A disused café is still inspectable but must carry its real lifecycle
    # status so the client can mark it; ordinary matches stay "active".
    assert one(features, "inspect_points", "node", "127").get("status") == "disused", (
        "a lifecycle-inactive destination must be marked, not silently active"
    )
    assert one(features, "inspect_points", "node", "103").get("status") == "active"
    for osm_id in ("119", "120", "122", "123", "133", "146", "147", "148", "149", "190"):
        absent(features, "node", osm_id)
    road = one(features, "inspect_lines", "way", "301")
    assert road.get("category") == "transport" and road.get("highway") == "path"
    assert road.get("oneway") == "yes" and road.get("destination") == "Old town"
    assert road.get("foot") == "private" and road.get("surface") == "ground"
    steps = one(features, "inspect_lines", "way", "306")
    assert steps.get("highway") == "steps" and steps.get("kind") == "steps"
    for osm_id in ("304", "305", "309", "310", "311", "312", "313", "314", "315"):
        absent(features, "way", osm_id)
    assert {feature["_layer"] for feature in features} <= {
        "inspect_points", "inspect_lines", "inspect_areas"
    }
    assert all(
        feature.get("search_service") in {"coffee", "hospital", "supermarket", "fuel"}
        or feature.get("category") == "transport"
        for feature in features
    )
    generate_source = (args.process.parent / "generate.py").read_text(encoding="utf-8")
    inspector_metadata = generate_source[generate_source.index('"inspector": {'):
                                         generate_source.index('"osm_attribution"')]
    assert '"schema_version": 4' in inspector_metadata
    assert '"status": ["active", "abandoned", "closed", "disused", "proposed", "removed"]' in inspector_metadata
    assert '"search_service": ["coffee", "hospital", "supermarket", "fuel"]' in inspector_metadata
    assert '"cafe", "restaurant", "coffee_shop", "hospital"' in inspector_metadata
    assert '"path", "footway", "cycleway", "bridleway", "steps", "corridor"' in inspector_metadata
    assert '"destination": {' in inspector_metadata and '"road": {' in inspector_metadata
    assert '"foot_access"' not in inspector_metadata, (
        "metadata advertises a normalized field that the narrow inspector never emits"
    )
    # Routing must drop the same lifecycle-inactive objects the inspector marks,
    # and the two lifecycle vocabularies must not drift apart.
    assert "if not object_is_current(source_properties):" in generate_source, (
        "lifecycle-inactive destinations must be excluded from the routable place set"
    )
    generate_lifecycle = set(re.findall(
        r'"([a-z]+)"',
        generate_source[generate_source.index("LIFECYCLE_KEYS = ("):
                        generate_source.index("def object_is_current")],
    ))
    lua_lifecycle = set(re.findall(
        r'"([a-z]+)"',
        process_source[process_source.index("local lifecycle_keys = {"):
                       process_source.index("local former_highways")],
    ))
    assert generate_lifecycle == lua_lifecycle == {
        "abandoned", "closed", "demolished", "destroyed",
        "disused", "proposed", "razed", "removed",
    }, "routing and inspector lifecycle vocabularies have drifted"
    print(f"narrow inspector fixture OK ({len(features)} encoded tile features)")


if __name__ == "__main__":
    main()
