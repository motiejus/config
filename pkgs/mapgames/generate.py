#!/usr/bin/env python3

import argparse
from contextlib import contextmanager
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time

from shapely.geometry import (
    box,
    mapping,
    shape,
)

from valhalla import get_config


TILE_MIN_ZOOM = 6
DESTINATION_MIN_ZOOM = 12
TILE_MAX_ZOOM = 14
# Place dots are displayed only in overzoomed street-level views. Encoding
# the same point set below the archive's maximum zoom only duplicates data;
# one canonical z14 tile pyramid supplies every displayed zoom.
PLACE_TILE_MIN_ZOOM = TILE_MAX_ZOOM
# Low-zoom fast-path (docs/lowzoom-fastpath.md): coarsen.py always builds a
# z10-grid skeleton. Serving that same artifact through z13 avoids the raw
# network's severe mobile draw cost at z11-13 without changing its grid or
# regeneration algorithm; raw reachable routing edges begin at z14.
COARSE_GRID_ZOOM = 10
SKELETON_SIMPLIFY_BELOW = COARSE_GRID_ZOOM + 1
COARSE_MAX_ZOOM = 13
RAW_NETWORK_MIN_ZOOM = COARSE_MAX_ZOOM + 1
# One MVT coordinate unit (tile extent 4096) at zoom z spans
# 360 / (4096 * 2**z) projected degrees — the grid every vertex is rounded
# to when the tile is encoded. Tilemaker scales the configured level by
# simplify_ratio**((simplify_below - 1) - z) at zoom z (tile_worker.cpp:438
# in the pinned 3.1.0), and both that scaling (ratio 2) and the coordinate
# unit double per zoom step down, so anchoring the level to one coordinate
# unit at COARSE_GRID_ZOOM makes the effective tolerance exactly one
# coordinate unit at every simplified zoom. The overzoomed z11-13 skeleton
# needs no further tilemaker simplification.
NETWORK_SIMPLIFY_LEVEL = 360 / (4096 * 2**COARSE_GRID_ZOOM)
# Low-zoom fast-path (docs/lowzoom-fastpath.md, owner-selected Variant B):
# the z10-encoder-grid skeleton serves z8-13, and the section 4.6
# short-chain-filtered subset (chains of z10-grid length >= N_drop kept)
# serves z6-7. GRID_ZOOM is fixed at 10 for both (coarser grids measured
# exhausted, section 4.6); N_drop = 64 grid units (~350 m ground) is the
# owner-accepted comparison value.
# COARSE_GRID_ZOOM must equal coarsen.py's GRID_ZOOM literal (the grid the
# skeleton is actually built on). Keep the grid independent of the serving
# handoff: changing COARSE_MAX_ZOOM must never silently change coarsen.py.
VARIANT_B_MAX_ZOOM = 7
VARIANT_B_N_DROP = 64

assert COARSE_GRID_ZOOM == 10, "must match coarsen.py GRID_ZOOM"
assert SKELETON_SIMPLIFY_BELOW == COARSE_GRID_ZOOM + 1
assert VARIANT_B_MAX_ZOOM < COARSE_GRID_ZOOM <= COARSE_MAX_ZOOM
assert RAW_NETWORK_MIN_ZOOM == COARSE_MAX_ZOOM + 1
assert RAW_NETWORK_MIN_ZOOM <= TILE_MAX_ZOOM

SERVICE_SPECS = (
    {
        "id": "coffee",
        "label": "Coffee & food",
        "description": "Cafes, coffee shops, and restaurants",
        "query": ("amenity=cafe", "amenity=restaurant", "shop=coffee"),
        "routes": (("walk", (5, 10, 20)),),
    },
    {
        "id": "hospital",
        "label": "Hospital",
        "description": "Hospitals reachable by car",
        "query": ("amenity=hospital", "healthcare=hospital"),
        "routes": (("drive", (15, 30, 45, 60)),),
    },
    {
        "id": "supermarket",
        "label": "Supermarket",
        "description": "Full-size supermarkets",
        "query": ("shop=supermarket",),
        "routes": (("walk", (10, 20)), ("drive", (10,))),
    },
    {
        "id": "fuel",
        "label": "Fuel station",
        "description": "Fuel stations reachable by car",
        "query": ("amenity=fuel",),
        "routes": (("drive", (10, 20)),),
    },
)

