#!/usr/bin/env python3

import argparse
from contextlib import contextmanager
import json
import math
from pathlib import Path
import subprocess
import sys
import time

from shapely.geometry import GeometryCollection, MultiPolygon, Polygon, mapping, shape
from shapely.ops import transform, unary_union

from valhalla import Actor, get_config


CONTOUR_MINUTES = (5, 10, 20)
LITHUANIA_ISO_CODE = "LT"
COVERAGE_MIN_ZOOM = 6
COVERAGE_MAX_ZOOM = 12


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


def coverage_tile_config(minutes: int, output: Path) -> dict:
    layers = {}
    for minimum_cafes, layer_name in ((1, "coverage_one"), (2, "coverage_two")):
        layers[layer_name] = {
            "minzoom": COVERAGE_MIN_ZOOM,
            "maxzoom": COVERAGE_MAX_ZOOM,
            "source": str(output / f"coverage-{minutes}-{minimum_cafes}.geojson"),
            "simplify_below": COVERAGE_MAX_ZOOM,
            "simplify_level": 0.00001,
            "simplify_algorithm": "visvalingam",
        }
    return {
        "layers": layers,
        "settings": {
            "minzoom": COVERAGE_MIN_ZOOM,
            "maxzoom": COVERAGE_MAX_ZOOM,
            "basezoom": COVERAGE_MAX_ZOOM,
            "include_ids": False,
            "combine_below": COVERAGE_MAX_ZOOM,
            "name": f"Mapgames {minutes}-minute cafe coverage",
            "version": "1.0.0",
            "description": "Tiled walking-time coverage generated with Valhalla",
            "compress": "gzip",
            "filemetadata": {
                "tilejson": "3.0.0",
                "scheme": "xyz",
                "type": "overlay",
                "format": "pbf",
                "attribution": "© OpenStreetMap contributors, ODbL 1.0",
            },
        },
    }


def polygonal_part(geometry):
    if isinstance(geometry, (Polygon, MultiPolygon)):
        return geometry
    if isinstance(geometry, GeometryCollection):
        polygons = [
            part
            for part in geometry.geoms
            if isinstance(part, (Polygon, MultiPolygon)) and not part.is_empty
        ]
        return unary_union(polygons) if polygons else Polygon()
    return Polygon()


def valid_polygon(geometry):
    geometry = polygonal_part(geometry)
    if not geometry.is_valid:
        geometry = polygonal_part(geometry.buffer(0))
    return geometry


def merge_coverage_states(left, right):
    """Merge (covered >=1 time, covered >=2 times) polygon states."""
    left_once, left_twice = left
    right_once, right_twice = right
    twice = unary_union(
        [left_twice, right_twice, valid_polygon(left_once.intersection(right_once))]
    )
    return valid_polygon(unary_union([left_once, right_once])), valid_polygon(twice)


def coverage_at_least_twice(polygons):
    states = [(polygon, Polygon()) for polygon in polygons if not polygon.is_empty]
    if not states:
        return Polygon(), Polygon()
    while len(states) > 1:
        next_states = [
            merge_coverage_states(states[index], states[index + 1])
            for index in range(0, len(states) - 1, 2)
        ]
        if len(states) % 2:
            next_states.append(states[-1])
        states = next_states
    return states[0]


def local_metric_transforms(country):
    center_latitude = (country.bounds[1] + country.bounds[3]) / 2.0
    longitude_scale = 111_320.0 * math.cos(math.radians(center_latitude))
    latitude_scale = 110_574.0

    def forward(x, y, z=None):
        return x * longitude_scale, y * latitude_scale

    def inverse(x, y, z=None):
        return x / longitude_scale, y / latitude_scale

    return forward, inverse


def simplify_in_meters(geometry, meters: float, forward, inverse):
    if meters <= 0:
        return geometry
    projected = transform(forward, geometry)
    return valid_polygon(transform(inverse, projected.simplify(meters, preserve_topology=True)))


