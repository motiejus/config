#!/usr/bin/env python3

"""Real-PMTiles check for streamed synthetic and spatial catalog pages."""

import argparse
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import errno
import gzip
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import time


EDGE_BUILD_ID_DOMAIN = b"mapgames-catalog-edge-build-id-v3"


def canonical_json(value) -> bytes:
    return (
        json.dumps(
            value, ensure_ascii=False, allow_nan=False,
            separators=(",", ":"), sort_keys=True,
        ) + "\n"
    ).encode("utf-8")


def update_build_digest(
    digest, kind: int, name: str, page_number: int, raw: bytes,
    tile: tuple[int, int, int] | None = None,
) -> None:
    encoded_name = name.encode("utf-8")
    digest.update(
        struct.pack(
            ">BIQQB", kind, len(encoded_name), page_number, len(raw), tile is not None,
        )
    )
    digest.update(encoded_name)
    if tile is not None:
        digest.update(struct.pack(">BQQ", *tile))
    digest.update(raw)


def mbtiles_page(database, zoom: int, x: int, y: int) -> bytes:
    row = database.execute(
        "SELECT tile_data FROM tiles "
        "WHERE zoom_level=? AND tile_column=? AND tile_row=?",
        (zoom, x, 2**zoom - 1 - y),
    ).fetchone()
    assert row is not None, (zoom, x, y)
    return gzip.decompress(row[0])


def recompute_edge_build_id(mbtiles: Path, manifest: dict, requirements: list[dict]) -> str:
    digest = hashlib.sha256()
    digest.update(EDGE_BUILD_ID_DOMAIN)
    update_build_digest(digest, 0, "requirements", 0, canonical_json(requirements))
    with sqlite3.connect(mbtiles) as database:
        identity_collections = [
            preset["set_collection"]
            for requirement in requirements
            for preset in requirement["presets"]
        ] + ["destination_edges"]
        for name in identity_collections:
            collection = manifest["collections"][name]
            for page_number in range(collection["pages"]):
                raw = mbtiles_page(
                    database, manifest["page_zoom"],
                    collection["base"] + page_number, 0,
                )
                update_build_digest(digest, 1, name, page_number, raw)
        spatial_zoom = manifest["spatial"]["zoom"]
        spatial_rows = database.execute(
            "SELECT tile_column,tile_row,tile_data FROM tiles WHERE zoom_level=? "
            "ORDER BY tile_column,tile_row DESC",
            (spatial_zoom,),
        )
        for page_number, (x, tms_y, payload) in enumerate(spatial_rows):
            y = 2**spatial_zoom - 1 - tms_y
            update_build_digest(
                digest, 1, "destination_hit", page_number, gzip.decompress(payload),
                tile=(spatial_zoom, x, y),
            )
    return digest.hexdigest()


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


