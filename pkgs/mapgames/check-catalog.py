#!/usr/bin/env python3

"""Real-PMTiles check for streamed synthetic and spatial catalog pages."""

import argparse
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
import gzip
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time


def fnv1a32(value: str) -> int:
    result = 2_166_136_261
    for byte in value.encode("utf-8"):
        result ^= byte
        result = (result * 16_777_619) & 0xFFFFFFFF
    return result


def pmtiles_page(pmtiles, archive, zoom, x, y):
    payload = subprocess.run(
        [pmtiles, "tile", archive, str(zoom), str(x), str(y)],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    return gzip.decompress(payload) if payload.startswith(b"\x1f\x8b") else payload


def check_parallel_branches(generate_source: str) -> None:
    support_source = generate_source[
        generate_source.index("def run_parallel_branches"):
        generate_source.index("def write_json")
    ]
    namespace = {
        "Callable": Callable,
        "ThreadPoolExecutor": ThreadPoolExecutor,
    }
    exec(compile(support_source, "generate-parallel-support", "exec"), namespace)
    run_parallel_branches = namespace["run_parallel_branches"]

    def slow_first():
        time.sleep(0.02)
        return "first-result"

    results = run_parallel_branches(
        {"first": slow_first, "second": lambda: "second-result"}
    )
    assert list(results.items()) == [
        ("first", "first-result"),
        ("second", "second-result"),
    ]

    sibling_finished = []

    def failing_branch():
        raise RuntimeError("primary branch failure")

    def finishing_sibling():
        time.sleep(0.02)
        sibling_finished.append(True)

    try:
        run_parallel_branches(
            {"failing": failing_branch, "sibling": finishing_sibling}
        )
    except RuntimeError as error:
        assert str(error) == "primary branch failure"
    else:
        raise AssertionError("single branch failure was not propagated")
    assert sibling_finished == [True], "failed overlap abandoned its running sibling"

    def slow_first_failure():
        time.sleep(0.02)
        raise ValueError("first failure")

    def quick_second_failure():
        raise KeyError("second failure")

    try:
        run_parallel_branches(
            {"first": slow_first_failure, "second": quick_second_failure}
        )
    except ExceptionGroup as errors:
        assert [type(error) for error in errors.exceptions] == [ValueError, KeyError]
    else:
        raise AssertionError("multiple branch failures were not propagated")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog-tool", type=Path, required=True)
    parser.add_argument("--destination-tool", type=Path, required=True)
    parser.add_argument("--destination-native-tool", type=Path, required=True)
    parser.add_argument("--generate", type=Path, required=True)
    parser.add_argument("--pmtiles", type=Path, required=True)
    args = parser.parse_args()
    generate_source = args.generate.read_text(encoding="utf-8")
    assert "args.expansion_output_concurrency" not in generate_source
    assert "if args.expansion_batch_size <= 0:" in generate_source
    assert "lithuania-boundary.raw.geojson" in generate_source
    assert "mapping(country)" in generate_source
    catalog_branch = generate_source[
        generate_source.index("def build_catalog_branch("):
        generate_source.index("def build_access_branch(")
    ]
    assert catalog_branch.count('"edit"') == 1
    assert '"--header-json"' in catalog_branch and '"--metadata"' in catalog_branch
    assert "lookup_database_path" in catalog_branch
    access_branch = generate_source[
        generate_source.index("def build_access_branch("):
        generate_source.index("branch_results = run_parallel_branches")
    ]
    assert "lookup_database_path" in access_branch
    assert "merge normalized edge relations into unified network" in access_branch
    assert "derive low-zoom skeleton from unified network" in access_branch
    assert "build unified access PMTiles" in access_branch
    parallel_start = generate_source.index("branch_results = run_parallel_branches")
    assert '"catalog": build_catalog_branch, "access": build_access_branch' in generate_source
    joined_cleanup = generate_source[
        parallel_start:generate_source.index(
            "catalog_filename, catalog_manifest", parallel_start
        )
    ]
    assert "finally:" in joined_cleanup
    assert "lookup_database_path.unlink()" in joined_cleanup
    assert "if branch_error is None:" in joined_cleanup
    assert parallel_start < generate_source.index("build service destination PMTiles")
    assert "ThreadPoolExecutor" in generate_source
    boundary_cleanup = '(work / "lithuania-boundary.raw.geojson").unlink()'
    assert (
        generate_source.index("build lean vector basemap")
        < generate_source.index(boundary_cleanup)
        < generate_source.index("canonicalize public transport stops")
    )
    check_parallel_branches(generate_source)
    for cleanup in (
        "places_pbf.unlink()",
        "raw_places_path.unlink()",
        boundary_cleanup,
        "requests_path.unlink()",
        "shutil.rmtree(tiles)",
        "config_path.unlink()",
        "relation_handoff_filename(route)).unlink()",
        "objects_path.unlink()",
        "lookup_database_path.unlink()",
        '(work / "catalog.mbtiles").unlink()',
        "network_config_path.unlink()",
        '(work / "network.geojson").unlink()',
        '(work / "network-lowzoom.geojson").unlink()',
        '(work / "network-lowzoom-z67.geojson").unlink()',
        "places_config.unlink()",
        '(work / "places.geojson").unlink()',
    ):
        assert cleanup in generate_source, cleanup
    assert generate_source.index("requests_path.unlink()") > generate_source.index(
        "compute {key} native reverse expansion lines"
    )
    assert generate_source.index("shutil.rmtree(tiles)") > generate_source.index(
        "requests_path.unlink()"
    )
    assert generate_source.index("relation_handoff_filename(route)).unlink()") > (
        generate_source.index("build shared destination edge relations")
    )
    assert access_branch.index("merge normalized edge relations into unified network") < (
        access_branch.index("derive low-zoom skeleton from unified network")
    )
    assert generate_source.index('(work / "catalog.mbtiles").unlink()') > (
        generate_source.index("convert paged object catalog to PMTiles")
    )
    assert generate_source.index('(work / "network.geojson").unlink()') > (
        generate_source.index("build unified access PMTiles")
    )
    assert generate_source.index('(work / "places.geojson").unlink()') > (
        generate_source.index("build service destination PMTiles")
    )
    with tempfile.TemporaryDirectory(prefix="catalog-check-") as directory:
        work = Path(directory)
        geometry = "250000000,550000000;250100000,550000000;"
        relations = work / "relations-coffee-walk.bin"
        with relations.open("wb") as output:
            output.write(b"MAPGAMES-REL-01\0")
            output.write(struct.pack("<III", 1, 1, 5))
            output.write(struct.pack("<II", 0xB47C4E01, 2))
            output.write(struct.pack("<II", 1, 0))
            output.write(struct.pack("<III", 2, 0, 1))
            output.write(struct.pack("<IQIiiiiI", 1, 1, 2,
                                     250000000, 550000000,
                                     250100000, 550000000, 1))
            output.write(struct.pack("<II", 0, 2))
            output.write(struct.pack("<ddIddI", 0, .5, 0, .5, 1, 1))
            output.write(struct.pack("<I", 3))
            output.write(struct.pack("<dIdIdI", 0, 0, .5, 1, 1, 1))
        lookup = work / "lookup.sqlite"
        lookup_manifest = work / "lookup.json"
        subprocess.run(
            [
                sys.executable, str(args.destination_tool),
                "--native-tool", str(args.destination_native_tool),
                "--route", f"coffee:walk:{relations}",
                "--database", str(lookup), "--manifest-out", str(lookup_manifest),
            ],
            check=True,
        )
        objects = [
            {"index": 0, "place_id": "coffee:n1", "service": "coffee", "lon": 25, "lat": 55},
            {"index": 1, "place_id": "coffee:n2", "service": "coffee", "lon": 25.1, "lat": 55},
            {
                "index": 2,
                "place_id": "pharmacy:n3",
                "service": "pharmacy",
                "kind": "pharmacy",
                "lon": 25.2,
                "lat": 55,
            },
        ]
        objects_path = work / "objects.json"
        objects_path.write_text(json.dumps(objects, ensure_ascii=False))
        notes = [{"place_id": "pharmacy:n3", "note": "quality-only record"}]
        notes_path = work / "generic-notes.json"
        notes_path.write_text(json.dumps(notes, ensure_ascii=False))
        empty_path = work / "generic-empty.json"
        empty_path.write_text("[]\n", encoding="utf-8")

        def aliased_path(case: Path, target: Path, identity: str, label: str):
            alias = case / f"{label}-{identity}"
            if identity == "lexical":
                parent = case / f"{label}-parent"
                parent.mkdir()
                return parent / ".." / target.name
            try:
                if identity == "symlink":
                    alias.symlink_to(target.name)
                elif identity == "hardlink":
                    os.link(target, alias)
                else:
                    raise AssertionError(identity)
            except OSError:
                return None
            return alias

        def reject_input_output_alias(
            output_name: str, input_name: str, identity: str,
        ) -> None:
            case = work / f"alias-{output_name}-{input_name}-{identity}"
            case.mkdir()
            case_objects = case / "objects.json"
            case_lookup = case / "lookup.sqlite"
            case_records = case / "records.json"
            shutil.copy2(objects_path, case_objects)
            shutil.copy2(lookup, case_lookup)
            shutil.copy2(notes_path, case_records)
            inputs = {
                "objects": case_objects,
                "lookup": case_lookup,
                "records": case_records,
            }
            outputs = {
                "mbtiles": case / "catalog.mbtiles",
                "manifest": case / "catalog.json",
            }
            alias = aliased_path(case, inputs[input_name], identity, output_name)
            if alias is None:
                return
            outputs[output_name] = alias
            before = {name: path.read_bytes() for name, path in inputs.items()}
            rejected = subprocess.run(
                [
                    sys.executable, str(args.catalog_tool),
                    "--objects", str(case_objects),
                    "--lookup-database", str(case_lookup),
                    "--mbtiles-out", str(outputs["mbtiles"]),
                    "--manifest-out", str(outputs["manifest"]),
                    "--record-collection", f"generic_records={case_records}",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert rejected.returncode != 0
            assert b"must identify different files" in rejected.stderr, rejected.stderr
            assert before == {
                name: path.read_bytes() for name, path in inputs.items()
            }, f"{output_name}/{input_name}/{identity} modified an input"

        # Exercise all six destructive input/output pairs through a lexical
        # alias, plus filesystem identity that resolve() alone cannot cover.
        for output_name in ("mbtiles", "manifest"):
            for input_name in ("objects", "lookup", "records"):
                reject_input_output_alias(output_name, input_name, "lexical")
        reject_input_output_alias("mbtiles", "records", "symlink")
        reject_input_output_alias("manifest", "lookup", "hardlink")

        same_output = work / "aliased-output"
        output_alias = work / "aliased-output-parent"
        output_alias.mkdir()
        rejected = subprocess.run(
            [
                sys.executable, str(args.catalog_tool),
                "--objects", str(objects_path),
                "--lookup-database", str(lookup),
                "--mbtiles-out", str(same_output),
                "--manifest-out", str(output_alias / ".." / same_output.name),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert rejected.returncode != 0
        assert b"must identify different files" in rejected.stderr, rejected.stderr
        assert not same_output.exists()

        mbtiles = work / "catalog.mbtiles"
        manifest_path = work / "catalog.json"
        subprocess.run(
            [
                sys.executable, str(args.catalog_tool), "--objects", str(objects_path),
                "--lookup-database", str(lookup), "--mbtiles-out", str(mbtiles),
                "--manifest-out", str(manifest_path),
                "--record-collection", f"generic_notes={notes_path}",
                "--record-collection", f"generic_empty={empty_path}",
            ],
            check=True,
        )

        corruptions = {
            "out-of-bounds": (
                struct.pack("<iiii", 1_800_000_000, 0, 1, 0),
                b"coordinate out of bounds",
            ),
            "degenerate": (struct.pack("<iiii", 0, 0, 0, 0), b"degenerate"),
            "noncanonical": (
                struct.pack("<iiii", 250_000_000, 550_000_000, -1_000_000, 0),
                b"non-canonical",
            ),
        }
        for name, (geometry_blob, expected_error) in corruptions.items():
            corrupt_lookup = work / f"lookup-{name}.sqlite"
            shutil.copy2(lookup, corrupt_lookup)
            with sqlite3.connect(corrupt_lookup) as corrupt:
                corrupt.execute("UPDATE edges SET delta_coords=?", (geometry_blob,))
            rejected = subprocess.run(
                [
                    sys.executable, str(args.catalog_tool),
                    "--objects", str(objects_path),
                    "--lookup-database", str(corrupt_lookup),
                    "--mbtiles-out", str(work / f"catalog-{name}.mbtiles"),
                    "--manifest-out", str(work / f"catalog-{name}.json"),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert rejected.returncode != 0, name
            assert expected_error in rejected.stderr, (name, rejected.stderr)

        manifest = json.loads(manifest_path.read_text())
        assert manifest["schema_version"] == 2
        assert "edge_build_id" not in json.loads(lookup_manifest.read_text())
        assert len(manifest["edge_build_id"]) == 64
        assert manifest["collections"]["object_locations"]["count"] == 3
        assert manifest["collections"]["generic_notes"]["count"] == 1
        assert manifest["collections"]["generic_empty"] == {
            "base": manifest["collections"]["generic_empty"]["base"],
            "count": 0,
            "page_size": 32,
            "pages": 0,
        }
        assert manifest["collections"]["destination_edges"]["page_size"] == 64
        fanout = manifest["spatial"]["fanout_stats"]
        assert manifest["collections"]["destination_edges"]["max_request_pages"] == (
            fanout["relation_pages_per_lookup_raw_max"]
        )
        assert manifest["spatial"]["fanout_gate"][
            "postfilter_relation_pages_per_lookup"
        ] == fanout["relation_pages_per_lookup_raw_max"]
        assert fanout["candidates_per_lookup_max"] >= 1
        spatial = sqlite3.connect(mbtiles).execute(
            "SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles WHERE zoom_level=?",
            (manifest["spatial"]["zoom"],),
        ).fetchall()
        assert spatial

        archive = work / "catalog.pmtiles"
        subprocess.run([args.pmtiles, "convert", mbtiles, archive], check=True)
        header = json.loads(
            subprocess.run(
                [args.pmtiles, "show", archive, "--header-json"], check=True,
                text=True, stdout=subprocess.PIPE,
            ).stdout
        )
        header["tile_compression"] = "gzip"
        header_path = work / "header.json"
        header_path.write_text(json.dumps(header))
        subprocess.run(
            [
                args.pmtiles, "edit", archive,
                "--header-json", header_path,
                "--metadata", manifest_path,
            ],
            check=True,
        )
        subprocess.run([args.pmtiles, "verify", archive], check=True)
        assert json.loads(pmtiles_page(args.pmtiles, archive, 18, 0, 0)) == objects
        place_collection = manifest["collections"]["place_id_index"]
        place_id = objects[2]["place_id"]
        bucket = fnv1a32(place_id) & 255
        assert json.loads(pmtiles_page(
            args.pmtiles, archive, 18, place_collection["base"] + bucket, 0
        ))[place_id] == 2
        notes_collection = manifest["collections"]["generic_notes"]
        assert json.loads(
            pmtiles_page(args.pmtiles, archive, 18, notes_collection["base"], 0)
        ) == notes
        zoom, x, tms_y, payload = spatial[0]
        y = 2**zoom - 1 - tms_y
        assert pmtiles_page(args.pmtiles, archive, zoom, x, y) == gzip.decompress(payload)
        assert json.loads(
            subprocess.run(
                [args.pmtiles, "show", archive, "--metadata"], check=True,
                text=True, stdout=subprocess.PIPE,
            ).stdout
        ) == manifest

        nonfinite_path = work / "generic-nonfinite.json"
        nonfinite_path.write_text('[{"coordinate":NaN}]\n', encoding="utf-8")
        nonfinite = subprocess.run(
            [
                sys.executable, str(args.catalog_tool), "--objects", str(objects_path),
                "--lookup-database", str(lookup),
                "--mbtiles-out", str(work / "nonfinite.mbtiles"),
                "--manifest-out", str(work / "nonfinite.json"),
                "--record-collection", f"generic_nonfinite={nonfinite_path}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert nonfinite.returncode != 0
        assert b"Out of range float values" in nonfinite.stderr, nonfinite.stderr


if __name__ == "__main__":
    main()