ROUTE_SPECS = tuple(
    {
        "service": service["id"],
        "mode": mode,
        "minutes": minutes,
    }
    for service in SERVICE_SPECS
    for mode, minutes in service["routes"]
)

def route_key(route: dict) -> str:
    return f"{route['service']}-{route['mode']}"


# Attribute keys of the unified network layer (docs/unified-access-layer.md
# section 1.1): one per requirement, `{service}_{mode}` with underscore.
# valhalla-expand.cc derives the same keys from the edges-<service>-<mode>.tsv
# dump filenames, so the two derivations (plus the step-3 checker's regex)
# stay lockstep only while every route key is exactly one lowercase word, one
# dash, one lowercase word. Validate that grammar here at import time — the
# check is static (module constants only), and failing before the expensive
# routing phase beats failing after it.
_ROUTE_KEY_GRAMMAR = re.compile(r"[a-z]+-[a-z]+")
REQUIREMENT_KEYS = tuple(f"{route['service']}_{route['mode']}" for route in ROUTE_SPECS)
for _route, _requirement_key in zip(ROUTE_SPECS, REQUIREMENT_KEYS, strict=True):
    _key = route_key(_route)
    if not _ROUTE_KEY_GRAMMAR.fullmatch(_key):
        raise RuntimeError(
            f"route key {_key!r} does not match the one-dash [a-z]+-[a-z]+ grammar"
            " that the dump-filename key derivation in valhalla-expand.cc assumes"
        )
    if _key.replace("-", "_") != _requirement_key:
        raise RuntimeError(
            f"route key {_key!r} does not derive requirement key {_requirement_key!r}"
        )
del _route, _requirement_key, _key

MODE_COSTING = {"walk": "pedestrian", "drive": "auto"}
CORRIDOR_BUFFER_METERS = {"walk": 12, "drive": 18}
DESTINATION_SOURCE_COLUMNS = (
    "minutes",
    "mode",
    "lookup_ids",
    "service",
)
PLACE_SOURCE_COLUMNS = (
    "amenity",
    "brand",
    "healthcare",
    "kind",
    "name",
    "osm_id",
    "osm_type",
    "osm_url",
    "place_id",
    "place_index",
    "service",
    "shop",
    "source_geometry",
)
# The inspect dialog needs only these human-facing fields, point coordinates,
# service identity, and a stable share ID. Keep its catalog separate from the
# tilemaker GeoJSON: shipping the latter exposed every OSM tag and made the
# browser parse several MiB on the first inspection. Entries are stored in
# place_index order, so the array position remains the compact lookup key
# carried by destination tiles; URLs use place_id instead.
PLACE_CATALOG_COLUMNS = (
    "addr:city",
    "addr:housenumber",
    "addr:postcode",
    "addr:street",
    "brand",
    "contact:phone",
    "kind",
    "name",
    "opening_hours",
    "phone",
    "place_id",
    "service",
)


@contextmanager
def timed(label: str):
    started = time.perf_counter()
    print(f"[mapgames] {label}...", flush=True)
    try:
        yield
    except Exception:
        elapsed = time.perf_counter() - started
        print(f"[mapgames] {label} failed after {elapsed:.2f}s", file=sys.stderr, flush=True)
        raise
    elapsed = time.perf_counter() - started
    print(f"[mapgames] {label}: {elapsed:.2f}s", flush=True)


def run(label: str, argv: list[object]) -> None:
    command = [str(arg) for arg in argv]
    print("+", " ".join(command), flush=True)
    with timed(label):
        subprocess.run(command, check=True)


def capture(label: str, argv: list[object]) -> str:
    command = [str(arg) for arg in argv]
    print("+", " ".join(command), flush=True)
    with timed(label):
        result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE)
    return result.stdout.strip()


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )


def feature_collection(features: list[dict], bbox: list[float]) -> dict:
    return {"type": "FeatureCollection", "bbox": bbox, "features": features}


def decode_osmium_id(feature_id: object):
    value = str(feature_id or "")
    if value.startswith("n") and value[1:].isdigit():
        return "node", int(value[1:])
    if value.startswith("a") and value[1:].isdigit():
        area_id = int(value[1:])
        if area_id % 2 == 0:
            return "way", area_id // 2
        return "relation", (area_id - 1) // 2
    return None, None