def check_routing_tile_lifecycle(generate_source: str) -> None:
    helper_source = generate_source[
        generate_source.index("def require_paths_outside_directory("):
        generate_source.index("def main()")
    ]
    namespace = {
        "Path": Path,
        "contextmanager": contextmanager,
        "errno": errno,
        "os": os,
        "secrets": secrets,
        "stat": stat,
        "time": time,
    }
    exec(compile(helper_source, "generate-routing-tile-support", "exec"), namespace)
    require_outside = namespace["require_paths_outside_directory"]
    routing_directory = namespace["routing_tiles_directory"]

    with tempfile.TemporaryDirectory(prefix="routing-tile-lifecycle-") as directory:
        work = Path(directory)
        preexisting = work / "tiles"
        preexisting.mkdir()
        (preexisting / "user-data").write_text("preserve me\n")
        with routing_directory(
            work, [("safe input", work / "outside.pbf")]
        ) as owned:
            assert owned.parent == work and owned != preexisting
            (owned / "graph-tile").write_text("temporary\n")
        assert not owned.exists()
        assert (preexisting / "user-data").read_text() == "preserve me\n"

        # A producer can add one last entry after cleanup's directory snapshot
        # but before the root rmdir. The next bounded drain must remove it.
        original_rmdir = os.rmdir
        late_owned = None
        injected_late_entry = False

        def inject_late_entry(path, *, dir_fd=None):
            nonlocal injected_late_entry
            if (
                not injected_late_entry
                and late_owned is not None
                and path == late_owned.name
            ):
                (late_owned / "late-graph-tile").write_text("late\n")
                injected_late_entry = True
            return original_rmdir(path, dir_fd=dir_fd)

        try:
            with routing_directory(
                work, [("safe input", work / "outside.pbf")]
            ) as late_owned:
                (late_owned / "initial-graph-tile").write_text("temporary\n")
                os.rmdir = inject_late_entry
        finally:
            os.rmdir = original_rmdir
        assert injected_late_entry
        assert not late_owned.exists()

        # A hostile writer must not turn cleanup into an infinite loop. Leave
        # one new entry before every root removal, then verify the useful,
        # bounded failure and clean up the test fixture ourselves.
        hostile_owned = None
        hostile_injections = 0

        def inject_forever(path, *, dir_fd=None):
            nonlocal hostile_injections
            if hostile_owned is not None and path == hostile_owned.name:
                hostile_injections += 1
                (hostile_owned / f"late-{hostile_injections}").write_text("late\n")
            return original_rmdir(path, dir_fd=dir_fd)

        try:
            try:
                with routing_directory(
                    work, [("safe input", work / "outside.pbf")]
                ) as hostile_owned:
                    os.rmdir = inject_forever
            except RuntimeError as error:
                assert "remained non-empty after 16 cleanup attempts" in str(error)
                assert "possible active writer" in str(error)
                assert "late-16" in str(error)
            else:
                raise AssertionError("hostile writer bypassed bounded cleanup")
        finally:
            os.rmdir = original_rmdir
        assert hostile_injections == 16
        (hostile_owned / "late-16").unlink()
        hostile_owned.rmdir()

        # rmdir itself is path-based, so an empty replacement can be installed
        # after the last identity check and be removed by the syscall. The
        # retained descriptor's link count must expose that the owned inode was
        # merely renamed and prevent a false cleanup success. A non-empty
        # replacement is preserved by the pre-retry identity check above; POSIX
        # offers no way to restore an empty replacement already removed by the
        # successful path-based rmdir.
        last_moment_original = work / "last-moment-original"
        replaced_owned = None
        replaced_empty_directory = False

        def replace_before_rmdir(path, *, dir_fd=None):
            nonlocal replaced_empty_directory
            if (
                not replaced_empty_directory
                and replaced_owned is not None
                and path == replaced_owned.name
            ):
                replaced_owned.rename(last_moment_original)
                replaced_owned.mkdir()
                replaced_empty_directory = True
            return original_rmdir(path, dir_fd=dir_fd)

        try:
            try:
                with routing_directory(
                    work, [("safe input", work / "outside.pbf")]
                ) as replaced_owned:
                    os.rmdir = replace_before_rmdir
            except RuntimeError as error:
                assert "identity changed; refusing cleanup" in str(error)
            else:
                raise AssertionError("empty replacement hid leaked owned directory")
        finally:
            os.rmdir = original_rmdir
        assert replaced_empty_directory
        assert not replaced_owned.exists()
        assert last_moment_original.is_dir()
        last_moment_original.rmdir()

        # Retaining an fd to the exclusively created inode prevents recursive
        # cleanup from following a different directory swapped into its path.
        swapped_original = work / "swapped-original"
        try:
            with routing_directory(
                work, [("safe input", work / "outside.pbf")]
            ) as owned:
                owned.rename(swapped_original)
                owned.mkdir()
                (owned / "replacement-data").write_text("preserve replacement\n")
        except RuntimeError as error:
            assert "identity changed; refusing cleanup" in str(error)
        else:
            raise AssertionError("swapped routing directory was recursively deleted")
        assert (owned / "replacement-data").read_text() == "preserve replacement\n"
        assert swapped_original.is_dir() and not list(swapped_original.iterdir())

        dual_original = work / "dual-original"
        try:
            with routing_directory(
                work, [("safe input", work / "outside.pbf")]
            ) as dual_owned:
                dual_owned.rename(dual_original)
                dual_owned.mkdir()
                (dual_owned / "replacement-data").write_text("still here\n")
                raise ValueError("primary routing failure")
        except BaseExceptionGroup as errors:
            assert [type(error) for error in errors.exceptions] == [
                ValueError, RuntimeError
            ]
            assert str(errors.exceptions[0]) == "primary routing failure"
        else:
            raise AssertionError("cleanup failure masked the primary exception")
        assert (dual_owned / "replacement-data").read_text() == "still here\n"

        tiles = work / "owned-tiles"
        tiles.mkdir()
        require_outside(tiles, [("safe input", work / "outside.pbf")])
        for name, protected in (
            ("tile directory", tiles),
            ("PBF descendant", tiles / "source.pbf"),
            ("output descendant", tiles / "generated"),
        ):
            try:
                require_outside(tiles, [(name, protected)])
            except ValueError as error:
                assert "must not be inside temporary routing tiles" in str(error)
            else:
                raise AssertionError(f"accepted unsafe {name}")
        alias = work / "tile-alias"
        alias.symlink_to(tiles, target_is_directory=True)
        try:
            require_outside(tiles, [("aliased output", alias / "generated")])
        except ValueError:
            pass
        else:
            raise AssertionError("accepted an aliased output descendant")

    routing_start = generate_source.index("with routing_tiles_directory(")
    routing_scope = generate_source[
        routing_start:generate_source.index("config_path.unlink()", routing_start)
    ]
    assert 'os.mkdir(candidate, mode=0o700, dir_fd=parent_descriptor)' in generate_source
    assert "remove_owned_directory(" in generate_source
    assert "BaseExceptionGroup(" in generate_source
    assert 'work, [("PBF input", args.pbf), ("output directory", output)]' in routing_scope
    assert "compute {key} native reverse expansion lines" in routing_scope
    assert 'tiles.mkdir(exist_ok=True)' not in generate_source
    assert "shutil.rmtree(tiles)" not in generate_source
    # Unroutable shelter origins are skipped by the native helper and kept as
    # POIs; generate.py must consume the skip list, mark those places
    # "unroutable", and drop them from the routed count.
    assert "unrouted-{key}.tsv" in routing_scope
    assert '"unroutable"' in routing_scope
    assert "len(entries) - len(unrouted_indices)" in routing_scope


