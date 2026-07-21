#!/usr/bin/env python3

import argparse
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import time

from shapely.geometry import (
    box,
    mapping,
    Point,
    shape,
)

from valhalla import get_config


TILE_MIN_ZOOM = 6
TILE_MAX_ZOOM = 14
# Place dots are displayed only in overzoomed street-level views. Encoding
# the same point set below the archive's maximum zoom only duplicates data;
# one canonical z14 tile pyramid supplies every displayed zoom.
PLACE_TILE_MIN_ZOOM = TILE_MAX_ZOOM
INSPECTOR_MIN_ZOOM = 15
INSPECTOR_MAX_ZOOM = 16
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
# Low-zoom fast-path (docs/lowzoom-fastpath.md):
# the z10-encoder-grid skeleton serves z8-13, and the
# short-chain-filtered subset (chains of z10-grid length >= N_drop kept)
# serves z6-7. GRID_ZOOM is fixed at 10 for both; N_drop = 64 grid units
# (~350 m ground) is the accepted comparison value.
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
        "routes": (("drive", (15, 30)),),
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
    {
        # Unlike every other service, shelter destinations are not matched from
        # the OSM PBF. They come from Lithuania's official PAGD open datasets
        # (see SHELTER_SOURCES / load_shelters), pinned as a snapshot input.
        # An empty query keeps this service out of the osmium destination
        # filter while still satisfying the generic per-service machinery.
        "id": "shelter",
        "label": "Shelter",
        "description": "Public civil-protection shelters reachable on foot",
        "query": (),
        "routes": (("walk", (10, 20)),),
    },
)