def display_geometry(
    geometry,
    country,
    smoothing_meters: float,
    simplify_meters: float,
    forward,
    inverse,
):
    geometry = valid_polygon(geometry.intersection(country))
    projected = transform(forward, geometry)
    if smoothing_meters > 0:
        projected = projected.buffer(smoothing_meters, quad_segs=4).buffer(
            -smoothing_meters, quad_segs=4
        )
    if simplify_meters > 0:
        projected = projected.simplify(simplify_meters, preserve_topology=True)
    return valid_polygon(transform(inverse, projected).intersection(country))


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pbf", type=Path, required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    parser.add_argument("--basemap-config", type=Path, required=True)
    parser.add_argument("--basemap-process", type=Path, required=True)
    parser.add_argument("--coverage-process", type=Path, required=True)
    parser.add_argument("--tilemaker-version", required=True)
    parser.add_argument("--valhalla-version", required=True)
    parser.add_argument("--osm-source-url", required=True)
    parser.add_argument("--smoothing-meters", type=float, required=True)
    parser.add_argument("--simplify-meters", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    pipeline_started = time.perf_counter()
    args = parse_args()
    if args.concurrency <= 0:
        raise ValueError("concurrency must be positive")
    if not math.isfinite(args.smoothing_meters) or args.smoothing_meters < 0:
        raise ValueError("smoothing-meters must be finite and non-negative")
    if not math.isfinite(args.simplify_meters) or args.simplify_meters < 0:
        raise ValueError("simplify-meters must be finite and non-negative")

    work = Path.cwd() / "work"
    output = args.output.resolve()
    work.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)

    osm_timestamp = capture(
        "read OSM snapshot timestamp",
        ["osmium", "fileinfo", "-g", "header.option.osmosis_replication_timestamp", args.pbf],
    )

    boundary_pbf = work / "lithuania-boundary.osm.pbf"
    boundary_geojson_path = work / "lithuania-boundary.raw.geojson"
    run(
        "extract Lithuania boundary",
        [
            "osmium",
            "tags-filter",
            "--remove-tags",
            "--output",
            boundary_pbf,
            args.pbf,
            f"r/ISO3166-1={LITHUANIA_ISO_CODE}",
        ],
    )
    run(
        "export Lithuania boundary",
        [
            "osmium",
            "export",
            "--geometry-types=polygon",
            "--add-unique-id=type_id",
            "--show-errors",
            "--stop-on-error",
            "--output",
            boundary_geojson_path,
            boundary_pbf,
        ],
    )
    with timed("prepare Lithuania boundary"):
        boundary_source = json.loads(boundary_geojson_path.read_text(encoding="utf-8"))
        boundary_features = boundary_source.get("features", [])
        if len(boundary_features) != 1:
            raise RuntimeError(
                f"expected one ISO3166-1={LITHUANIA_ISO_CODE} boundary, got "
                f"{len(boundary_features)}"
            )
        country = valid_polygon(shape(boundary_features[0]["geometry"]))
        if country.is_empty:
            raise RuntimeError("Lithuania boundary is empty")
        forward, inverse = local_metric_transforms(country)
        country_for_output = simplify_in_meters(country, 10.0, forward, inverse)
        country_bbox = list(country.bounds)
        write_json(
            output / "lithuania.geojson",
            {
                "type": "FeatureCollection",
                "bbox": country_bbox,
                "features": [
                    {
                        "type": "Feature",
                        "properties": {"ISO3166-1": LITHUANIA_ISO_CODE, "name": "Lietuva"},
                        "geometry": mapping(country_for_output),
                    }
                ],
            },
        )

    run(
        "build lean Lithuania PMTiles basemap",
        [
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
        ],
    )

    cafe_pbf = work / "cafes.osm.pbf"
    raw_cafes_path = work / "cafes.raw.geojson"
    run(
        "filter cafes and coffee shops",
        [
            "osmium",
            "tags-filter",
            "--remove-tags",
            "--output",
            cafe_pbf,
            args.pbf,
            "nwr/amenity=cafe",
            "nwr/shop=coffee",
        ],
    )
    run(
        "export cafes and coffee shops",
        [
            "osmium",
            "export",
            "--geometry-types=point,polygon",
            "--add-unique-id=type_id",
            "--attributes=version,timestamp",
            "--show-errors",
            "--stop-on-error",
            "--output",
            raw_cafes_path,
            cafe_pbf,
        ],
    )

    with timed("prepare cafe locations"):
        source_cafes = json.loads(raw_cafes_path.read_text(encoding="utf-8"))
        prepared = []
        seen_ids = set()
        for feature in source_cafes.get("features", []):
            feature_id = str(feature.get("id") or "")
            if not feature_id or feature_id in seen_ids:
                continue
            source_geometry = feature.get("geometry")
            if source_geometry is None:
                continue
            geometry = shape(source_geometry)
            if geometry.is_empty:
                continue
            point = geometry.representative_point()
            if not country.covers(point):
                continue
            osm_type, osm_id = decode_osmium_id(feature_id)
            properties = dict(feature.get("properties") or {})
            properties["source_geometry"] = source_geometry.get("type")
            if osm_type is not None:
                properties["osm_type"] = osm_type
                properties["osm_id"] = osm_id
                properties["osm_url"] = f"https://www.openstreetmap.org/{osm_type}/{osm_id}"
            prepared.append(
                (
                    {"lon": point.x, "lat": point.y, "radius": 100},
                    {
                        "type": "Feature",
                        "id": feature_id,
                        "geometry": {"type": "Point", "coordinates": [point.x, point.y]},
                        "properties": properties,
                    },
                )
            )
            seen_ids.add(feature_id)

        prepared.sort(key=lambda pair: (pair[0]["lon"], pair[0]["lat"], pair[1]["id"]))
        if not prepared:
            raise RuntimeError("Lithuania contains no amenity=cafe or shop=coffee features")

    tiles = work / "tiles"
    tiles.mkdir()
    with timed("write Valhalla configuration"):
        # Keywords keep this compatible with nixpkgs releases that changed the
        # positional order. Empty tile_extract selects the directory without
        # requiring a not-yet-created tar archive.
        config = get_config(tile_extract="", tile_dir=tiles)
        config_path = work / "valhalla.json"
        write_json(config_path, config)

    run(
        "build Lithuania Valhalla routing tiles",
        [
            "valhalla_build_tiles",
            "--config",
            config_path,
            "--concurrency",
            args.concurrency,
            args.pbf,
        ],
    )

    with timed("initialize offline Valhalla Actor"):
        try:
            actor = Actor(config)
        except TypeError:
            actor = Actor(json.dumps(config, separators=(",", ":")))

    contour_polygons = {minutes: [] for minutes in CONTOUR_MINUTES}
    routing_failures = []
    with timed("compute per-cafe Lithuania walking isochrones"):
        for index, (location, cafe_feature) in enumerate(prepared, start=1):
            try:
                result = actor.isochrone(
                    {
                        "locations": [location],
                        "costing": "pedestrian",
                        "contours": [{"time": minutes} for minutes in CONTOUR_MINUTES],
                        "polygons": True,
                        "denoise": 0,
                        "generalize": 0,
                        # Measure places from which each cafe can be reached.
                        "reverse": True,
                    }
                )
                found = {}
                for feature in result.get("features", []):
                    minutes = int(feature.get("properties", {}).get("contour", -1))
                    if minutes not in contour_polygons:
                        continue
                    geometry = valid_polygon(shape(feature["geometry"]))
                    if not geometry.is_empty:
                        found[minutes] = geometry
                missing = set(CONTOUR_MINUTES) - set(found)
                if missing:
                    raise RuntimeError(f"missing contours: {sorted(missing)}")
                for minutes, geometry in found.items():
                    contour_polygons[minutes].append(geometry)
                cafe_feature["properties"]["routing_status"] = "routed"
            except RuntimeError as error:
                cafe_feature["properties"]["routing_status"] = "unroutable"
                routing_failures.append({"id": cafe_feature["id"], "error": str(error)})
            if index % 100 == 0 or index == len(prepared):
                print(f"[mapgames] routed {index}/{len(prepared)} locations", flush=True)

    routed_count = len(prepared) - len(routing_failures)
    if routed_count == 0:
        raise RuntimeError("Valhalla could not route any cafe locations")

    cafe_features = [feature for _location, feature in prepared]
    write_json(
        output / "cafes.geojson",
        {
            "type": "FeatureCollection",
            "bbox": country_bbox,
            "features": cafe_features,
        },
    )

    with timed("build one-cafe and two-cafe coverage polygons"):
        coverage_files = []
        for minutes in CONTOUR_MINUTES:
            once, twice = coverage_at_least_twice(contour_polygons[minutes])
            once = valid_polygon(once.intersection(country))
            twice = valid_polygon(twice.intersection(once))
            if once.is_empty:
                raise RuntimeError(f"the {minutes}-minute one-cafe coverage is empty")

            displayed_once = display_geometry(
                once,
                country_for_output,
                args.smoothing_meters,
                args.simplify_meters,
                forward,
                inverse,
            )
            displayed_twice = display_geometry(
                twice,
                country_for_output,
                args.smoothing_meters,
                args.simplify_meters,
                forward,
                inverse,
            )
            displayed_twice = valid_polygon(displayed_twice.intersection(displayed_once))

            for minimum_cafes, raw_geometry, rendered_geometry in (
                (1, once, displayed_once),
                (2, twice, displayed_twice),
            ):
                properties = {
                    "minutes": minutes,
                    "minimum_cafes": minimum_cafes,
                    "direction": "to_cafe",
                }
                raw_name = f"coverage-{minutes}-{minimum_cafes}-raw.geojson"
                display_name = f"coverage-{minutes}-{minimum_cafes}.geojson"
                for filename, geometry, display in (
                    (raw_name, raw_geometry, False),
                    (display_name, rendered_geometry, True),
                ):
                    write_json(
                        output / filename,
                        {
                            "type": "FeatureCollection",
                            "bbox": country_bbox,
                            "features": [
                                {
                                    "type": "Feature",
                                    "properties": {**properties, "display_geometry": display},
                                    "geometry": mapping(geometry),
                                }
                            ],
                        },
                    )
                coverage_files.append(
                    {
                        **properties,
                        "raw": raw_name,
                        "display": display_name,
                    }
                )

    coverage_tiles = []
    coverage_bbox = ",".join(str(coordinate) for coordinate in country_bbox)
    for minutes in CONTOUR_MINUTES:
        config_path = work / f"coverage-{minutes}.json"
        write_json(config_path, coverage_tile_config(minutes, output))
        tile_name = f"coverage-{minutes}.pmtiles"
        run(
            f"build {minutes}-minute coverage PMTiles",
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
        coverage_tiles.append(
            {
                "file": tile_name,
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "layers": {"1": "coverage_one", "2": "coverage_two"},
                "max_data_zoom": COVERAGE_MAX_ZOOM,
                "min_data_zoom": COVERAGE_MIN_ZOOM,
                "minutes": minutes,
            }
        )

    write_json(
        output / "metadata.json",
        {
            "bbox": country_bbox,
            "basemap": {
                "file": "lithuania.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "max_data_zoom": 14,
                "min_data_zoom": 4,
                "tilemaker_version": args.tilemaker_version,
            },
            "cafe_count": len(prepared),
            "contours_minutes": list(CONTOUR_MINUTES),
            "coverage_files": coverage_files,
            "coverage_tiles": coverage_tiles,
            "generated_at_osm_timestamp": osm_timestamp,
            "osm_attribution": "© OpenStreetMap contributors, ODbL 1.0",
            "osm_source": args.osm_source_url,
            "query": ["amenity=cafe", "shop=coffee"],
            "routed_cafe_count": routed_count,
            "routing_failures": routing_failures,
            "routing_mode": "pedestrian reverse isochrone (walk to cafe)",
            "valhalla_version": args.valhalla_version,
            "display_geometry": {
                "authoritative_raw_files_are_included": True,
                "simplify_meters": args.simplify_meters,
                "smoothing_meters": args.smoothing_meters,
            },
        },
    )
    print(
        f"generated six raw and six display layers from {routed_count}/{len(prepared)} "
        "Lithuania cafes and coffee shops",
        file=sys.stderr,
    )
    print(f"[mapgames] total pipeline: {time.perf_counter() - pipeline_started:.2f}s", flush=True)


if __name__ == "__main__":
    main()