def services_for_properties(properties: dict) -> list[str]:
    services = []
    amenity = properties.get("amenity")
    shop = properties.get("shop")
    if amenity in ("cafe", "restaurant") or shop == "coffee":
        services.append("coffee")
    if amenity == "hospital" or properties.get("healthcare") == "hospital":
        services.append("hospital")
    if shop == "supermarket":
        services.append("supermarket")
    if amenity == "fuel":
        services.append("fuel")
    return services


def place_kind(service: str, properties: dict) -> str:
    if service == "coffee":
        if properties.get("amenity") == "restaurant":
            return "restaurant"
        if properties.get("amenity") == "cafe":
            return "cafe"
        return "coffee_shop"
    return service


def destination_layer_name(minutes: int) -> str:
    return f"destinations_{minutes}"


def destinations_filename(route: dict, minutes: int) -> str:
    return f"destinations-{route_key(route)}-{minutes}.geojson"


def common_tile_settings(name: str, description: str, minzoom: int = TILE_MIN_ZOOM) -> dict:
    return {
        "minzoom": minzoom,
        "maxzoom": TILE_MAX_ZOOM,
        "basezoom": TILE_MAX_ZOOM,
        "include_ids": False,
        "combine_below": TILE_MAX_ZOOM,
        "name": name,
        "version": "1.0.0",
        "description": description,
        "compress": "gzip",
        "filemetadata": {
            "tilejson": "3.0.0",
            "scheme": "xyz",
            "type": "overlay",
            "format": "pbf",
            "attribution": "© OpenStreetMap contributors, ODbL 1.0",
        },
    }


def edge_dump_filename(route: dict) -> str:
    return f"edges-{route_key(route)}.tsv"


def network_tile_config(work: Path) -> dict:
    # Three config layers, one MVT source-layer `network` via write_to
    # (docs/lowzoom-fastpath.md sections 2.3 and 4.6, Variant B): the raw
    # reachable routing edges at inspection zoom z14, the coarsen.py
    # z10-grid skeleton at z8-13, and its short-chain-filtered subset at
    # z6-7. Zoom-scaled generalization on the skeleton layers is bounded by
    # the tile encoder's coordinate grid (one MVT unit per generalized zoom,
    # z6-10; z11-13 overzoom that grid without further simplification; see
    # NETWORK_SIMPLIFY_LEVEL). The raw layer ships unsimplified.
    source_columns = sorted((*REQUIREMENT_KEYS, "g"))
    skeleton_simplify = {
        "simplify_below": SKELETON_SIMPLIFY_BELOW,
        "simplify_level": NETWORK_SIMPLIFY_LEVEL,
        "simplify_ratio": 2.0,
        "simplify_algorithm": "visvalingam",
    }
    return {
        "layers": {
            "network": {
                "minzoom": RAW_NETWORK_MIN_ZOOM,
                "maxzoom": TILE_MAX_ZOOM,
                "source": str(work / "network.geojson"),
                "source_columns": source_columns,
            },
            "network_lowzoom": {
                "minzoom": VARIANT_B_MAX_ZOOM + 1,
                "maxzoom": COARSE_MAX_ZOOM,
                "source": str(work / "network-lowzoom.geojson"),
                "source_columns": source_columns,
                "write_to": "network",
                **skeleton_simplify,
            },
            "network_lowzoom_z67": {
                "minzoom": TILE_MIN_ZOOM,
                "maxzoom": VARIANT_B_MAX_ZOOM,
                "source": str(work / "network-lowzoom-z67.geojson"),
                "source_columns": source_columns,
                "write_to": "network",
                **skeleton_simplify,
            },
        },
        "settings": common_tile_settings(
            "Mapgames unified access network",
            "Edge-attributed everyday-access bands for all services",
        ),
    }


def destination_tile_config(route: dict, work: Path) -> dict:
    return {
        "layers": {
            destination_layer_name(minutes): {
                "minzoom": DESTINATION_MIN_ZOOM,
                "maxzoom": TILE_MAX_ZOOM,
                "source": str(work / destinations_filename(route, minutes)),
                "source_columns": list(DESTINATION_SOURCE_COLUMNS),
            }
            for minutes in route["minutes"]
        },
        "settings": common_tile_settings(
            f"Mapgames {route_key(route)} destination lookup",
            "Reachable edge to destination-catalog lookup",
            DESTINATION_MIN_ZOOM,
        ),
    }


