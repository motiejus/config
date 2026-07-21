#!/usr/bin/env python3

"""Build the normalized shared-destination SQLite handoff."""

import argparse
import json
import os
from pathlib import Path
import re
import resource
import sqlite3
import subprocess
import sys
import time


MODE_BITS = {"walk": 1, "drive": 2}
EDGE_COLLECTION = "destination_edges"
SCHEMA_VERSION = 3
SPATIAL_ZOOM = 15
_ROUTE = re.compile(r"([a-z]+):([a-z]+):(.+)")


def canonical_json(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def parse_route(value: str) -> tuple[str, str, Path]:
    match = _ROUTE.fullmatch(value)
    if match is None or match.group(2) not in MODE_BITS:
        raise argparse.ArgumentTypeError("route must be SERVICE:walk|drive:MEMBERSHIP_DUMP")
    return match.group(1), match.group(2), Path(match.group(3))


def requirements_manifest(database: sqlite3.Connection) -> list[dict]:
    result = []
    for ordinal, key, service, mode, mode_bit in database.execute(
        "SELECT requirement,key,service,mode,mode_bit FROM requirements ORDER BY requirement"
    ):
        if ordinal != len(result):
            raise ValueError("non-contiguous requirement ordinals")
        presets = []
        for minute, collection, count in database.execute(
            "SELECT minute,collection,set_count FROM presets WHERE requirement=? ORDER BY minute",
            (ordinal,),
        ):
            presets.append({"minutes": minute, "set_collection": collection, "set_count": count})
        result.append(
            {"key": key, "service": service, "mode": mode, "mode_bit": mode_bit, "presets": presets}
        )
    return result


def normalization_counts(database: sqlite3.Connection) -> tuple[int, int]:
    metadata = dict(database.execute("SELECT key,value FROM metadata"))
    expected = {"schema_version", "spatial_zoom", "edge_count", "spatial_hit_count"}
    if set(metadata) != expected:
        raise ValueError("native relation finalizer left incompatible metadata")
    if metadata["schema_version"] != str(SCHEMA_VERSION):
        raise ValueError("native relation finalizer used an incompatible schema version")
    if metadata["spatial_zoom"] != str(SPATIAL_ZOOM):
        raise ValueError("native relation finalizer used an incompatible spatial zoom")

    counts = []
    for name in ("edge_count", "spatial_hit_count"):
        encoded = metadata[name]
        if not isinstance(encoded, str) or re.fullmatch(r"[1-9][0-9]*", encoded) is None:
            raise ValueError(f"native relation finalizer left invalid {name}")
        counts.append(int(encoded))
    edge_count, spatial_hit_count = counts
    if spatial_hit_count < edge_count:
        raise ValueError("native relation finalizer left too few spatial candidates")
    return edge_count, spatial_hit_count


def same_file_identity(left: Path, right: Path) -> bool:
    if left.resolve(strict=False) == right.resolve(strict=False):
        return True
    try:
        return os.path.samefile(left, right)
    except FileNotFoundError:
        return False


def require_distinct_paths(paths: list[tuple[str, Path]]) -> None:
    for left_index, (left_name, left_path) in enumerate(paths):
        for right_name, right_path in paths[left_index + 1:]:
            if same_file_identity(left_path, right_path):
                raise ValueError(
                    f"{left_name} and {right_name} must identify different files"
                )


def build(routes, database_path: Path, manifest_path: Path,
          native_tool: Path) -> dict:
    started = time.perf_counter()
    ordered = sorted(routes, key=lambda route: (route[0], route[1]))
    if not ordered or len({(service, mode) for service, mode, _ in ordered}) != len(ordered):
        raise ValueError("routes must be nonempty and unique by service/mode")
    outputs = [
        ("database output", database_path),
        ("manifest output", manifest_path),
    ]
    route_inputs = [
        (f"route input {service}/{mode}", path)
        for service, mode, path in ordered
    ]
    require_distinct_paths(outputs)
    for output in outputs:
        for route_input in route_inputs:
            require_distinct_paths([output, route_input])
    command = [native_tool, "--finalize-relations", "--database", database_path]
    for service, mode, path in ordered:
        command.extend(("--route", f"{service}:{mode}:{path}"))
    subprocess.run([str(value) for value in command], check=True)
    database = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)
    try:
        edge_count, _spatial_hit_count = normalization_counts(database)
        empty = database.execute(
            "SELECT requirement,minute FROM presets WHERE set_count IS NULL OR set_count=0 LIMIT 1"
        ).fetchone()
        if empty is not None:
            raise ValueError(f"native relation finalizer left empty preset {empty}")
        requirements = requirements_manifest(database)
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "edge_collection": EDGE_COLLECTION,
            "edge_count": edge_count,
            "requirements": requirements,
            "coordinate_encoding": {
                "scale": 10_000_000,
                "order": "lon_lat",
                "delta": "first_pair_absolute_then_signed_deltas",
            },
            "fraction_semantics": "closed_source_intervals; exact breakpoint override; open interior runs",
            "spatial": {
                "zoom": SPATIAL_ZOOM,
                "candidate_encoding": "sorted [edge_id,mode_mask] arrays",
                "neighbor_radius": 1,
            },
        }
        manifest_path.write_bytes(canonical_json(manifest) + b"\n")
        elapsed = time.perf_counter() - started
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        print(
            f"[mapgames] lookup complete: {manifest['edge_count']} edges, {elapsed:.3f}s, "
            f"maxrss={rss} KiB, sqlite={database_path.stat().st_size} bytes",
            file=sys.stderr,
        )
        return manifest
    finally:
        database.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--route", action="append", type=parse_route, required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    parser.add_argument("--native-tool", type=Path, required=True)
    args = parser.parse_args()
    build(args.route, args.database, args.manifest_out, args.native_tool)


if __name__ == "__main__":
    main()
