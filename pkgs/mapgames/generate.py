#!/usr/bin/env python3

import argparse
from contextlib import contextmanager
import json
import math
from pathlib import Path
import subprocess
import sys
import time

from shapely.geometry import (
    box,
    mapping,
    shape,
)

from valhalla import get_config


COVERAGE_MIN_ZOOM = 6
DESTINATION_MIN_ZOOM = 12
COVERAGE_MAX_ZOOM = 14
LOW_ZOOM_GENERALIZATION_BELOW = 11

SERVICE_SPECS = (
    {
        "id": "coffee",
        "label": "Coffee & food",
        "description": "Cafes, coffee shops, and restaurants",
        "query": ("amenity=cafe", "amenity=restaurant", "shop=coffee"),
        "routes": (("walk", (5, 10, 20)),),
        "count_bands": False,
    },
    {
        "id": "hospital",
        "label": "Hospital",
        "description": "Hospitals reachable by car",
        "query": ("amenity=hospital", "healthcare=hospital"),
        "routes": (("drive", (20, 30)),),
        "count_bands": False,
    },
    {
        "id": "supermarket",
        "label": "Supermarket",
        "description": "Full-size supermarkets",
        "query": ("shop=supermarket",),
        "routes": (("walk", (10, 20)), ("drive", (10,))),
        "count_bands": False,
    },
    {
        "id": "fuel",
        "label": "Fuel station",
        "description": "Fuel stations reachable by car",
        "query": ("amenity=fuel",),
        "routes": (("drive", (10, 20)),),
        "count_bands": False,
    },
)

ROUTE_SPECS = tuple(
    {
        "service": service["id"],
        "mode": mode,
        "minutes": minutes,
        "count_bands": service["count_bands"],
    }
    for service in SERVICE_SPECS
    for mode, minutes in service["routes"]
)

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


def route_key(route: dict) -> str:
    return f"{route['service']}-{route['mode']}"


def coverage_layer_name() -> str:
    return "coverage"


def destination_layer_name(minutes: int) -> str:
    return f"destinations_{minutes}"


def coverage_filename(route: dict) -> str:
    return f"coverage-{route_key(route)}.geojson"


def destinations_filename(route: dict, minutes: int) -> str:
    return f"destinations-{route_key(route)}-{minutes}.geojson"