def places_tile_config(work: Path) -> dict:
    return {
        "layers": {
            "places": {
                "minzoom": PLACE_TILE_MIN_ZOOM,
                "maxzoom": TILE_MAX_ZOOM,
                "source": str(work / "places.geojson"),
                "source_columns": list(PLACE_SOURCE_COLUMNS),
                "combine_points": False,
            }
        },
        "settings": common_tile_settings(
            "Mapgames service destinations",
            "Cafes, restaurants, hospitals, supermarkets, and fuel stations",
            PLACE_TILE_MIN_ZOOM,
        ),
    }


def parse_bbox(value: str) -> tuple[float, float, float, float]:
    try:
        result = tuple(float(part) for part in value.split(","))
    except ValueError as error:
        raise argparse.ArgumentTypeError("bbox must contain four numbers") from error
    if len(result) != 4:
        raise argparse.ArgumentTypeError("bbox must be min_lon,min_lat,max_lon,max_lat")
    min_lon, min_lat, max_lon, max_lat = result
    if not all(math.isfinite(coordinate) for coordinate in result):
        raise argparse.ArgumentTypeError("bbox coordinates must be finite")
    if not (-180 <= min_lon <= 180 and -180 <= max_lon <= 180):
        raise argparse.ArgumentTypeError("bbox longitudes must be between -180 and 180")
    if not (-90 <= min_lat <= 90 and -90 <= max_lat <= 90):
        raise argparse.ArgumentTypeError("bbox latitudes must be between -90 and 90")
    if min_lon >= max_lon or min_lat >= max_lat:
        raise argparse.ArgumentTypeError("bbox minimums must be below maximums")
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pbf", type=Path, required=True)
    parser.add_argument("--bbox", type=parse_bbox, required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    parser.add_argument("--expansion-concurrency", type=int, required=True)
    parser.add_argument("--expansion-output-concurrency", type=int, required=True)
    parser.add_argument("--basemap-config", type=Path, required=True)
    parser.add_argument("--basemap-process", type=Path, required=True)
    parser.add_argument("--detail-config", type=Path, required=True)
    parser.add_argument("--detail-process", type=Path, required=True)
    parser.add_argument("--transit-tool", type=Path, required=True)
    parser.add_argument("--geojson-process", type=Path, required=True)
    parser.add_argument("--pmtiles-cli-version", required=True)
    parser.add_argument("--tilemaker-version", required=True)
    parser.add_argument("--valhalla-version", required=True)
    parser.add_argument("--expansion-helper", type=Path, required=True)
    parser.add_argument("--coarsen-tool", type=Path, required=True)
    parser.add_argument("--osm-source-url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def prepare_boundary(args: argparse.Namespace, work: Path):
    boundary_geojson_path = work / "lithuania-boundary.raw.geojson"
    country = box(*args.bbox)
    write_json(
        boundary_geojson_path,
        feature_collection(
            [
                {
                    "type": "Feature",
                    "properties": {"name": "Coverage bounds"},
                    "geometry": mapping(country),
                }
            ],
            list(args.bbox),
        ),
    )

    if country.is_empty:
        raise RuntimeError("coverage boundary is empty")
    country_bbox = list(country.bounds)
    return country, country_bbox


def prepare_places(args: argparse.Namespace, work: Path, country):
    places_pbf = work / "places.osm.pbf"
    raw_places_path = work / "places.raw.geojson"
    filters = [f"nwr/{query}" for service in SERVICE_SPECS for query in service["query"]]
    run(
        "filter service destinations",
        [
            "osmium",
            "tags-filter",
            "--remove-tags",
            "--output",
            places_pbf,
            args.pbf,
            *filters,
        ],
    )
    run(
        "export service destinations",
        [
            "osmium",
            "export",
            "--geometry-types=point,polygon",
            "--add-unique-id=type_id",
            "--attributes=version,timestamp",
            "--show-errors",
            "--stop-on-error",
            "--output",
            raw_places_path,
            places_pbf,
        ],
    )

    source = json.loads(raw_places_path.read_text(encoding="utf-8"))
    prepared = {service["id"]: [] for service in SERVICE_SPECS}
    seen_ids = set()
    for source_feature in source.get("features", []):
        source_id = str(source_feature.get("id") or "")
        source_geometry = source_feature.get("geometry")
        if not source_id or source_geometry is None:
            continue
        geometry = shape(source_geometry)
        if geometry.is_empty:
            continue
        point = geometry.representative_point()
        if not country.covers(point):
            continue
        source_properties = dict(source_feature.get("properties") or {})
        osm_type, osm_id = decode_osmium_id(source_id)
        for service in services_for_properties(source_properties):
            place_id = f"{service}:{source_id}"
            if place_id in seen_ids:
                continue
            properties = dict(source_properties)
            properties.update(
                {
                    "kind": place_kind(service, source_properties),
                    "place_id": place_id,
                    "service": service,
                    "source_geometry": source_geometry.get("type"),
                }
            )
            if osm_type is not None:
                properties.update(
                    {
                        "osm_type": osm_type,
                        "osm_id": osm_id,
                        "osm_url": f"https://www.openstreetmap.org/{osm_type}/{osm_id}",
                    }
                )
            feature = {
                "type": "Feature",
                "id": place_id,
                "geometry": {"type": "Point", "coordinates": [point.x, point.y]},
                "properties": properties,
            }
            prepared[service].append(
                ({"lon": point.x, "lat": point.y, "radius": 100}, feature)
            )
            seen_ids.add(place_id)

    for service, entries in prepared.items():
        entries.sort(key=lambda pair: (pair[0]["lon"], pair[0]["lat"], pair[1]["id"]))
        if not entries:
            raise RuntimeError(f"coverage region contains no {service} destinations")
    place_index = 0
    for service in SERVICE_SPECS:
        for _location, feature in prepared[service["id"]]:
            feature["properties"]["place_index"] = place_index
            place_index += 1
    return prepared


def place_catalog(features: list[dict]) -> list[dict]:
    result = []
    for expected_index, feature in enumerate(features):
        properties = feature["properties"]
        if properties.get("place_index") != expected_index:
            raise RuntimeError(
                f"place catalog feature {expected_index} has index "
                f"{properties.get('place_index')!r}"
            )
        entry = {
            key: properties[key]
            for key in PLACE_CATALOG_COLUMNS
            if key in properties
        }
        entry["lon"], entry["lat"] = feature["geometry"]["coordinates"]
        result.append(entry)
    return result


def write_expansion_requests(path: Path, route: dict, entries: list[tuple[dict, dict]]):
    with path.open("w", encoding="utf-8") as file:
        for index, (location, place_feature) in enumerate(entries, start=1):
            request_id = f"{index:06d}"
            max_minutes = max(route["minutes"])
            file.write(
                "\t".join(
                    [
                        request_id,
                        MODE_COSTING[route["mode"]],
                        f"{location['lon']:.17g}",
                        f"{location['lat']:.17g}",
                        str(max_minutes),
                        json.dumps(
                            {
                                "lookup_id": place_feature["properties"]["place_index"],
                                "place_id": place_feature["properties"]["place_id"],
                            },
                            ensure_ascii=False,
                            separators=(",", ":"),
                            sort_keys=True,
                        ),
                    ]
                )
                + "\n"
            )


def main() -> None:
    pipeline_started = time.perf_counter()
    args = parse_args()
    if args.concurrency <= 0:
        raise ValueError("concurrency must be positive")
    if args.expansion_concurrency <= 0:
        raise ValueError("expansion concurrency must be positive")
    if args.expansion_output_concurrency <= 0:
        raise ValueError("expansion output concurrency must be positive")

    work = Path.cwd() / "work"
    output = args.output.resolve()
    work.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)

    osm_timestamp = capture(
        "read OSM snapshot timestamp",
        ["osmium", "fileinfo", "-g", "header.option.osmosis_replication_timestamp", args.pbf],
    )

    with timed("prepare coverage boundary"):
        country, country_bbox = prepare_boundary(args, work)

    basemap_command = [
        "tilemaker",
        "--input",
        args.pbf,
        "--output",
        output / "lithuania.pmtiles",
        "--config",
        args.basemap_config,
        "--process",
        args.basemap_process,
        "--threads",
        args.concurrency,
    ]
    basemap_command.extend(["--bbox", ",".join(str(value) for value in args.bbox)])
    run("build lean vector basemap", basemap_command)

    transit_path = work / "transit-details.geojson"
    run(
        "canonicalize public transport stops",
        [
            sys.executable,
            args.transit_tool,
            "--bbox",
            ",".join(str(value) for value in args.bbox),
            "--input",
            args.pbf,
            "--output",
            transit_path,
            "--work",
            work,
        ],
    )
    detail_config = json.loads(args.detail_config.read_text(encoding="utf-8"))
    detail_config["layers"]["transit_details"]["source"] = str(transit_path)
    detail_config_path = work / "details.json"
    write_json(detail_config_path, detail_config)
    detail_command = [
        "tilemaker",
        "--input",
        args.pbf,
        "--output",
        output / "details.pmtiles",
        "--config",
        detail_config_path,
        "--process",
        args.detail_process,
        "--threads",
        args.concurrency,
    ]
    detail_command.extend(["--bbox", ",".join(str(value) for value in args.bbox)])
    run("build high-zoom building and address detail", detail_command)
    # tilemaker writes a valid but unclustered archive whose first z15 lookup
    # can require a multi-megabyte leaf-directory range. Reorder only this
    # new, unusually high-cardinality archive in place; the established
    # basemap/access/destination archives are already acceptably laid out.
    run(
        "cluster high-zoom detail PMTiles",
        ["pmtiles", "cluster", output / "details.pmtiles"],
    )

    with timed("prepare service locations"):
        prepared = prepare_places(args, work, country)

    tiles = work / "tiles"
    tiles.mkdir(exist_ok=True)
    with timed("write Valhalla configuration"):
        config = get_config(tile_extract="", tile_dir=tiles)
        # The pipeline reads only its unpacked graph tiles. Remove optional
        # /data/valhalla defaults so an unsandboxed build cannot accidentally
        # consume host traffic, admin, timezone, transit, landmark, or elevation
        # data and produce a different output for the same derivation.
        for key in (
            "tile_extract",
            "traffic_extract",
            "admin",
            "landmarks",
            "timezone",
            "transit_dir",
            "transit_feeds_dir",
        ):
            config["mjolnir"].pop(key, None)
        config.get("additional_data", {}).pop("elevation", None)
        config_path = work / "valhalla.json"
        write_json(config_path, config)

    run(
        "build Valhalla routing tiles",
        [
            "valhalla_build_tiles",
            "--config",
            config_path,
            "--concurrency",
            args.concurrency,
            args.pbf,
        ],
    )

    routed_counts = {}
    bbox_arg = ",".join(str(coordinate) for coordinate in country_bbox)
    for route in ROUTE_SPECS:
        key = route_key(route)
        entries = prepared[route["service"]]
        requests_path = work / f"expansion-{key}.tsv"
        write_expansion_requests(requests_path, route, entries)
        run(
            f"compute {key} native reverse expansion lines",
            [
                args.expansion_helper,
                config_path,
                requests_path,
                # Destination GeoJSON and the edge-interval dump are tilemaker
                # and merge-tool inputs only; keep them out of the published
                # output directory.
                work,
                args.expansion_concurrency,
                args.expansion_output_concurrency,
                ",".join(str(minutes) for minutes in route["minutes"]),
                bbox_arg,
                key,
                route["service"],
                route["mode"],
            ],
        )
        for _location, place_feature in entries:
            place_feature["properties"][f"{route['mode']}_routing_status"] = "routed"
        routed_counts[key] = len(entries)

    # Unified network (docs/unified-access-layer.md section 2.1): merge the
    # per-route edge-interval dumps into one work/network.geojson. The helper
    # derives each dump's attribute key from its filename
    # (requirement_key_from_dump in valhalla-expand.cc: edges-<service>-<mode>
    # .tsv -> <service>_<mode>); the module-scope grammar check next to
    # REQUIREMENT_KEYS guarantees that derivation lands exactly on the
    # authoritative keys.
    network_dumps = tuple(work / edge_dump_filename(route) for route in ROUTE_SPECS)
    run(
        "merge per-route edge dumps into unified network",
        [
            args.expansion_helper,
            "--merge-network",
            # network.geojson is a tilemaker input only (never published);
            # see "network.geojson is NOT published" in the design doc.
            work / "network.geojson",
            bbox_arg,
            *network_dumps,
        ],
    )

    # Low-zoom fast-path (docs/lowzoom-fastpath.md section 2.2): derive the
    # encoder-grid skeleton (z8-13 tiles) and the Variant-B short-chain-
    # filtered subset (z6-7 tiles) from the merged network. Both are work/
    # intermediates, never published, exactly like network.geojson.
    run(
        "derive low-zoom skeleton from unified network",
        [
            sys.executable,
            args.coarsen_tool,
            work / "network.geojson",
            work / "network-lowzoom.geojson",
            "--z67-out",
            work / "network-lowzoom-z67.geojson",
            "--n-drop",
            VARIANT_B_N_DROP,
        ],
    )

    place_features = [
        feature
        for service in SERVICE_SPECS
        for _location, feature in prepared[service["id"]]
    ]
    # The full GeoJSON is an encoder input, not a web API. The browser gets a
    # compact, index-addressed detail catalog without geometry wrappers or
    # hundreds of unrelated OSM tags.
    write_json(work / "places.geojson", feature_collection(place_features, country_bbox))
    write_json(output / "place-catalog.json", place_catalog(place_features))

    network_config_path = work / "access.json"
    write_json(network_config_path, network_tile_config(work))
    run(
        "build unified access PMTiles",
        [
            "tilemaker",
            "--quiet",
            "--bbox",
            bbox_arg,
            "--output",
            output / "access.pmtiles",
            "--config",
            network_config_path,
            "--process",
            args.geojson_process,
            "--threads",
            args.concurrency,
        ],
    )

    for route in ROUTE_SPECS:
        key = route_key(route)
        destination_config_path = work / f"destination-lookup-{key}.json"
        write_json(destination_config_path, destination_tile_config(route, work))
        destination_tile_name = f"destinations-{key}.pmtiles"
        run(
            f"build {key} click-lookup PMTiles",
            [
                "tilemaker",
                "--quiet",
                "--bbox",
                bbox_arg,
                "--output",
                output / destination_tile_name,
                "--config",
                destination_config_path,
                "--process",
                args.geojson_process,
                "--threads",
                args.concurrency,
            ],
        )

    places_config = work / "places.json"
    write_json(places_config, places_tile_config(work))
    run(
        "build service destination PMTiles",
        [
            "tilemaker",
            "--quiet",
            "--bbox",
            bbox_arg,
            "--output",
            output / "places.pmtiles",
            "--config",
            places_config,
            "--process",
            args.geojson_process,
            "--threads",
            args.concurrency,
        ],
    )

    # Phase-B group table (docs/lowzoom-fastpath.md section 3.2): the
    # attribute map of every group, listed in `g` order, read back from
    # work/network.geojson — the same single source that feeds the tiles,
    # never a second derivation. R-L5: `g` is a per-build index and must
    # never be persisted client-side across deploys; URL state stores
    # requirement keys/minutes, never group ids, and index.html + data
    # deploy atomically.
    with timed("read attribute-map groups for metadata"):
        network_features = json.loads(
            (work / "network.geojson").read_text(encoding="utf-8")
        )["features"]
        access_groups = []
        for index, feature in enumerate(network_features):
            properties = dict(feature["properties"])
            if properties.pop("g", None) != index:
                raise RuntimeError(
                    f"network.geojson feature {index} does not carry its own"
                    " file-order index as g"
                )
            access_groups.append(properties)
        del network_features

    service_metadata = []
    for service in SERVICE_SPECS:
        presets = [
            {
                "label": f"{minutes} min {'walk' if mode == 'walk' else 'drive'}",
                "minutes": minutes,
                "mode": mode,
            }
            for mode, minutes_values in service["routes"]
            for minutes in minutes_values
        ]
        service_metadata.append(
            {
                "description": service["description"],
                "id": service["id"],
                "label": service["label"],
                "place_count": len(prepared[service["id"]]),
                "presets": presets,
                "query": list(service["query"]),
            }
        )

    write_json(
        output / "metadata.json",
        {
            "access_network": {
                "file": "access.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                # Attribute map per group, indexed by the tiles' `g`
                # property (feature-state styling, lowzoom-fastpath
                # section 3.2). Per-build; never persist g across deploys.
                "groups": access_groups,
                "layer": "network",
                # Informational (docs/lowzoom-fastpath.md section 2.3):
                # z6-max_zoom tiles carry the fixed grid_zoom encoder-grid
                # skeleton; the raw edges begin one zoom above. Grid and
                # serving handoff are intentionally independent.
                "lowzoom": {
                    "grid_zoom": COARSE_GRID_ZOOM,
                    "max_zoom": COARSE_MAX_ZOOM,
                },
                "max_data_zoom": TILE_MAX_ZOOM,
                "min_data_zoom": TILE_MIN_ZOOM,
                "requirements": [
                    {
                        "key": key,
                        "minutes": list(route["minutes"]),
                        "mode": route["mode"],
                        "service": route["service"],
                    }
                    for key, route in zip(REQUIREMENT_KEYS, ROUTE_SPECS, strict=True)
                ],
            },
            "destination_tiles": [
                {
                    "file": f"destinations-{route_key(route)}.pmtiles",
                    "layers": {
                        str(minutes): destination_layer_name(minutes)
                        for minutes in route["minutes"]
                    },
                    "mode": route["mode"],
                    "service": route["service"],
                }
                for route in ROUTE_SPECS
            ],
            "basemap": {
                "file": "lithuania.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "max_data_zoom": 14,
                "min_data_zoom": 4,
                "tilemaker_version": args.tilemaker_version,
            },
            "details": {
                "attributes": {
                    "access": ["public", "private", "customers"],
                    "classification": [
                        "playground",
                        "health",
                        "education",
                        "civic",
                        "culture",
                        "lodging",
                        "food",
                        "retail",
                        "recreation",
                        "religion",
                        "tourism",
                        "business",
                        "service",
                    ],
                    "display_tier": [15, 16, 17, 18],
                    "fallback_name": ["brand", "operator"],
                    "house_name": ["housename", "housename:lt", "housename:en"],
                    "house_number": "housenumber",
                    "kind": "source_osm_subtype",
                    "micro_class": [
                        "toilets",
                        "drinking_water",
                        "bicycle_parking",
                        "compressed_air",
                        "shelter",
                        "recycling",
                        "information",
                        "defibrillator",
                        "life_ring",
                        "emergency_entrance",
                        "fountain",
                    ],
                    "micro_markers": "localized_code_like_text; never color_only",
                    "proper_name": ["name", "name:lt", "name:en"],
                    "rank": "lower_values_win_collisions",
                    "transit_kind": ["station", "halt", "terminal", "stop"],
                    "transit_modes": ["train", "subway", "tram", "trolleybus", "bus", "ferry"],
                    "transit_platform_count": "canonicalized_source_members",
                    "transit_ref": "short_explicit_ref_only",
                },
                "display_max_zoom": 18,
                "display_min_zoom": 15,
                "file": "details.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "layers": {
                    "building_details": "building_details",
                    "micro_details": "micro_details",
                    "poi_details": "poi_details",
                    "transit_details": "transit_details",
                },
                "max_data_zoom": 16,
                "min_data_zoom": 15,
                "overzoom": {
                    "from_zoom": 17,
                    "source_zoom": 16,
                    "through_zoom": 18,
                },
                "schema_version": 4,
                "pmtiles_cli_version": args.pmtiles_cli_version,
                "tilemaker_version": args.tilemaker_version,
            },
            "bbox": country_bbox,
            "generated_at_osm_timestamp": osm_timestamp,
            "geometry": {
                "corridor_buffer_meters": CORRIDOR_BUFFER_METERS,
                "low_zoom_generalization_below": RAW_NETWORK_MIN_ZOOM,
                "representation": "client_stroked_lines",
                "source": "valhalla_expansion_edges",
                "tile_max_zoom": TILE_MAX_ZOOM,
                "visual_smoothing": False,
            },
            "osm_attribution": "© OpenStreetMap contributors, ODbL 1.0",
            "osm_source": args.osm_source_url,
            "places": {
                "catalog_file": "place-catalog.json",
                "file": "places.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "layer": "places",
                "max_data_zoom": TILE_MAX_ZOOM,
                "min_data_zoom": PLACE_TILE_MIN_ZOOM,
            },
            "routed_counts": routed_counts,
            "routing_failure_policy": "fail_build_on_any_unroutable_destination",
            "routing_mode": "reverse expansion edges: origin routing graph to concrete destination",
            "services": service_metadata,
            "valhalla_version": args.valhalla_version,
        },
    )
    print(
        "generated "
        + ", ".join(
            f"{len(prepared[service['id']])} {service['id']}" for service in SERVICE_SPECS
        )
        + " destinations",
        file=sys.stderr,
    )
    print(f"[mapgames] total pipeline: {time.perf_counter() - pipeline_started:.2f}s", flush=True)


if __name__ == "__main__":
    main()
