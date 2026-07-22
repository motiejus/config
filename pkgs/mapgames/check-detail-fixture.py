#!/usr/bin/env python3

import argparse
import gzip
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
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
        tag_indexes = []
        geometry_type = None
        for number, wire, value in protobuf_fields(encoded):
            if number == 2 and wire == 2:
                tag_indexes.extend(packed_varints(value))
            elif number == 3 and wire == 0:
                geometry_type = value
        assert len(tag_indexes) % 2 == 0
        feature = {
                keys[tag_indexes[index]]: values[tag_indexes[index + 1]]
                for index in range(0, len(tag_indexes), 2)
        }
        feature["_geometry_type"] = geometry_type
        features.append(feature)
    return name, features


def decode_detail_features(database: Path) -> list[dict]:
    result = []
    with sqlite3.connect(database) as connection:
        blobs = connection.execute(
            "SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles"
        ).fetchall()
    for zoom, column, row, blob in blobs:
        try:
            tile = gzip.decompress(blob)
        except gzip.BadGzipFile:
            tile = zlib.decompress(blob)
        for number, wire, layer in protobuf_fields(tile):
            if number == 3 and wire == 2:
                name, features = decode_layer(layer)
                if name in (
                    "building_details", "poi_details", "micro_details", "transit_details",
                    "street_details", "water_details",
                ):
                    for feature in features:
                        feature["_layer"] = name
                        feature["_tile"] = (zoom, column, row)
                        result.append(feature)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    package = Path(__file__).resolve().parent
    parser.add_argument("--config", type=Path, default=package / "detail.json")
    parser.add_argument("--fixture", type=Path, default=package / "testdata/detail.osm")
    parser.add_argument("--index", type=Path, default=package / "index.html")
    parser.add_argument("--osmium", default="osmium")
    parser.add_argument("--process", type=Path, default=package / "detail.lua")
    parser.add_argument("--tilemaker", default="tilemaker")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mapgames-detail-fixture-") as temporary:
        temporary = Path(temporary)
        pbf = temporary / "detail.osm.pbf"
        mbtiles = temporary / "detail.mbtiles"
        transit = temporary / "transit.geojson"
        transit.write_text(
            json.dumps({
                "type": "FeatureCollection",
                "features": [{
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [25.005, 55.005]},
                    "properties": {
                        "display_tier": 16,
                        "kind": "stop",
                        "mode_bus": 1,
                        "mode_count": 2,
                        "mode_tram": 1,
                        "name": "Tile multimodal fixture",
                        "primary_mode": "tram",
                        "rank": 28,
                    },
                }],
            }) + "\n",
            encoding="utf-8",
        )
        config = json.loads(args.config.read_text(encoding="utf-8"))
        config["layers"]["transit_details"]["source"] = str(transit)
        config_path = temporary / "detail.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        subprocess.run(
            [args.osmium, "cat", args.fixture, "-o", pbf],
            check=True,
        )
        subprocess.run(
            [
                args.tilemaker,
                "--quiet",
                "--input", pbf,
                "--output", mbtiles,
                "--config", config_path,
                "--process", args.process,
                "--bbox", "24.99,54.99,25.02,55.02",
                "--threads", "2",
            ],
            check=True,
        )
        features = decode_detail_features(mbtiles)

    buildings = [feature for feature in features if feature["_layer"] == "building_details"]
    pois = [feature for feature in features if feature["_layer"] == "poi_details"]
    micros = [feature for feature in features if feature["_layer"] == "micro_details"]
    waters = [feature for feature in features if feature["_layer"] == "water_details"]
    transits = [feature for feature in features if feature["_layer"] == "transit_details"]
    street_details = [
        feature for feature in features if feature["_layer"] == "street_details"
    ]

    assert transits and all(feature.get("mode_count") == 2 for feature in transits), (
        "transit mode_count was dropped while encoding the vector tiles"
    )

    assert any(
        feature.get("housenumber") == "42A" and feature.get("kind") == "address"
        for feature in buildings
    ), "closed address-only area was not emitted as kind=address"
    assert not any(
        feature.get("housenumber") == "1-9" for feature in buildings
    ), "open interpolation way was incorrectly emitted"
    assert any(
        feature.get("name:en") == "English-only Hall" and "name" not in feature
        for feature in buildings
    ), "localized-only proper name was lost"
    assert any(
        feature.get("housename:lt") == "Tik lietuviškas namas"
        and "housename" not in feature
        for feature in buildings
    ), "localized-only house name was lost"

    hospital = [feature for feature in pois if feature.get("name:en") == "General Hospital"]
    assert hospital and all(
        feature.get("class") == "health"
        and feature.get("kind") == "hospital"
        and feature.get("display_tier") == 15
        for feature in hospital
    ), "multi-tag hospital did not resolve once to major health"
    hospital_building = [
        feature for feature in buildings if feature.get("housenumber") == "12"
    ]
    assert hospital_building and all(
        feature.get("has_poi") == 1
        and not any(key in feature for key in ("name", "name:lt", "name:en"))
        for feature in hospital_building
    ), "building+POI proper name was not suppressed while retaining its address"

    assert any(
        feature.get("name") == "Hotel with dining"
        and feature.get("class") == "lodging"
        and feature.get("display_tier") == 16
        for feature in pois
    ), "lodging did not win over a secondary restaurant tag"
    assert not any(
        feature.get("name") == "Hotel with dining" and feature.get("class") == "food"
        for feature in pois
    ), "multi-tag hotel emitted a second food feature"
    assert any(
        feature.get("name") == "Fuel shop"
        and feature.get("class") == "retail"
        and feature.get("kind") == "convenience"
        and feature.get("display_tier") == 17
        for feature in pois
    ), "retail did not win over a secondary fuel tag"

    generic_playgrounds = [
        feature for feature in pois
        if feature.get("name:lt") == "Žaidimų aikštelė"
        and feature.get("name:en") == "Playground"
    ]
    assert generic_playgrounds, "unnamed playground lost its localized generic name"
    assert any(
        feature.get("display_tier") == 17 and "access" not in feature
        for feature in generic_playgrounds
    ), "unknown playground access was incorrectly presented as known public access"
    assert any(
        feature.get("access") == "customers" and feature.get("display_tier") == 18
        for feature in generic_playgrounds
    ), "customer-only playground was not delayed to z18"
    assert any(
        feature.get("access") == "public" and feature.get("display_tier") == 17
        for feature in generic_playgrounds
    ), "explicitly public playground was not retained at z17"
    assert any(
        feature.get("name") == "Residents' yard"
        and feature.get("access") == "private"
        and feature.get("display_tier") == 18
        for feature in pois
    ), "private playground was not delayed to z18"

    assert any(
        feature.get("brand") == "Brand-only office"
        and feature.get("class") == "business"
        and feature.get("display_tier") == 18
        for feature in pois
    ), "brand-only office fallback was lost"
    assert any(
        feature.get("operator") == "Operator-only carpenter"
        and feature.get("class") == "business"
        and feature.get("display_tier") == 18
        for feature in pois
    ), "operator-only craft fallback was lost"
    assert any(
        feature.get("name") == "Relation museum"
        and feature.get("class") == "culture"
        and feature.get("display_tier") == 15
        for feature in pois
    ), "relation-tagged multipolygon POI was lost"

    duplicate_relation = [
        feature for feature in pois if feature.get("name") == "Duplicate-tag museum"
    ]
    assert duplicate_relation, "duplicate-tag relation fixture was lost entirely"
    copies_per_tile = {}
    for feature in duplicate_relation:
        copies_per_tile[feature["_tile"]] = copies_per_tile.get(feature["_tile"], 0) + 1
    assert max(copies_per_tile.values()) == 1, (
        "same-tag relation and member emitted duplicate POIs in one tile: "
        f"{copies_per_tile}"
    )

    expected_micro_classes = {
        "toilets",
        "bicycle_parking",
        "compressed_air",
        "shelter",
        "recycling",
        "information",
        "defibrillator",
        "life_ring",
        "emergency_entrance",
        "fountain",
    }
    assert {feature.get("class") for feature in micros} == expected_micro_classes, (
        "micro fixture taxonomy mismatch: "
        f"{sorted({feature.get('class') for feature in micros})}"
    )
    assert all(feature.get("display_tier") == 18 for feature in micros), (
        "ordinary micro detail escaped its z18 display tier"
    )
    assert waters and all(
        feature.get("class") == "drinking_water" and feature.get("display_tier") == 15
        for feature in waters
    ), "dedicated water source contains a non-potable or wrongly tiered feature"
    assert any(
        feature.get("class") == "drinking_water" and feature["_tile"][0] == 15
        for feature in waters
    ), "potable water was not physically encoded in z15 source tiles"
    assert any(
        feature.get("class") == "drinking_water"
        and feature.get("name") == "Public trail tap"
        for feature in waters
    ), "named potable water lost its proper name in the dedicated source"
    assert not any(
        feature["_tile"][0] == 15
        for feature in micros
    ), "ordinary micro detail escaped into z15 source tiles"
    assert all(feature.get("_geometry_type") == 1 for feature in micros + waters), (
        "micro detail must remain point/centroid geometry"
    )
    assert any(
        feature.get("class") == "toilets" and "access" not in feature
        for feature in micros + waters
    ), "unknown toilet access was incorrectly presented as public"
    assert any(
        feature.get("class") == "toilets"
        and feature.get("name") == "Public WC"
        and feature.get("access") == "public"
        for feature in micros + waters
    ), "explicitly public toilet was lost or mis-normalized"
    assert not any(
        feature.get("name") in {
            "Private WC",
            "Transit shelter",
            "Untyped shelter",
            "Recycling container",
            "Information board",
            "Residents bicycle parking",
            "Destination toilet",
            "Customer-only AED",
        }
        for feature in micros
    ), "restricted or explicitly excluded micro detail was emitted"
    assert any(
        feature.get("class") == "bicycle_parking"
        and feature.get("name") == "Open bicycle rack"
        for feature in micros
    ), "open bicycle-parking way was not retained as a representative point"
    assert all(
        any(key in feature for key in ("name", "name:lt", "name:en"))
        for feature in micros if feature.get("class") == "fountain"
    ), "unnamed fountain was emitted"
    assert any(
        feature.get("class") == "fountain"
        and feature.get("name:lt") == "Vardinis fontanas"
        and "name" not in feature
        for feature in micros
    ), "localized-only named fountain was lost"
    assert any(
        feature.get("class") == "defibrillator" and feature.get("name") == "AED toilet"
        for feature in micros
    ) and not any(
        feature.get("class") == "toilets" and feature.get("name") == "AED toilet"
        for feature in micros
    ), "emergency marker did not win micro multi-tag precedence"
    assert any(
        feature.get("name") == "Named bicycle shop" and feature.get("class") == "retail"
        for feature in pois
    ) and not any(
        feature.get("name") == "Named bicycle shop" for feature in micros
    ), "accepted POI also emitted a duplicate micro marker"
    assert not any(
        feature.get("name") in {"Disabled restaurant", "Lifecycle-prefixed restaurant"}
        for feature in pois
    ), "truthy lifecycle-disabled POI was emitted"
    assert not any(
        feature.get("name") == "Disabled toilet" for feature in micros
    ), "truthy lifecycle-disabled micro utility was emitted"
    assert not any(
        feature.get("name") == "Lifecycle-prefixed recycling" for feature in micros
    ), "lifecycle-prefixed micro utility was emitted"
    assert not any(
        feature.get("name") == "Non-potable tap" for feature in micros + waters
    ), "drinking_water=no was incorrectly presented as potable water"
    assert any(
        feature.get("name") == "False-lifecycle restaurant"
        and feature.get("class") == "food"
        for feature in pois
    ), "explicit lifecycle=no incorrectly disabled an active POI"
    assert any(
        feature.get("name") == "False-lifecycle toilet"
        and feature.get("class") == "toilets"
        for feature in micros
    ), "explicit lifecycle=0 incorrectly disabled an active micro utility"
    assert any(
        feature.get("name") == "False-literal toilet"
        and feature.get("class") == "toilets"
        for feature in micros
    ), "explicit lifecycle=false incorrectly disabled an active micro utility"
    assert not any(
        feature.get("name") in {"Disabled building restaurant", "Demolished named building"}
        for feature in pois + buildings
    ), "lifecycle-disabled proper name leaked through POI/building fallback"
    disabled_building_address = [
        feature for feature in buildings if feature.get("housenumber") == "101"
    ]
    assert disabled_building_address and all(
        not any(key in feature for key in ("name", "name:lt", "name:en"))
        and feature.get("has_poi") is None
        for feature in disabled_building_address
    ), "disabled building address was lost or incorrectly marked as an active POI"
    assert any(
        feature.get("class") == "bicycle_parking" and "access" not in feature
        for feature in micros
    ) and any(
        feature.get("class") == "bicycle_parking" and feature.get("access") == "public"
        for feature in micros
    ), "unnamed secondary micro feature or explicit-public bicycle parking was lost"
    micro_building = [
        feature for feature in buildings if feature.get("housenumber") == "99"
    ]
    assert micro_building and all(
        feature.get("has_poi") == 1
        and not any(key in feature for key in ("name", "name:lt", "name:en"))
        for feature in micro_building
    ), "micro-tagged building name was not suppressed while retaining address"
    assert any(
        feature.get("class") == "recycling"
        and feature.get("name") == "Relation recycling centre"
        for feature in micros
    ), "relation-only micro area was lost"

    assert {feature.get("class") for feature in street_details} == {"bench", "tree"}, (
        f"street-detail fixture taxonomy mismatch: {street_details}"
    )
    assert any(
        feature.get("class") == "bench" and feature.get("display_tier") == 17
        for feature in street_details
    ), "bench was not retained at its z17 presentation tier"
    assert any(
        feature.get("class") == "tree" and feature.get("display_tier") == 18
        for feature in street_details
    ), "individual tree was not delayed to z18"
    assert all(feature.get("_geometry_type") == 1 for feature in street_details), (
        "street detail must remain point geometry"
    )
    assert not any(
        feature.get("name") in {"Private bench", "Removed tree"}
        for feature in street_details
    ), "restricted bench or lifecycle-disabled tree was emitted"

    index = args.index.read_text(encoding="utf-8")
    public_playground_color = (
        '["all", ["==", ["get", "class"], "playground"], '
        '["==", ["get", "access"], "public"]],\n'
        '            "#2f6248"'
    )
    assert public_playground_color in index, (
        "playground color must require explicit public access; unknown/private/"
        "customer playgrounds stay neutral"
    )
    assert '"icon-image": "mapgames-playground"' in index, (
        "playgrounds need a dedicated swing-set pictogram, not the school sprite"
    )
    assert 'registerIcon("mapgames-playground"' in index
    assert "if (!map.hasImage(name))" in index, (
        "custom icon registration needs a synchronous runtime contract"
    )
    assert "The upstream `school` sprite" in index, (
        "the semantically wrong pinned school artwork must stay documented"
    )
    assert 'playgroundIconLayer("detail-playground-open-icons", 17, 16)' in index, (
        "open/unknown playground icons must appear at z16 ahead of their names"
    )
    assert 'playgroundIconLayer("detail-playground-restricted-icons", 18, 18)' in index, (
        "restricted playground icons must wait for the restriction label at z18"
    )
    assert 'streetIconLayer("detail-bench-icons", "bench", 17' in index, (
        "recognizable bench sprite must appear from z17"
    )
    assert 'streetIconLayer("detail-tree-icons", "tree", 18, "park"' in index, (
        "recognizable individual-tree sprite must remain z18-only"
    )
    street_icon_style = index[
        index.index('addBelowBaseLabels(streetIconLayer("detail-tree-icons"'):
        index.index('addBelowBaseLabels({\n          id: "detail-micro-names"')
    ]
    assert "icon-allow-overlap" not in street_icon_style, (
        "dense bench/tree icons must remain collision-aware"
    )
    assert index.count('id: "detail-micro-') == 2, "expected marker and optional-name micro layers"
    assert index.count('"source-layer": details.layers.micro_details') == 2, (
        "ordinary micro layers must use the curated micro source"
    )
    assert index.count('"source-layer": details.layers.water_details') == 3, (
        "potable-water dot, badge, and optional name must use the dedicated source"
    )
    utility_icons = {
        "toilets": "toilets",
        "bicycle_parking": "mapgames-bicycle",
        "compressed_air": "mapgames-air",
        "shelter": "mapgames-shelter",
        "recycling": "mapgames-recycling",
        "information": "mapgames-information",
        "defibrillator": "mapgames-aed",
        "life_ring": "mapgames-life-ring",
        "emergency_entrance": "mapgames-emergency",
        "fountain": "mapgames-fountain",
    }
    for category, image in utility_icons.items():
        assert f'"{category}", "{image}"' in index, (
            f"micro utility {category} needs a recognizable shape-first icon"
        )
    for cryptic in ('"DVIR."', '"PAST."', '"SKUB."', '"TROL."', '"TBUS"'):
        assert cryptic not in index, f"cryptic map abbreviation survived: {cryptic}"
    micro_style = index[index.index('id: "detail-micro-names"'):index.index('addBelowBaseLabels(poiLayer("detail-poi-micro"')]
    assert micro_style.count("minzoom: 18") == 3, (
        "ordinary micro and optional water-name styles must be absent below z18"
    )
    assert "text-allow-overlap" not in micro_style and "text-ignore-placement" not in micro_style, (
        "micro labels must remain collision-aware"
    )
    water_style = index[index.index('id: "detail-water-names"'):index.index("function discardInspectorLayers")]
    assert 'minzoom: 15' in water_style and 'minzoom: 16' in water_style, (
        "potable water needs a z15 dot and an explicit badge from z16"
    )
    assert water_style.count('["==", ["get", "class"], "drinking_water"]') == 2, (
        "dedicated water layers must not style unrelated micro utilities"
    )
    assert '"text-allow-overlap": true' in water_style, (
        "the compact H₂O badge must not disappear due to label collisions"
    )
    assert 'id: "detail-water-names"' in water_style and 'minzoom: 18' in water_style, (
        "named potable water needs a collision-aware z18 label"
    )
    assert '["!=", ["get", "class"], "drinking_water"]' in micro_style, (
        "potable water must not receive a duplicate generic micro marker"
    )

    basemap_lua = (args.process.parent / "basemap.lua").read_text(encoding="utf-8")
    assert 'amenity=bench' not in basemap_lua and 'Attribute("kind", "bench")' not in basemap_lua, (
        "benches must have one owner (details.pmtiles), not duplicate basemap/detail icons"
    )
    basemap_json = json.loads((args.process.parent / "basemap.json").read_text(encoding="utf-8"))
    assert "pois" not in basemap_json["layers"], (
        "empty generic basemap POI source-layer must not survive after detail takes ownership"
    )
    assert 'baseLayers.findIndex(layer => layer.id === "pois")' in index
    for service in ("coffee", "hospital", "supermarket", "fuel"):
        assert f'"{service}", "mapgames-{service}"' in index, (
            f"{service} service needs a non-colour silhouette at z16+"
        )
    assert index.count('id: "places-service-icons"') == 1
    assert 'id: `places-${service.id}-icon`' not in index, (
        "per-service icon layers make symbol-sort-key priority ineffective across services"
    )
    service_icon_style = index[index.index('id: "places-service-icons"'):index.index('function refreshControls')]
    assert 'minzoom: Math.max(placeDisplayMinZoom, metadata.places.min_data_zoom)' in service_icon_style
    assert '"icon-allow-overlap": true' in service_icon_style
    assert '"icon-ignore-placement": true' in service_icon_style
    priority = index[index.index("const serviceIconPriority"):
                     index.index("const inspectorHitLayerIds")]
    assert priority.index("coffee: 10") < priority.index("supermarket: 20")
    assert priority.index("supermarket: 20") < priority.index("fuel: 30")
    assert priority.index("fuel: 30") < priority.index("hospital: 40"), (
        "persistent service silhouettes need deterministic safety-first overpaint"
    )
    # The PAGD civil-protection classes (priedanga, kas) are safety-critical and
    # must overpaint on top, each with its own official sign -- distinct from the
    # house-shaped micro-detail "mapgames-shelter" utility icon asserted above.
    assert (
        priority.index("hospital: 40")
        < priority.index("priedanga: 50")
        < priority.index("kas: 60")
    ), "civil-protection classes must overpaint above every other service"
    assert (
        '"priedanga", "mapgames-priedanga"' in index
        and '"kas", "mapgames-kas"' in index
    ), "priedanga/kas need their own symbols in the z>=14 icon match"
    # Those symbols are the official PAGD signs, loaded as static raster assets.
    assert (
        '"mapgames-priedanga", "assets/priedanga.png"' in index
        and '"mapgames-kas", "assets/kas.png"' in index
    ), "priedanga/kas symbols must load the official PAGD sign assets"
    assert "...Object.entries(serviceIconPriority).flat(), 0" in service_icon_style, (
        "symbol overpaint does not use the shared service priority"
    )
    assert '["in", ["get", "service"], ["literal", []]]' in service_icon_style
    assert 'map.setFilter("places-service-icons",' in index
    # The z>=14 detail icons intentionally show EVERY class (selected or not) so
    # you can see what is around; the low-zoom overview aggregates are what track
    # the enabled set.
    assert '["literal", metadata.services.map(service => service.id)]' in index, (
        "the detail icon layer must show all services, not only the enabled set"
    )
    icon_hit = index[index.index("function serviceIconFeaturesAt"):
                     index.index("function markerFeaturesAt")]
    assert "map.getZoom() < placeDisplayMinZoom" in icon_hit
    assert "map.queryRenderedFeatures(point, options)" in icon_hit
    assert "serviceIconPriority[right.properties.service]" in icon_hit
    assert "edgePadding" in icon_hit, "the visible icon edge is not a practical target"
    assert "const edgePadding = coarse ? 22 : 2;" in icon_hit, (
        "coarse category icons do not provide a 44 CSS-pixel target"
    )
    assert "const compare = exact.length" in icon_hit
    assert "priority(left, right) || distance(left) - distance(right)" in icon_hit, (
        "exact overlapping icons do not follow their painted priority"
    )
    assert "distance(left) - distance(right) || priority(left, right)" in icon_hit, (
        "padded icon fallback can select a farther high-priority service"
    )
    marker_hit = index[index.index("function markerFeaturesAt"):
                       index.index("function markerCandidateAt")]
    assert "return serviceIconFeaturesAt(point, coarse);" in marker_hit, (
        "a hidden underlying service circle can win before the visible top icon"
    )
    assert "placeLayerIds" not in marker_hit
    emergency_art = index[index.index('registerIcon("mapgames-emergency"'):index.index('registerIcon("mapgames-bicycle"')]
    hospital_art = index[index.index('registerIcon("mapgames-hospital"'):index.index('registerIcon("mapgames-coffee"')]
    assert "strokeRect" in emergency_art and "fillRect" not in emergency_art
    assert "fillRect" in hospital_art, "emergency entrance and hospital must not share a red cross"

    print(
        f"detail fixture passed ({len(buildings)} building/address and "
        f"{len(pois)} POI, {len(micros)} micro, and "
        f"{len(street_details)} street-detail encoded feature copies)"
    )


if __name__ == "__main__":
    main()