def common_tile_settings(name: str, description: str, minzoom: int = COVERAGE_MIN_ZOOM) -> dict:
    return {
        "minzoom": minzoom,
        "maxzoom": COVERAGE_MAX_ZOOM,
        "basezoom": COVERAGE_MAX_ZOOM,
        "include_ids": False,
        "combine_below": COVERAGE_MAX_ZOOM,
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


def coverage_tile_config(route: dict, work: Path) -> dict:
    layer = coverage_layer_name()
    return {
        "layers": {
            layer: {
                "minzoom": COVERAGE_MIN_ZOOM,
                "maxzoom": COVERAGE_MAX_ZOOM,
                "source": str(work / coverage_filename(route)),
                "source_columns": ["max_minutes", "min_minutes", "mode", "service"],
                # Only country-scale tiles are generalized. Street-scale tiles and
                # the exported GeoJSON retain the reachable routing edges.
                "simplify_below": LOW_ZOOM_GENERALIZATION_BELOW,
                "simplify_level": 0.00001,
                "simplify_algorithm": "visvalingam",
            }
        },
        "settings": common_tile_settings(
            f"Mapgames {route_key(route)} access",
            "Deduplicated reverse Valhalla expansion edges",
        ),
    }


def destination_tile_config(route: dict, work: Path) -> dict:
    return {
        "layers": {
            destination_layer_name(minutes): {
                "minzoom": DESTINATION_MIN_ZOOM,
                "maxzoom": COVERAGE_MAX_ZOOM,
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


def places_tile_config(output: Path) -> dict:
    return {
        "layers": {
            "places": {
                "minzoom": 9,
                "maxzoom": COVERAGE_MAX_ZOOM,
                "source": str(output / "places.geojson"),
                "source_columns": list(PLACE_SOURCE_COLUMNS),
                "combine_points": False,
            }
        },
        "settings": common_tile_settings(
            "Mapgames service destinations",
            "Cafes, restaurants, hospitals, supermarkets, and fuel stations",
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
    parser.add_argument("--basemap-config", type=Path, required=True)
    parser.add_argument("--basemap-process", type=Path, required=True)
    parser.add_argument("--coverage-process", type=Path, required=True)
    parser.add_argument("--tilemaker-version", required=True)
    parser.add_argument("--valhalla-version", required=True)
    parser.add_argument("--expansion-helper", type=Path, required=True)
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
    write_json(
        work / "lithuania.geojson",
        feature_collection(
            [
                {
                    "type": "Feature",
                    "properties": {"boundary_type": "bbox", "name": "Coverage bounds"},
                    "geometry": mapping(country),
                }
            ],
            country_bbox,
        ),
    )
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
    coverage_bbox = ",".join(str(coordinate) for coordinate in country_bbox)
    for route in ROUTE_SPECS:
        if route["count_bands"]:
            raise RuntimeError("native reachable-line generation does not support count bands")
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
                work,
                # Coverage GeoJSON is a tilemaker input only; keep it out of
                # the published output directory.
                work,
                args.concurrency,
                ",".join(str(minutes) for minutes in route["minutes"]),
                coverage_bbox,
                key,
                route["service"],
                route["mode"],
            ],
        )
        for _location, place_feature in entries:
            place_feature["properties"][f"{route['mode']}_routing_status"] = "routed"
        routed_counts[key] = len(entries)

    place_features = [
        feature
        for service in SERVICE_SPECS
        for _location, feature in prepared[service["id"]]
    ]
    write_json(output / "places.geojson", feature_collection(place_features, country_bbox))

    access_tiles = []
    for route in ROUTE_SPECS:
        key = route_key(route)
        config_path = work / f"access-{key}.json"
        write_json(config_path, coverage_tile_config(route, work))
        tile_name = f"access-{key}.pmtiles"
        run(
            f"build {key} access PMTiles",
            [
                "tilemaker",
                "--quiet",
                "--bbox",
                coverage_bbox,
                "--output",
                output / tile_name,
                "--config",
                config_path,
                "--process",
                args.coverage_process,
                "--threads",
                args.concurrency,
            ],
        )
        destination_config_path = work / f"destination-lookup-{key}.json"
        write_json(destination_config_path, destination_tile_config(route, work))
        destination_tile_name = f"destinations-{key}.pmtiles"
        run(
            f"build {key} click-lookup PMTiles",
            [
                "tilemaker",
                "--quiet",
                "--bbox",
                coverage_bbox,
                "--output",
                output / destination_tile_name,
                "--config",
                destination_config_path,
                "--process",
                args.coverage_process,
                "--threads",
                args.concurrency,
            ],
        )
        coverage_layers = {}
        destination_layers = {}
        for minutes in route["minutes"]:
            coverage_layers[str(minutes)] = coverage_layer_name()
            destination_layers[str(minutes)] = destination_layer_name(minutes)
        access_tiles.append(
            {
                "coverage_layers": coverage_layers,
                "destination_file": destination_tile_name,
                "destination_layers": destination_layers,
                "file": tile_name,
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "max_data_zoom": COVERAGE_MAX_ZOOM,
                "min_data_zoom": COVERAGE_MIN_ZOOM,
                "mode": route["mode"],
                "service": route["service"],
            }
        )

    places_config = work / "places.json"
    write_json(places_config, places_tile_config(output))
    run(
        "build service destination PMTiles",
        [
            "tilemaker",
            "--quiet",
            "--bbox",
            coverage_bbox,
            "--output",
            output / "places.pmtiles",
            "--config",
            places_config,
            "--process",
            args.coverage_process,
            "--threads",
            args.concurrency,
        ],
    )

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
                "count_bands": service["count_bands"],
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
            "access_tiles": access_tiles,
            "basemap": {
                "file": "lithuania.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "max_data_zoom": 14,
                "min_data_zoom": 4,
                "tilemaker_version": args.tilemaker_version,
            },
            "bbox": country_bbox,
            "generated_at_osm_timestamp": osm_timestamp,
            "geometry": {
                "corridor_buffer_meters": CORRIDOR_BUFFER_METERS,
                "low_zoom_generalization_below": LOW_ZOOM_GENERALIZATION_BELOW,
                "representation": "client_stroked_lines",
                "source": "valhalla_expansion_edges",
                "tile_max_zoom": COVERAGE_MAX_ZOOM,
                "visual_smoothing": False,
            },
            "osm_attribution": "© OpenStreetMap contributors, ODbL 1.0",
            "osm_source": args.osm_source_url,
            "places": {
                "file": "places.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "layer": "places",
                "max_data_zoom": COVERAGE_MAX_ZOOM,
                "min_data_zoom": 9,
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