def check_shelter_unroutable_carveout(expand_source: str) -> None:
    # The skip-on-unroutable carve-out must stay scoped to shelters: every other
    # service still fails the build on an unroutable origin so a genuine data or
    # routing-graph regression is never silently dropped.
    assert 'const bool allow_unroutable = service == "shelter";' in expand_source
    assert "if (!allow_unroutable) {" in expand_source
    assert 'out_dir / ("unrouted-" + route_key + ".tsv")' in expand_source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog-tool", type=Path, required=True)
    parser.add_argument("--destination-tool", type=Path, required=True)
    parser.add_argument("--destination-native-tool", type=Path, required=True)
    parser.add_argument("--generate", type=Path, required=True)
    parser.add_argument("--expand-source", type=Path, required=True)
    parser.add_argument("--pmtiles", type=Path, required=True)
    args = parser.parse_args()
    generate_source = args.generate.read_text(encoding="utf-8")
    check_shelter_unroutable_carveout(
        args.expand_source.read_text(encoding="utf-8")
    )
    assert "args.expansion_output_concurrency" not in generate_source
    assert "if args.expansion_batch_size <= 0:" in generate_source
    assert "lithuania-boundary.raw.geojson" in generate_source
    assert "mapping(country)" in generate_source
    catalog_branch = generate_source[
        generate_source.index("def build_catalog_branch("):
        generate_source.index("def build_access_branch(")
    ]
    assert catalog_branch.count('"edit"') == 1
    assert '"--header-json"' in catalog_branch
    assert catalog_branch.count('"--metadata"') == 1
    assert catalog_branch.index('"--metadata"') < catalog_branch.index('"edit"')
    assert "catalog_archive_metadata" in catalog_branch
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
    check_routing_tile_lifecycle(generate_source)
    for cleanup in (
        "places_pbf.unlink()",
        "raw_places_path.unlink()",
        boundary_cleanup,
        "requests_path.unlink()",
        "remove_owned_directory(",
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
    assert generate_source.index("remove_owned_directory(") > (
        generate_source.index("def routing_tiles_directory(")
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

        duplicate_set_lookup = work / "lookup-duplicate-set.sqlite"
        shutil.copy2(lookup, duplicate_set_lookup)
        with sqlite3.connect(duplicate_set_lookup) as corrupt:
            corrupt.execute(
                "UPDATE sets SET members=? WHERE (requirement,minute,set_id)=("
                "SELECT requirement,minute,set_id FROM sets ORDER BY requirement,minute,set_id LIMIT 1)",
                (sqlite3.Binary(struct.pack("<II", 0, 0)),),
            )
        rejected = subprocess.run(
            [
                sys.executable, str(args.catalog_tool),
                "--objects", str(objects_path),
                "--lookup-database", str(duplicate_set_lookup),
                "--mbtiles-out", str(work / "catalog-duplicate-set.mbtiles"),
                "--manifest-out", str(work / "catalog-duplicate-set.json"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert rejected.returncode != 0
        assert b"invalid destination set" in rejected.stderr, rejected.stderr

        dangling_spatial_lookup = work / "lookup-dangling-spatial.sqlite"
        shutil.copy2(lookup, dangling_spatial_lookup)
        with sqlite3.connect(dangling_spatial_lookup) as corrupt:
            corrupt.execute(
                "UPDATE spatial_hits SET edge_id=999 WHERE (x,y,edge_id)=("
                "SELECT x,y,edge_id FROM spatial_hits ORDER BY x,y,edge_id LIMIT 1)"
            )
        rejected = subprocess.run(
            [
                sys.executable, str(args.catalog_tool),
                "--objects", str(objects_path),
                "--lookup-database", str(dangling_spatial_lookup),
                "--mbtiles-out", str(work / "catalog-dangling-spatial.mbtiles"),
                "--manifest-out", str(work / "catalog-dangling-spatial.json"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert rejected.returncode != 0
        assert b"spatial hit references an unknown edge" in rejected.stderr, rejected.stderr

        manifest = json.loads(manifest_path.read_text())
        lookup_contract = json.loads(lookup_manifest.read_text())
        assert manifest["schema_version"] == 4
        assert "edge_build_id" not in lookup_contract
        assert len(manifest["edge_build_id"]) == 64
        assert manifest["edge_build_id"] == recompute_edge_build_id(
            mbtiles, manifest, lookup_contract["requirements"]
        )

        moved_spatial_mbtiles = work / "catalog-moved-spatial.mbtiles"
        shutil.copy2(mbtiles, moved_spatial_mbtiles)
        with sqlite3.connect(moved_spatial_mbtiles) as moved:
            zoom = manifest["spatial"]["zoom"]
            x, tms_y = moved.execute(
                "SELECT tile_column,tile_row FROM tiles WHERE zoom_level=? "
                "ORDER BY tile_column,tile_row LIMIT 1",
                (zoom,),
            ).fetchone()
            moved.execute(
                "UPDATE tiles SET tile_column=? "
                "WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                (x + 2**zoom, zoom, x, tms_y),
            )
        assert recompute_edge_build_id(
            moved_spatial_mbtiles, manifest, lookup_contract["requirements"]
        ) != manifest["edge_build_id"]

        changed_geometry_lookup = work / "lookup-changed-geometry.sqlite"
        shutil.copy2(lookup, changed_geometry_lookup)
        with sqlite3.connect(changed_geometry_lookup) as changed:
            changed.execute(
                "UPDATE edges SET delta_coords=?",
                (sqlite3.Binary(struct.pack(
                    "<iiii", 250_000_000, 550_000_000, 2_000_000, 0,
                )),),
            )
        changed_geometry_manifest = work / "catalog-changed-geometry.json"
        subprocess.run(
            [
                sys.executable, str(args.catalog_tool),
                "--objects", str(objects_path),
                "--lookup-database", str(changed_geometry_lookup),
                "--mbtiles-out", str(work / "catalog-changed-geometry.mbtiles"),
                "--manifest-out", str(changed_geometry_manifest),
            ],
            check=True,
        )
        assert json.loads(changed_geometry_manifest.read_text())["edge_build_id"] != (
            manifest["edge_build_id"]
        )
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
        destination_sets = [
            collection
            for name, collection in manifest["collections"].items()
            if name.startswith("destination_edge_set:")
        ]
        assert destination_sets
        for collection in destination_sets:
            max_records = min(
                collection["count"], fanout["candidates_per_lookup_max"]
            )
            assert collection["max_request_pages"] == min(
                collection["pages"], max_records
            )
            assert 1 <= collection["max_record_members"] <= len(objects)
            assert collection["max_request_members"] == (
                max_records * collection["max_record_members"]
            )
        reference_fanout = manifest["reference_fanout"]
        assert reference_fanout["destination_set_pages_per_lookup"] == sum(
            collection["max_request_pages"] for collection in destination_sets
        )
        assert reference_fanout["destination_set_members_per_lookup"] == sum(
            collection["max_request_members"] for collection in destination_sets
        )
        assert manifest["collections"]["object_locations"]["max_request_pages"] == (
            manifest["collections"]["object_locations"]["pages"]
        )
        assert reference_fanout["object_location_pages_per_lookup"] == (
            manifest["collections"]["object_locations"]["pages"]
        )
        with sqlite3.connect(mbtiles) as database:
            assert {
                name for name, _value in database.execute("SELECT name,value FROM metadata")
            } == {"bounds", "json"}
            edge_collection = manifest["collections"]["destination_edges"]
            relation_records = json.loads(mbtiles_page(
                database, manifest["page_zoom"], edge_collection["base"], 0
            ))
            assert relation_records
            assert all(
                len(record) == 2
                and record[0] in (1, 2, 3)
                and isinstance(record[1], list)
                for record in relation_records
            ), relation_records
            spatial = database.execute(
                "SELECT zoom_level,tile_column,tile_row,tile_data "
                "FROM tiles WHERE zoom_level=?",
                (manifest["spatial"]["zoom"],),
            ).fetchall()
        assert spatial

        archive = work / "catalog.pmtiles"
        subprocess.run([args.pmtiles, "convert", mbtiles, archive], check=True)
        converted_metadata = json.loads(
            subprocess.run(
                [args.pmtiles, "show", archive, "--metadata"], check=True,
                text=True, stdout=subprocess.PIPE,
            ).stdout
        )
        assert converted_metadata == manifest
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
        ) == converted_metadata

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