# Official PAGD open datasets snapshotted by the lt-shelters service. Each
# record carries WGS84 coordinates (wgs_lon_ilguma / wgs_lat_platuma) and
# Lithuanian address fields. `kind` is the catalog/marker classification the
# client localizes via kindLabelTables. `dataset` is the record `_type` the
# lt-shelters fetcher validates, re-checked here so a mismatched file fails
# the build loudly rather than silently emitting zero shelters.
SHELTER_SOURCES = (
    {
        "id": "priedanga",
        "kind": "priedanga",
        "arg": "shelter_priedangos",
        "dataset": "datasets/gov/pagd/priedangos/Priedanga",
    },
    {
        "id": "kas",
        "kind": "kas",
        "arg": "shelter_kas",
        "dataset": "datasets/gov/pagd/kas/KAS",
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


# Attribute keys of the unified network layer are `{service}_{mode}`. Route
# keys also name the native classified handoffs, so keep both components to
# lowercase words and prove their mapping before expensive routing starts.
_ROUTE_KEY_GRAMMAR = re.compile(r"[a-z]+-[a-z]+")
REQUIREMENT_KEYS = tuple(f"{route['service']}_{route['mode']}" for route in ROUTE_SPECS)
for _route, _requirement_key in zip(ROUTE_SPECS, REQUIREMENT_KEYS, strict=True):
    _key = route_key(_route)
    if not _ROUTE_KEY_GRAMMAR.fullmatch(_key):
        raise RuntimeError(
            f"route key {_key!r} does not match the one-dash [a-z]+-[a-z]+ grammar"
            " required by the native relation handoff"
        )
    if _key.replace("-", "_") != _requirement_key:
        raise RuntimeError(
            f"route key {_key!r} does not derive requirement key {_requirement_key!r}"
        )
del _route, _requirement_key, _key

# The client (review-ui-state.js withIconsOnlyPreset) synthesizes its icons-only
# "0" on top of each service's routed presets and trusts them to be a non-empty
# array of positive-integer minutes. That is a generation-time contract: enforce
# it here, statically at import, so an invalid SERVICE_SPECS fails the build
# rather than the page load.
for _service in SERVICE_SPECS:
    if not _service["routes"]:
        raise RuntimeError(f"service {_service['id']!r} has no routes")
    for _mode, _minutes_values in _service["routes"]:
        if not isinstance(_mode, str) or not _mode:
            raise RuntimeError(
                f"service {_service['id']!r} has a non-string route mode {_mode!r}"
            )
        if not _minutes_values:
            raise RuntimeError(
                f"service {_service['id']!r} mode {_mode!r} has no preset minutes"
            )
        for _minutes in _minutes_values:
            if isinstance(_minutes, bool) or not isinstance(_minutes, int) or _minutes <= 0:
                raise RuntimeError(
                    f"service {_service['id']!r} mode {_mode!r} has a"
                    f" non-positive-integer preset minute {_minutes!r}"
                )
del _service, _mode, _minutes_values, _minutes

MODE_COSTING = {"walk": "pedestrian", "drive": "auto"}
MODE_BITS = {"walk": 1, "drive": 2}
CORRIDOR_BUFFER_METERS = {"walk": 12, "drive": 18}
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


def run_parallel_branches(
    branches: dict[str, Callable[[], object]],
) -> dict[str, object]:
    """Run independent branches and retain declaration-ordered outcomes."""
    if not branches:
        return {}
    results = {}
    failures = {}
    with ThreadPoolExecutor(max_workers=len(branches), thread_name_prefix="mapgames") as executor:
        futures = {name: executor.submit(branch) for name, branch in branches.items()}
        # Resolve every submitted branch before propagating an error. This is
        # deliberate structured concurrency: a failed build waits for its one
        # running sibling to finish and clean up rather than abandoning it.
        for name, future in futures.items():
            try:
                results[name] = future.result()
            except Exception as error:
                error.add_note(f"post-merge {name} branch failed")
                failures[name] = error
    if failures:
        if len(failures) == 1:
            raise next(failures[name] for name in branches if name in failures)
        raise ExceptionGroup(
            "post-merge build branches failed",
            [failures[name] for name in branches if name in failures],
        )
    return {name: results[name] for name in branches}


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )


def feature_collection(features: list[dict], bbox: list[float]) -> dict:
    return {"type": "FeatureCollection", "bbox": bbox, "features": features}


# Metres Valhalla is allowed to snap a destination point to the routing graph.
PLACE_SNAP_RADIUS_METERS = 100


def make_place_entry(place_id: str, lon: float, lat: float, properties: dict) -> tuple[dict, dict]:
    """The (location, feature) tuple every destination takes, OSM or shelter.

    Both destination sources must produce byte-identical structure so the shared
    sort, place_index assignment, expansion, catalog, and places-tile stages
    treat them uniformly; keep this the single constructor of that shape.
    """
    feature = {
        "type": "Feature",
        "id": place_id,
        "geometry": {"type": "Point", "coordinates": [lon, lat]},
        "properties": properties,
    }
    return ({"lon": lon, "lat": lat, "radius": PLACE_SNAP_RADIUS_METERS}, feature)


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


# Object-level lifecycle booleans mark a destination as no longer in service.
# These objects still exist for the inspector (inspector.lua marks them), but
# they must never enter the routable place set: a route to a closed café is a
# defect, not a feature. Keep this list in lockstep with inspector.lua's
# lifecycle_keys so the two views agree on what "not current" means.
LIFECYCLE_KEYS = (
    "abandoned", "closed", "demolished", "destroyed",
    "disused", "proposed", "razed", "removed",
)


def object_is_current(properties: dict) -> bool:
    return not any(
        str(properties.get(key, "")).strip().lower() in ("yes", "true", "1")
        for key in LIFECYCLE_KEYS
    )


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


def shelter_display_name(record: dict, street: str, house: str) -> str:
    """A human-facing label for a shelter card, preferring the source name."""
    name = str(record.get("pavadinimas") or "").strip()
    if name:
        return name
    address = " ".join(part for part in (street, house) if part)
    if address:
        return address
    for field in ("gyvenviete", "savivaldybe"):
        value = str(record.get(field) or "").strip()
        if value:
            return value
    return "Slėptuvė"


def load_shelters(args: argparse.Namespace, country, prepared: dict) -> None:
    """Inject PAGD shelter destinations into prepared["shelter"] from JSONL.

    Shelter points originate outside OSM, so they bypass services_for_properties
    and the osmium destination filter. Every downstream stage (routing,
    catalog, places, unified network) is service-agnostic and consumes the same
    (location, feature) tuples the OSM path produces; the only shelter-specific
    work is here.
    """
    seen_ids: set[str] = set()
    for source in SHELTER_SOURCES:
        path = getattr(args, source["arg"])
        added = 0
        skipped = 0
        with path.open(encoding="utf-8") as handle:
            for line_number, raw in enumerate(handle, start=1):
                stripped = raw.strip()
                if not stripped:
                    continue
                # The lt-shelters fetcher already validated JSON structure and
                # dataset type per record; re-validate the shape this pipeline
                # depends on rather than trusting the pinned snapshot blindly.
                try:
                    record = json.loads(stripped)
                except json.JSONDecodeError as error:
                    raise RuntimeError(
                        f"{path}:{line_number} is not valid JSON: {error}"
                    ) from error
                if not isinstance(record, dict) or record.get("_type") != source["dataset"]:
                    raise RuntimeError(
                        f"{path}:{line_number} is not a {source['dataset']!r} record"
                    )
                record_id = str(record.get("_id") or "").strip()
                if not record_id:
                    raise RuntimeError(f"{path}:{line_number} has no _id")
                lon = record.get("wgs_lon_ilguma")
                lat = record.get("wgs_lat_platuma")
                if (
                    isinstance(lon, bool)
                    or isinstance(lat, bool)
                    or not isinstance(lon, (int, float))
                    or not isinstance(lat, (int, float))
                    or not math.isfinite(lon)
                    or not math.isfinite(lat)
                ):
                    skipped += 1
                    continue
                point = Point(lon, lat)
                if not country.covers(point):
                    skipped += 1
                    continue
                place_id = f"shelter:{source['id']}:{record_id}"
                if place_id in seen_ids:
                    skipped += 1
                    continue
                street = str(record.get("gatve") or "").strip()
                house = str(record.get("namo_numeris") or "").strip()
                city = (
                    str(record.get("gyvenviete") or "").strip()
                    or str(record.get("savivaldybe") or "").strip()
                )
                properties = {
                    "kind": source["kind"],
                    "name": shelter_display_name(record, street, house),
                    "place_id": place_id,
                    "service": "shelter",
                    "source_geometry": "Point",
                }
                if street:
                    properties["addr:street"] = street
                if house:
                    properties["addr:housenumber"] = house
                if city:
                    properties["addr:city"] = city
                prepared["shelter"].append(
                    make_place_entry(place_id, lon, lat, properties)
                )
                seen_ids.add(place_id)
                added += 1
        print(
            f"[mapgames] loaded {added} {source['id']} shelters"
            f" ({skipped} skipped: outside coverage, missing coordinates, or duplicate id)",
            file=sys.stderr,
            flush=True,
        )


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


def relation_handoff_filename(route: dict) -> str:
    return f"relations-{route_key(route)}.bin"


def network_tile_config(work: Path) -> dict:
    # Three config layers, one MVT source-layer `network` via write_to
    # (docs/lowzoom-fastpath.md): the raw
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


def read_access_groups(path: Path, requirement_keys) -> list[dict]:
    """Load and validate the native network writer's compact group sidecar."""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if (
        not isinstance(manifest, dict)
        or set(manifest) != {"schema_version", "group_count", "groups"}
        or type(manifest.get("schema_version")) is not int
        or manifest["schema_version"] != 1
    ):
        raise RuntimeError("access group manifest has an unsupported schema")
    allowed_keys = frozenset(requirement_keys)
    if not allowed_keys or any(
        not isinstance(key, str) or not key for key in allowed_keys
    ):
        raise RuntimeError("access group requirements are invalid")
    groups = manifest.get("groups")
    group_count = manifest.get("group_count")
    if (
        type(group_count) is not int
        or group_count < 0
        or not isinstance(groups, list)
        or group_count != len(groups)
    ):
        raise RuntimeError("access group manifest count does not match its groups")
    access_groups = []
    for index, value in enumerate(groups):
        if not isinstance(value, dict):
            raise RuntimeError(f"access group manifest entry {index} is not an object")
        properties = dict(value)
        group = properties.pop("g", None)
        if type(group) is not int or group != index:
            raise RuntimeError(
                f"access group manifest entry {index} does not carry its own"
                " file-order index as g"
            )
        if not properties:
            raise RuntimeError(f"access group manifest entry {index} is empty")
        for key, minutes in properties.items():
            if key not in allowed_keys:
                raise RuntimeError(
                    f"access group manifest entry {index} has unknown requirement {key!r}"
                )
            if type(minutes) is not int or minutes <= 0:
                raise RuntimeError(
                    f"access group manifest entry {index} has invalid minutes for {key}"
                )
        access_groups.append(properties)
    return access_groups


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pbf", type=Path, required=True)
    parser.add_argument("--bbox", type=parse_bbox, required=True)
    parser.add_argument("--concurrency", type=int, required=True)
    parser.add_argument("--expansion-concurrency", type=int, required=True)
    parser.add_argument("--expansion-batch-size", type=int, default=256)
    parser.add_argument("--basemap-config", type=Path, required=True)
    parser.add_argument("--basemap-process", type=Path, required=True)
    parser.add_argument("--detail-config", type=Path, required=True)
    parser.add_argument("--detail-process", type=Path, required=True)
    parser.add_argument("--inspector-config", type=Path, required=True)
    parser.add_argument("--inspector-process", type=Path, required=True)
    parser.add_argument("--transit-tool", type=Path, required=True)
    parser.add_argument("--geojson-process", type=Path, required=True)
    parser.add_argument("--catalog-tool", type=Path, required=True)
    parser.add_argument("--destination-lookup-tool", type=Path, required=True)
    parser.add_argument("--destination-lookup-native-tool", type=Path, required=True)
    parser.add_argument("--pmtiles-cli-version", required=True)
    parser.add_argument("--tilemaker-version", required=True)
    parser.add_argument("--valhalla-version", required=True)
    parser.add_argument("--expansion-helper", type=Path, required=True)
    parser.add_argument("--coarsen-tool", type=Path, required=True)
    parser.add_argument("--osm-source-url", required=True)
    # Pinned lt-shelters snapshot (PAGD Priedanga + KAS open datasets) plus the
    # UTC time that snapshot was last refreshed, surfaced in the map's data
    # sources. See default.nix `sheltersSrc`.
    parser.add_argument("--shelter-priedangos", type=Path, required=True)
    parser.add_argument("--shelter-kas", type=Path, required=True)
    parser.add_argument("--shelter-refreshed-at", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def read_shelter_refreshed_at(path: Path) -> str:
    text = path.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", text):
        raise RuntimeError(
            f"shelter refreshed-at timestamp is not RFC 3339 UTC: {text!r}"
        )
    return text


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
        # Lifecycle-inactive matches (disused=yes, abandoned=yes, …) are dropped
        # here so they are neither routed nor drawn as a service marker. The
        # inspector keeps and marks them; the routable layer must not.
        if not object_is_current(source_properties):
            continue
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
            prepared[service].append(
                make_place_entry(place_id, point.x, point.y, properties)
            )
            seen_ids.add(place_id)

    # Shelters are the one non-OSM service; inject them before the shared sort,
    # zero-destination guard, and global place_index assignment below so they
    # are indistinguishable from OSM destinations to everything downstream.
    load_shelters(args, country, prepared)

    for service, entries in prepared.items():
        entries.sort(key=lambda pair: (pair[0]["lon"], pair[0]["lat"], pair[1]["id"]))
        if not entries:
            raise RuntimeError(f"coverage region contains no {service} destinations")
    place_index = 0
    for service in SERVICE_SPECS:
        for _location, feature in prepared[service["id"]]:
            feature["properties"]["place_index"] = place_index
            place_index += 1
    places_pbf.unlink()
    raw_places_path.unlink()
    return prepared


def object_catalog(features: list[dict]) -> list[dict]:
    result = []
    for expected_index, feature in enumerate(features):
        properties = feature["properties"]
        if properties.get("place_index") != expected_index:
            raise RuntimeError(
                f"object catalog feature {expected_index} has index "
                f"{properties.get('place_index')!r}"
            )
        entry = {
            key: properties[key]
            for key in PLACE_CATALOG_COLUMNS
            if key in properties
        }
        entry["index"] = expected_index
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


def require_paths_outside_directory(
    directory: Path, paths: list[tuple[str, Path]]
) -> None:
    directory = directory.resolve(strict=False)
    for name, path in paths:
        resolved = path.resolve(strict=False)
        if resolved == directory or directory in resolved.parents:
            raise ValueError(f"{name} must not be inside temporary routing tiles")


@contextmanager
def routing_tiles_directory(
    work: Path, protected_paths: list[tuple[str, Path]]
):
    work = work.resolve(strict=True)
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    parent_descriptor = os.open(work, directory_flags)
    tiles_descriptor = None
    name = None
    try:
        for _attempt in range(128):
            candidate = f"valhalla-tiles-{secrets.token_hex(8)}"
            try:
                os.mkdir(candidate, mode=0o700, dir_fd=parent_descriptor)
                name = candidate
                break
            except FileExistsError:
                continue
        if name is None:
            raise RuntimeError("could not reserve temporary routing tile directory")
        tiles_descriptor = os.open(name, directory_flags, dir_fd=parent_descriptor)
        owned_identity = (
            os.fstat(tiles_descriptor).st_dev,
            os.fstat(tiles_descriptor).st_ino,
        )
        tiles = work / name

        def require_owned_directory(
            parent: int,
            entry: str,
            identity: tuple[int, int],
            identity_error: str,
        ) -> None:
            try:
                current = os.stat(
                    entry, dir_fd=parent, follow_symlinks=False
                )
            except FileNotFoundError as error:
                raise RuntimeError(identity_error) from error
            if (
                not stat.S_ISDIR(current.st_mode)
                or (current.st_dev, current.st_ino) != identity
            ):
                raise RuntimeError(identity_error)

        def remove_owned_directory(
            parent: int,
            entry: str,
            descriptor: int,
            identity: tuple[int, int],
            description: str,
            identity_error: str,
        ) -> None:
            cleanup_attempts = 16
            for attempt in range(1, cleanup_attempts + 1):
                for child_entry in os.listdir(descriptor):
                    try:
                        child_status = os.stat(
                            child_entry,
                            dir_fd=descriptor,
                            follow_symlinks=False,
                        )
                    except FileNotFoundError:
                        continue
                    if stat.S_ISDIR(child_status.st_mode):
                        try:
                            child = os.open(
                                child_entry, directory_flags, dir_fd=descriptor
                            )
                        except FileNotFoundError:
                            continue
                        try:
                            opened = os.fstat(child)
                            child_identity = (opened.st_dev, opened.st_ino)
                            if child_identity != (
                                child_status.st_dev,
                                child_status.st_ino,
                            ):
                                raise RuntimeError(
                                    "routing tile directory entry changed during cleanup"
                                )
                            remove_owned_directory(
                                descriptor,
                                child_entry,
                                child,
                                child_identity,
                                f"routing tile directory entry {child_entry!r}",
                                "routing tile directory entry changed during cleanup",
                            )
                        finally:
                            os.close(child)
                    else:
                        try:
                            os.unlink(child_entry, dir_fd=descriptor)
                        except FileNotFoundError:
                            continue
                require_owned_directory(
                    parent, entry, identity, identity_error
                )
                try:
                    os.rmdir(entry, dir_fd=parent)
                except OSError as error:
                    if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                        raise
                    # Directory enumeration and rmdir are not one atomic
                    # operation. A late Valhalla writer may add an entry after
                    # the drain, so retry the complete descriptor-relative
                    # traversal. Rechecking the path identity on every pass
                    # keeps a replacement directory out of the deletion walk.
                    require_owned_directory(
                        parent, entry, identity, identity_error
                    )
                    if attempt == cleanup_attempts:
                        remaining = sorted(os.listdir(descriptor))
                        sample = ", ".join(
                            repr(remaining_entry)
                            for remaining_entry in remaining[:5]
                        )
                        if len(remaining) > 5:
                            sample += ", ..."
                        raise RuntimeError(
                            f"{description} remained non-empty "
                            f"after {cleanup_attempts} cleanup attempts; "
                            "possible active writer"
                            + (f" (remaining: {sample})" if sample else "")
                        ) from error
                    time.sleep(min(0.001 * (2 ** (attempt - 1)), 0.05))
                else:
                    # rmdir is path-based: the entry can be replaced after
                    # the preceding identity check but before the syscall.
                    # POSIX does not expose descriptor-relative removal of an
                    # already-open directory. Prove that rmdir unlinked this
                    # opened inode rather than an empty replacement; otherwise
                    # fail visibly instead of reporting successful cleanup.
                    if os.fstat(descriptor).st_nlink != 0:
                        raise RuntimeError(identity_error)
                    return

        def cleanup() -> None:
            remove_owned_directory(
                parent_descriptor,
                name,
                tiles_descriptor,
                owned_identity,
                "temporary routing tile directory",
                "temporary routing tile directory identity changed; refusing cleanup",
            )

        try:
            require_paths_outside_directory(tiles, protected_paths)
            yield tiles
        except BaseException as body_error:
            try:
                cleanup()
            except BaseException as cleanup_error:
                raise BaseExceptionGroup(
                    "routing tile work failed and cleanup also failed",
                    [body_error, cleanup_error],
                )
            raise
        else:
            cleanup()
    finally:
        if tiles_descriptor is not None:
            os.close(tiles_descriptor)
        os.close(parent_descriptor)


def main() -> None:
    pipeline_started = time.perf_counter()
    args = parse_args()
    if args.concurrency <= 0:
        raise ValueError("concurrency must be positive")
    if args.expansion_concurrency <= 0:
        raise ValueError("expansion concurrency must be positive")
    if args.expansion_batch_size <= 0:
        raise ValueError("expansion batch size must be positive")

    work = Path.cwd() / "work"
    output = args.output.resolve()
    work.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)

    osm_timestamp = capture(
        "read OSM snapshot timestamp",
        ["osmium", "fileinfo", "-g", "header.option.osmosis_replication_timestamp", args.pbf],
    )
    shelter_refreshed_at = read_shelter_refreshed_at(args.shelter_refreshed_at)

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
    (work / "lithuania-boundary.raw.geojson").unlink()

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
    transit_path.unlink()
    detail_config_path.unlink()
    # tilemaker writes valid but unclustered high-zoom archives whose first
    # z15 lookup can require a multi-megabyte leaf-directory range. Reorder
    # these in place; the established basemap/access/destination archives are
    # already acceptably laid out.
    run(
        "cluster high-zoom detail PMTiles",
        ["pmtiles", "cluster", output / "details.pmtiles"],
    )

    inspector_command = [
        "tilemaker",
        "--fast",
        "--input",
        args.pbf,
        "--output",
        output / "inspector.pmtiles",
        "--config",
        args.inspector_config,
        "--process",
        args.inspector_process,
        "--threads",
        args.concurrency,
    ]
    inspector_command.extend(["--bbox", ",".join(str(value) for value in args.bbox)])
    run("build on-demand OSM inspector", inspector_command)
    # The inspector has the same high-cardinality z15-16 shape as details.
    # Cluster it before publication so first-click tile reads stay bounded.
    run(
        "cluster high-zoom inspector PMTiles",
        ["pmtiles", "cluster", output / "inspector.pmtiles"],
    )

    with timed("prepare service locations"):
        prepared = prepare_places(args, work, country)

    with routing_tiles_directory(
        work, [("PBF input", args.pbf), ("output directory", output)]
    ) as tiles:
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
                    # Classified native relation batches are build intermediates.
                    work,
                    args.expansion_concurrency,
                    args.expansion_batch_size,
                    ",".join(str(minutes) for minutes in route["minutes"]),
                    bbox_arg,
                    key,
                    route["service"],
                    route["mode"],
                ],
            )
            requests_path.unlink()
            for _location, place_feature in entries:
                place_feature["properties"][f"{route['mode']}_routing_status"] = "routed"
            routed_counts[key] = len(entries)

    config_path.unlink()

    destination_lookup_command = [
        sys.executable,
        args.destination_lookup_tool,
        "--native-tool",
        args.destination_lookup_native_tool,
        "--database",
        work / "destination-lookup.sqlite",
        "--manifest-out",
        work / "destination-lookup.json",
    ]
    for route in ROUTE_SPECS:
        destination_lookup_command.extend(
            [
                "--route",
                f"{route['service']}:{route['mode']}:{work / relation_handoff_filename(route)}",
            ]
        )
    run("build shared destination edge relations", destination_lookup_command)
    destination_lookup_manifest = json.loads(
        (work / "destination-lookup.json").read_text(encoding="utf-8")
    )
    (work / "destination-lookup.json").unlink()
    for route in ROUTE_SPECS:
        (work / relation_handoff_filename(route)).unlink()

    place_features = [
        feature
        for service in SERVICE_SPECS
        for _location, feature in prepared[service["id"]]
    ]
    # The full GeoJSON is an encoder input, not a web API. Write it before the
    # parallel section; only the later places tilemaker consumes it, so access
    # remains the sole tilemaker process while the catalog branch is active.
    write_json(work / "places.geojson", feature_collection(place_features, country_bbox))
    lookup_database_path = work / "destination-lookup.sqlite"

    def build_catalog_branch():
        with timed("post-normalization catalog branch"):
            # Rich object records, compact locations and every destination
            # membership set share one paged PMTiles archive.
            objects_path = work / "objects.json"
            write_json(objects_path, object_catalog(place_features))
            catalog_manifest_path = work / "catalog-manifest.json"
            run(
                "pack paged object catalog",
                [
                    sys.executable,
                    args.catalog_tool,
                    "--objects",
                    objects_path,
                    "--lookup-database",
                    lookup_database_path,
                    "--mbtiles-out",
                    work / "catalog.mbtiles",
                    "--manifest-out",
                    catalog_manifest_path,
                ],
            )
            catalog_manifest = json.loads(
                catalog_manifest_path.read_text(encoding="utf-8")
            )
            objects_path.unlink()
            run(
                "convert paged object catalog to PMTiles",
                ["pmtiles", "convert", work / "catalog.mbtiles", output / "catalog.pmtiles"],
            )
            (work / "catalog.mbtiles").unlink()
            # MBTiles already carries the complete catalog contract in its
            # `json` metadata. Prove conversion retained it before making the
            # only required in-place header correction.
            catalog_archive_metadata = json.loads(
                capture(
                    "read paged catalog PMTiles metadata",
                    ["pmtiles", "show", output / "catalog.pmtiles", "--metadata"],
                )
            )
            if catalog_archive_metadata != catalog_manifest:
                raise RuntimeError(
                    "catalog PMTiles did not retain the packed catalog manifest"
                )
            catalog_header = json.loads(
                capture(
                    "read paged catalog PMTiles header",
                    ["pmtiles", "show", output / "catalog.pmtiles", "--header-json"],
                )
            )
            if catalog_header.get("tile_type") not in ("", "unknown", "Unknown"):
                raise RuntimeError("catalog PMTiles did not retain Unknown tile type")
            catalog_header["tile_compression"] = "gzip"
            catalog_header_path = work / "catalog-header.json"
            write_json(catalog_header_path, catalog_header)
            run(
                "set paged catalog compression header",
                [
                    "pmtiles",
                    "edit",
                    output / "catalog.pmtiles",
                    "--header-json",
                    catalog_header_path,
                ],
            )
            catalog_header_path.unlink()
            run(
                "verify paged object catalog",
                ["pmtiles", "verify", output / "catalog.pmtiles"],
            )
            with (output / "catalog.pmtiles").open("rb") as catalog_file:
                catalog_digest = hashlib.file_digest(catalog_file, "sha256").hexdigest()
            catalog_filename = f"catalog-{catalog_digest}.pmtiles"
            (output / "catalog.pmtiles").rename(output / catalog_filename)
            catalog_manifest_path.unlink()
            return catalog_filename, catalog_manifest

    def build_access_branch():
        with timed("post-normalization access branch"):
            # Both post-normalization branches are read-only SQLite consumers.
            # Start this ordered merge beside catalog packing instead of
            # serializing two complete scans of the country-wide edge table.
            run(
                "merge normalized edge relations into unified network",
                [
                    args.expansion_helper,
                    "--merge-network-db",
                    # network.geojson is a tilemaker input only (never
                    # published); see the unified-access design document.
                    work / "network.geojson",
                    bbox_arg,
                    lookup_database_path,
                    "--groups-out",
                    work / "network-groups.json",
                ],
            )
            # Low-zoom fast-path (docs/lowzoom-fastpath.md): derive the
            # encoder-grid skeleton (z8-13 tiles) and the short-chain-filtered
            # subset (z6-7 tiles) from the already-merged network.
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
            network_config_path = work / "access.json"
            write_json(network_config_path, network_tile_config(work))
            run(
                "build unified access PMTiles",
                [
                    "tilemaker",
                    "--fast",
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
            network_config_path.unlink()
            (work / "network.geojson").unlink()
            (work / "network-lowzoom.geojson").unlink()
            (work / "network-lowzoom-z67.geojson").unlink()

    # The normalized database is the common immutable boundary: catalog pages
    # and the access network are independent projections of it. Reap both
    # projections before removing their shared input, including on failure.
    branch_error = None
    try:
        branch_results = run_parallel_branches(
            {"catalog": build_catalog_branch, "access": build_access_branch}
        )
    except Exception as error:
        branch_error = error
        raise
    finally:
        try:
            lookup_database_path.unlink()
        except OSError as cleanup_error:
            if branch_error is None:
                raise
            branch_error.add_note(
                f"could not remove joined-branch database: {cleanup_error}"
            )
    catalog_filename, catalog_manifest = branch_results["catalog"]

    # Keep this outside the overlap: access is the only tilemaker in the
    # parallel section, avoiding two full-thread-count tilemakers competing.
    places_config = work / "places.json"
    write_json(places_config, places_tile_config(work))
    run(
        "build service destination PMTiles",
        [
            "tilemaker",
            "--fast",
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
    places_config.unlink()
    (work / "places.geojson").unlink()

    # Feature-state group table (docs/unified-access-layer.md): the native
    # writer emits each compact property map alongside the corresponding
    # network feature in the same ordered loop. Reading that small sidecar
    # avoids materializing the country-wide geometry in Python while retaining
    # explicit count and g/file-order validation. R-L5: `g` is a per-build
    # index and must never be persisted client-side across deploys; URL state
    # stores requirement keys/minutes, never group ids, and index.html + data
    # deploy atomically.
    with timed("read attribute-map groups for metadata"):
        access_groups = read_access_groups(
            work / "network-groups.json", REQUIREMENT_KEYS
        )
    (work / "network-groups.json").unlink()

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
                # property (feature-state styling). Per-build; never persist
                # g across deploys.
                "groups": access_groups,
                "layer": "network",
                # Informational (docs/lowzoom-fastpath.md):
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
            "destination_lookup": {
                "schema_version": destination_lookup_manifest["schema_version"],
                # Catalog packing is the authoritative canonical serialization
                # pass for requirements, sets and edges, so it owns this ID.
                "edge_build_id": catalog_manifest["edge_build_id"],
                "edge_collection": destination_lookup_manifest["edge_collection"],
                "edge_count": destination_lookup_manifest["edge_count"],
                "requirements": destination_lookup_manifest["requirements"],
                "coordinate_encoding": destination_lookup_manifest["coordinate_encoding"],
                "fraction_semantics": destination_lookup_manifest["fraction_semantics"],
                "hit": {
                    "file": catalog_filename,
                    "zoom": catalog_manifest["spatial"]["zoom"],
                    "addressing": catalog_manifest["spatial"]["addressing"],
                    "candidate_encoding": catalog_manifest["spatial"]["candidate_encoding"],
                    "neighbor_radius": catalog_manifest["spatial"]["neighbor_radius"],
                    "mode_bits": MODE_BITS,
                },
            },
            "basemap": {
                "file": "lithuania.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "max_data_zoom": 14,
                "min_data_zoom": 4,
                "tilemaker_version": args.tilemaker_version,
            },
            "catalog": {"file": catalog_filename, **catalog_manifest},
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
                    "micro_markers": "shape_first_pictograms; never_color_only",
                    "drinking_water_marker_min_zoom": 15,
                    "drinking_water_badge_min_zoom": 16,
                    "proper_name": ["name", "name:lt", "name:en"],
                    "rank": "lower_values_win_collisions",
                    "street_class": ["bench", "tree"],
                    "street_marker_min_zoom": {"bench": 17, "tree": 18},
                    "transit_kind": ["station", "halt", "terminal", "stop"],
                    "transit_modes": ["train", "subway", "tram", "trolleybus", "bus", "ferry"],
                    "transit_mode_count": "number_of_distinct_detected_modes",
                    "transit_platform_count": "canonicalized_source_members",
                    "transit_ref": "short_explicit_ref_only",
                    "transit_marker_min_zoom": {
                        "named_transit_feature": 15,
                        "unnamed_stop": 18,
                    },
                    "transit_marker_semantics": "mode_specific_and_multimodal_pictograms; exact_modes_in_modal",
                    "transit_label_min_zoom": {
                        "station_or_terminal": 15,
                        "interchange_or_halt": 16,
                        "local_stop": 17,
                    },
                },
                "display_max_zoom": 18,
                "display_min_zoom": 15,
                "file": "details.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "layers": {
                    "building_details": "building_details",
                    "micro_details": "micro_details",
                    "poi_details": "poi_details",
                    "street_details": "street_details",
                    "transit_details": "transit_details",
                    "water_details": "water_details",
                },
                "max_data_zoom": 16,
                "min_data_zoom": 15,
                "overzoom": {
                    "from_zoom": 17,
                    "source_zoom": 16,
                    "through_zoom": 18,
                },
                # Both water_details and street_details extend the prior v4
                # detail schema; publish their combined contract as v6 rather
                # than reusing either feature branch's independent v5 bump.
                "schema_version": 6,
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
            "inspector": {
                # tilemaker 3.1 does not retain filemetadata.attribution in its
                # PMTiles JSON. The inspector is never used as a standalone
                # map; the enclosing basemap always displays osm_attribution.
                "attribution_policy": "enclosing_map_osm_attribution",
                "description": (
                    "High-zoom configured search-family destinations and road-direction "
                    "geometry; loaded only for an explicit inspection"
                ),
                "attributes": {
                    "common": {
                        "required": ["osm_type", "osm_id", "status"],
                        "osm_id": "exact_decimal_string",
                        "osm_type": ["node", "way", "relation"],
                        "status": ["active", "abandoned", "closed", "disused", "proposed", "removed"],
                        "optional_identity_tags": [
                            "name", "name:lt", "name:en", "int_name", "official_name",
                            "brand", "operator", "addr:city", "addr:housename",
                            "addr:housenumber", "addr:place", "addr:postcode", "addr:street",
                        ],
                    },
                    "destination": {
                        "required": ["category", "kind", "search_service"],
                        "search_service": ["coffee", "hospital", "supermarket", "fuel"],
                        "kind": [
                            "cafe", "restaurant", "coffee_shop", "hospital",
                            "supermarket", "fuel",
                        ],
                        "optional_source_tags": [
                            "amenity", "healthcare", "shop", "access", "foot", "wheelchair",
                            "opening_hours", "cuisine", "phone", "contact:phone", "email",
                            "contact:email", "website", "contact:website",
                        ],
                    },
                    "road": {
                        "required": {"category": "transport", "highway": "source value"},
                        "kind": "highway source value",
                        "highway": [
                            "motorway", "motorway_link", "trunk", "trunk_link",
                            "primary", "primary_link", "secondary", "secondary_link",
                            "tertiary", "tertiary_link", "unclassified", "residential",
                            "living_street", "service", "pedestrian", "track", "road",
                            "path", "footway", "cycleway", "bridleway", "steps", "corridor",
                        ],
                        "optional_source_tags": [
                            "access", "foot", "ref", "oneway", "destination",
                            "destination:ref", "destination:street", "surface", "smoothness",
                        ],
                    },
                },
                "file": "inspector.pmtiles",
                "format": "PMTiles v3 with Mapbox Vector Tiles",
                "layers": {
                    "points": "inspect_points",
                    "lines": "inspect_lines",
                    "areas": "inspect_areas",
                },
                "max_data_zoom": INSPECTOR_MAX_ZOOM,
                "min_data_zoom": INSPECTOR_MIN_ZOOM,
                "pmtiles_cli_version": args.pmtiles_cli_version,
                "schema_version": 4,
                "tilemaker_version": args.tilemaker_version,
            },
            "osm_attribution": "© OpenStreetMap contributors, ODbL 1.0",
            "osm_source": args.osm_source_url,
            "places": {
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
            # Non-OSM data source: the pinned PAGD shelter snapshot. The client
            # shows refreshed_at in the map's data-sources line and uses
            # attribution as the authoritative source/licence credit (required
            # by CC BY 4.0), so the credit text lives in one place. Per-service
            # counts are already in services[].place_count; the load log prints
            # the per-dataset split.
            "shelters": {
                "refreshed_at": shelter_refreshed_at,
                "attribution": (
                    "Priešgaisrinės apsaugos ir gelbėjimo departamentas (PAGD),"
                    " CC BY 4.0"
                ),
            },
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
