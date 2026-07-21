#!/usr/bin/env python3

"""Independent correctness/scale fixture for normalized destination lookup."""

import argparse
import gzip
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
from unittest import mock


GEOMETRY_A = "10000000,20000000;20000000,20000000;"
GEOMETRY_B = "10000000,21000000;20000000,21000000;"
RELATION_MAGIC = b"MAPGAMES-REL-01\0"


def web_mercator_tile(lon, lat, zoom):
    dimension = 1 << zoom
    latp = math.degrees(math.asinh(math.tan(math.radians(lat))))
    return (
        math.floor((lon + 180) / 360 * dimension),
        math.floor((180 - latp) / 360 * dimension),
    )


def module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def run_builder(tool, native_tool, routes, database, manifest):
    command = [
        sys.executable, str(tool), "--database", str(database),
        "--manifest-out", str(manifest),
        "--native-tool", str(native_tool),
    ]
    for route in routes:
        command.extend(("--route", route))
    subprocess.run(command, check=True)


def write_relations(path, minutes, batches):
    with path.open("wb") as output:
        output.write(RELATION_MAGIC)
        output.write(struct.pack("<II", 1, len(minutes)))
        output.write(struct.pack(f"<{len(minutes)}I", *minutes))
        for sets, edges in batches:
            output.write(struct.pack("<II", 0xB47C4E01, len(sets)))
            for members in sets:
                output.write(struct.pack(f"<I{len(members)}I", len(members), *members))
            output.write(struct.pack("<I", len(edges)))
            for key, geometry, bands in edges:
                points = [tuple(map(int, point.split(","))) for point in geometry[:-1].split(";")]
                output.write(struct.pack("<QI", key, len(points)))
                for point in points:
                    output.write(struct.pack("<ii", *point))
                output.write(struct.pack("<I", len(bands)))
                for minute_index, runs, exact in bands:
                    output.write(struct.pack("<II", minute_index, len(runs)))
                    for start, end, set_id in runs:
                        output.write(struct.pack("<ddI", start, end, set_id))
                    output.write(struct.pack("<I", len(exact)))
                    for position, set_id in exact:
                        output.write(struct.pack("<dI", position, set_id))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--catalog-tool", type=Path, required=True)
    parser.add_argument("--native-tool", type=Path, required=True)
    parser.add_argument("--coarsen-tool", type=Path, required=True)
    parser.add_argument("--coarsen-check-tool", type=Path, required=True)
    parser.add_argument("--publication-only", action="store_true")
    args = parser.parse_args()
    lookup_tool = module(args.tool, "lookup_fixture_tool")
    catalog_tool = module(args.catalog_tool, "catalog_fixture_tool")
    lookup_source = args.tool.read_text(encoding="utf-8")
    build_source = lookup_source[
        lookup_source.index("def build("):lookup_source.index("def main()")
    ]
    assert "SELECT count(*) FROM edges" not in build_source
    assert "SELECT count(*) FROM spatial_hits" not in build_source
    assert "edge_id IS NULL" not in build_source
    assert "?mode=ro" in build_source
    subprocess.run([args.native_tool, "--self-test"], check=True)

    with tempfile.TemporaryDirectory(prefix="destination-lookup-check-") as directory:
        work = Path(directory)
        coffee = work / "relations-coffee-walk.bin"
        pharmacy = work / "relations-pharmacy-walk.bin"
        write_relations(coffee, [5, 10], [
            ([[7], [8]], [(10, GEOMETRY_B, [
                (0, [(9.5e-6, .25, 0)], [(9.5e-6, 0), (.25, 0), (.75, 1)]),
                (1, [(9.5e-6, .25, 0)], [(9.5e-6, 0), (.25, 0), (.75, 1)]),
            ])]),
            ([[2], [5], [2, 5]], [(9, GEOMETRY_A, [
                (0, [(0, .5, 0), (.5, 1, 1)], [(0, 0), (.5, 2), (1, 1)]),
                (1, [(0, 1, 0)], [(0, 0), (1, 0)]),
            ])]),
        ])
        # Simulates duplicate membership domains from distinct native batches.
        write_relations(pharmacy, [5], [
            ([[3], [4], [6]], [
                (9, GEOMETRY_A, [(0, [(.25, .75, 0)], [(.25, 0), (.75, 0)])]),
                (11, GEOMETRY_A, [(
                    0, [(.5, 1, 1)], [(.5, 2), (.6, 2), (1, 1)]
                )]),
                (13, GEOMETRY_A, [(0, [], [(.125, 2)])]),
            ]),
            ([[5]], [(9, GEOMETRY_A, [(0, [(.75, 1, 0)], [(.75, 0), (1, 0)])])]),
        ])
        routes = [f"pharmacy:walk:{pharmacy}", f"coffee:walk:{coffee}"]

        relation_band = [(0, [(0, 1, 0)], [(0, 0), (1, 0)])]
        inconsistent_geometry = work / "relations-inconsistent-geometry.bin"
        write_relations(inconsistent_geometry, [5], [
            ([[1]], [(77, GEOMETRY_A, relation_band)]),
            ([[1]], [(77, GEOMETRY_B, relation_band)]),
        ])
        inconsistent_result = subprocess.run(
            [
                args.native_tool, "--finalize-relations",
                "--database", work / "inconsistent-geometry.sqlite",
                "--route", f"inconsistent:walk:{inconsistent_geometry}",
            ],
            text=True,
            capture_output=True,
        )
        assert inconsistent_result.returncode != 0
        assert "inconsistent geometry" in inconsistent_result.stderr

        # Streaming arrays obey JSON delimiter state instead of accepting
        # whitespace-separated values, repeated commas, or trailing commas.
        valid_array = work / "valid-array.json"
        valid_array.write_text('[1, {"two":2}, 3]\n')
        assert list(catalog_tool.iter_json_array(valid_array)) == [1, {"two": 2}, 3]
        for number, malformed_text in enumerate((
            "[1 2]", "[1,,2]", "[1,]", "[]" + " " * 70_000 + "x",
        )):
            malformed_array = work / f"malformed-array-{number}.json"
            malformed_array.write_text(malformed_text)
            try:
                list(catalog_tool.iter_json_array(malformed_array))
            except ValueError:
                pass
            else:
                raise AssertionError(f"malformed JSON array was accepted: {malformed_text}")

        relation_bytes = coffee.read_bytes()
        route_symlink = work / "route-symlink.bin"
        route_symlink.symlink_to(coffee)
        route_hardlink = work / "route-hardlink.bin"
        os.link(coffee, route_hardlink)
        for database_alias in (coffee, route_symlink, route_hardlink):
            native_alias = subprocess.run(
                [
                    args.native_tool, "--finalize-relations", "--database", database_alias,
                    "--route", f"coffee:walk:{coffee}",
                ],
                text=True,
                capture_output=True,
            )
            assert native_alias.returncode != 0
            assert "different files" in native_alias.stderr
            assert coffee.read_bytes() == relation_bytes
        assert route_symlink.is_symlink()

        def rejected_builder(database, output_manifest):
            try:
                lookup_tool.build(
                    [("coffee", "walk", coffee)], database, output_manifest,
                    args.native_tool,
                )
            except ValueError as error:
                assert "different files" in str(error)
            else:
                raise AssertionError("aliased destination lookup paths were accepted")

        same_output = work / "same-output"
        rejected_builder(same_output, same_output)
        rejected_builder(work / "unused-database", coffee)
        rejected_builder(route_hardlink, work / "unused-manifest")
        assert coffee.read_bytes() == relation_bytes

        # Inputs may intentionally share identity; only outputs can destroy an
        # aliased path. Distinct requirements over the same handoff are valid.
        shared_input_database = work / "shared-input.sqlite"
        shared_input_manifest = work / "shared-input.json"
        lookup_tool.build(
            [("aliasa", "walk", coffee), ("aliasb", "walk", route_hardlink)],
            shared_input_database, shared_input_manifest, args.native_tool,
        )
        assert shared_input_database.exists() and shared_input_manifest.exists()

        database_path = work / "lookup.sqlite"
        manifest_path = work / "lookup.json"
        run_builder(
            args.tool,
            args.native_tool,
            [f"coffee:walk:{coffee}"],
            database_path,
            manifest_path,
        )
        previous_database = database_path.read_bytes()
        previous_manifest = manifest_path.read_bytes()
        assert json.loads(previous_manifest)["edge_count"] == 2

        truncated = work / "relations-truncated.bin"
        truncated.write_bytes(coffee.read_bytes()[:-7])

        # The native finalizer is independently rollback-safe: a malformed
        # handoff never removes or truncates its previously valid database.
        native_rollback_database = work / "native-rollback.sqlite"
        shutil.copy2(database_path, native_rollback_database)
        native_database_before = native_rollback_database.read_bytes()
        native_truncated = subprocess.run(
            [
                args.native_tool,
                "--finalize-relations",
                "--database",
                native_rollback_database,
                "--route",
                f"coffee:walk:{truncated}",
            ],
            text=True,
            capture_output=True,
        )
        assert native_truncated.returncode != 0
        assert native_rollback_database.read_bytes() == native_database_before

        # The wrapper stages both files before publication, so a failed native
        # build retains a matched, valid database/manifest pair.
        truncated_builder = subprocess.run(
            [
                sys.executable,
                args.tool,
                "--database",
                database_path,
                "--manifest-out",
                manifest_path,
                "--native-tool",
                args.native_tool,
                "--route",
                f"coffee:walk:{truncated}",
            ],
            text=True,
            capture_output=True,
        )
        assert truncated_builder.returncode != 0
        assert database_path.read_bytes() == previous_database
        assert manifest_path.read_bytes() == previous_manifest

        # Exercise rollback after the first new file has been published by
        # injecting a failure into the second publication rename.
        pair_database = work / "pair-rollback.sqlite"
        pair_manifest = work / "pair-rollback.json"
        shutil.copy2(database_path, pair_database)
        shutil.copy2(manifest_path, pair_manifest)
        pair_database_before = pair_database.read_bytes()
        pair_manifest_before = pair_manifest.read_bytes()
        pair_database_temporary = lookup_tool.temporary_sibling(
            pair_database, "build"
        )
        pair_manifest_temporary = lookup_tool.temporary_sibling(
            pair_manifest, "build"
        )
        pair_database_temporary.write_bytes(b"replacement database\n")
        pair_manifest_temporary.write_bytes(b"replacement manifest\n")
        def fail_second_publication(source, destination):
            if (
                Path(source) == pair_manifest_temporary
                and Path(destination) == pair_manifest
            ):
                raise OSError("injected second-publication failure")
            return real_replace(source, destination)

        real_replace = os.replace
        with mock.patch.object(lookup_tool.os, "replace", fail_second_publication):
            try:
                lookup_tool.publish_output_pair(
                    pair_database_temporary,
                    pair_database,
                    pair_manifest_temporary,
                    pair_manifest,
                )
            except OSError as error:
                assert "second-publication" in str(error)
            else:
                raise AssertionError("injected pair-publication failure was ignored")
        lookup_tool.remove_owned_path(pair_database_temporary)
        lookup_tool.remove_owned_path(pair_manifest_temporary)
        assert pair_database.read_bytes() == pair_database_before
        assert pair_manifest.read_bytes() == pair_manifest_before
        assert not list(work.glob("*.mapgames-*"))

        # Reproduce the dual-failure review case end to end through build():
        # database publication succeeds, manifest publication fails, then the
        # attempted database restoration also fails. Finally must retain the
        # journal-owned manifest staging file, and the next invocation must
        # restore the old pair rather than infer a commit from missing names.
        dual_database = work / "dual-failure.sqlite"
        dual_manifest = work / "dual-failure.json"
        shutil.copy2(database_path, dual_database)
        shutil.copy2(manifest_path, dual_manifest)
        dual_database_before = dual_database.read_bytes()
        dual_manifest_before = dual_manifest.read_bytes()

        def fail_manifest_and_database_restore(source, destination):
            source = Path(source)
            destination = Path(destination)
            if (
                destination == dual_manifest
                and source.name.startswith(dual_manifest.name + ".mapgames-build-")
            ):
                raise OSError("injected manifest publication failure")
            if (
                destination == dual_database
                and ".mapgames-restore-" in source.name
            ):
                raise OSError("injected database restore failure")
            return real_replace(source, destination)

        with mock.patch.object(
            lookup_tool.os, "replace", fail_manifest_and_database_restore
        ):
            try:
                lookup_tool.build(
                    [
                        ("coffee", "walk", coffee),
                        ("pharmacy", "walk", pharmacy),
                    ],
                    dual_database,
                    dual_manifest,
                    args.native_tool,
                )
            except BaseExceptionGroup as errors:
                assert [type(error) for error in errors.exceptions] == [
                    OSError, OSError
                ]
            else:
                raise AssertionError("dual publication/recovery failure was ignored")
        dual_journal = lookup_tool.publication_journal_path(
            dual_database, dual_manifest
        )
        dual_state = json.loads(dual_journal.read_text())
        retained_manifest_temporary = Path(dual_state["manifest"]["temporary"])
        assert retained_manifest_temporary.exists()
        assert dual_database.read_bytes() != dual_database_before
        assert dual_manifest.read_bytes() == dual_manifest_before
        assert lookup_tool.recover_output_pair(dual_database, dual_manifest)
        assert dual_database.read_bytes() == dual_database_before
        assert dual_manifest.read_bytes() == dual_manifest_before
        assert not list(work.glob("*.mapgames-*"))

        # Cooperative process interruption follows the same rollback path as
        # ordinary exceptions instead of stranding live files in backups.
        interrupt_database = work / "interrupt.sqlite"
        interrupt_manifest = work / "interrupt.json"
        shutil.copy2(database_path, interrupt_database)
        shutil.copy2(manifest_path, interrupt_manifest)
        interrupt_database_before = interrupt_database.read_bytes()
        interrupt_manifest_before = interrupt_manifest.read_bytes()
        interrupt_database_temporary = lookup_tool.temporary_sibling(
            interrupt_database, "build"
        )
        interrupt_manifest_temporary = lookup_tool.temporary_sibling(
            interrupt_manifest, "build"
        )
        interrupt_database_temporary.write_bytes(b"interrupted database\n")
        interrupt_manifest_temporary.write_bytes(b"interrupted manifest\n")

        def interrupt_second_publication(source, destination):
            if (
                Path(source) == interrupt_manifest_temporary
                and Path(destination) == interrupt_manifest
            ):
                raise KeyboardInterrupt()
            return real_replace(source, destination)

        with mock.patch.object(
            lookup_tool.os, "replace", interrupt_second_publication
        ):
            try:
                lookup_tool.publish_output_pair(
                    interrupt_database_temporary,
                    interrupt_database,
                    interrupt_manifest_temporary,
                    interrupt_manifest,
                )
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("KeyboardInterrupt was swallowed")
        assert interrupt_database.read_bytes() == interrupt_database_before
        assert interrupt_manifest.read_bytes() == interrupt_manifest_before
        assert not list(work.glob("*.mapgames-*"))

        # Simulate a hard crash after only the database rename. The immutable
        # stale journal is recovered by the next invocation.
        stale_database = lookup_tool.canonical_target(work / "stale.sqlite")
        stale_manifest = lookup_tool.canonical_target(work / "stale.json")
        shutil.copy2(database_path, stale_database)
        shutil.copy2(manifest_path, stale_manifest)
        stale_database_before = stale_database.read_bytes()
        stale_manifest_before = stale_manifest.read_bytes()
        stale_database_temporary = lookup_tool.temporary_sibling(
            stale_database, "build"
        )
        stale_manifest_temporary = lookup_tool.temporary_sibling(
            stale_manifest, "build"
        )
        stale_database_temporary.write_bytes(b"crashed database\n")
        stale_manifest_temporary.write_bytes(b"crashed manifest\n")
        with lookup_tool.publication_lock(stale_database, stale_manifest):
            lookup_tool.begin_output_pair_transaction(
                stale_database_temporary,
                stale_database,
                stale_manifest_temporary,
                stale_manifest,
            )
            lookup_tool.durable_replace(stale_database_temporary, stale_database)
        assert lookup_tool.publication_journal_path(
            stale_database, stale_manifest
        ).exists()
        assert lookup_tool.recover_output_pair(stale_database, stale_manifest)
        assert stale_database.read_bytes() == stale_database_before
        assert stale_manifest.read_bytes() == stale_manifest_before
        assert not list(work.glob("*.mapgames-*"))

        # The other recoverable crash matrices are deterministic too: a
        # journal prepared before either rename rolls back, while two proven
        # staged targets commit even if cleanup never ran.
        prepared_database = lookup_tool.canonical_target(work / "prepared.sqlite")
        prepared_manifest = lookup_tool.canonical_target(work / "prepared.json")
        shutil.copy2(database_path, prepared_database)
        shutil.copy2(manifest_path, prepared_manifest)
        prepared_database_before = prepared_database.read_bytes()
        prepared_manifest_before = prepared_manifest.read_bytes()
        prepared_database_temporary = lookup_tool.temporary_sibling(
            prepared_database, "build"
        )
        prepared_manifest_temporary = lookup_tool.temporary_sibling(
            prepared_manifest, "build"
        )
        prepared_database_temporary.write_bytes(b"prepared database\n")
        prepared_manifest_temporary.write_bytes(b"prepared manifest\n")
        with lookup_tool.publication_lock(prepared_database, prepared_manifest):
            lookup_tool.begin_output_pair_transaction(
                prepared_database_temporary,
                prepared_database,
                prepared_manifest_temporary,
                prepared_manifest,
            )
        assert lookup_tool.recover_output_pair(prepared_database, prepared_manifest)
        assert prepared_database.read_bytes() == prepared_database_before
        assert prepared_manifest.read_bytes() == prepared_manifest_before

        committed_database = lookup_tool.canonical_target(work / "committed.sqlite")
        committed_manifest = lookup_tool.canonical_target(work / "committed.json")
        shutil.copy2(database_path, committed_database)
        shutil.copy2(manifest_path, committed_manifest)
        committed_database_temporary = lookup_tool.temporary_sibling(
            committed_database, "build"
        )
        committed_manifest_temporary = lookup_tool.temporary_sibling(
            committed_manifest, "build"
        )
        committed_database_temporary.write_bytes(b"committed database\n")
        committed_manifest_temporary.write_bytes(b"committed manifest\n")
        with lookup_tool.publication_lock(committed_database, committed_manifest):
            lookup_tool.begin_output_pair_transaction(
                committed_database_temporary,
                committed_database,
                committed_manifest_temporary,
                committed_manifest,
            )
            lookup_tool.durable_replace(
                committed_database_temporary, committed_database
            )
            lookup_tool.durable_replace(
                committed_manifest_temporary, committed_manifest
            )
        assert lookup_tool.recover_output_pair(committed_database, committed_manifest)
        assert committed_database.read_bytes() == b"committed database\n"
        assert committed_manifest.read_bytes() == b"committed manifest\n"
        assert not list(work.glob("*.mapgames-*"))

        # A forged/malformed journal cannot redirect cleanup through a
        # non-path JSON value or mutate either live target.
        malformed_database = lookup_tool.canonical_target(work / "malformed.sqlite")
        malformed_manifest = lookup_tool.canonical_target(work / "malformed.json")
        shutil.copy2(database_path, malformed_database)
        shutil.copy2(manifest_path, malformed_manifest)
        malformed_database_before = malformed_database.read_bytes()
        malformed_manifest_before = malformed_manifest.read_bytes()
        malformed_database_temporary = lookup_tool.temporary_sibling(
            malformed_database, "build"
        )
        malformed_manifest_temporary = lookup_tool.temporary_sibling(
            malformed_manifest, "build"
        )
        malformed_state = {
            "schema_version": lookup_tool.TRANSACTION_SCHEMA_VERSION,
            "transaction_id": "a" * 32,
            "database": lookup_tool.transaction_record(
                malformed_database, malformed_database_temporary, "a" * 32
            ),
            "manifest": lookup_tool.transaction_record(
                malformed_manifest, malformed_manifest_temporary, "a" * 32
            ),
        }
        malformed_state["database"]["temporary"] = ["not", "a", "path"]
        malformed_journal = lookup_tool.publication_journal_path(
            malformed_database, malformed_manifest
        )
        malformed_journal.write_bytes(
            lookup_tool.canonical_json(malformed_state) + b"\n"
        )
        try:
            lookup_tool.recover_output_pair(
                malformed_database, malformed_manifest
            )
        except RuntimeError as error:
            assert "invalid destination publication transaction" in str(error)
        else:
            raise AssertionError("malformed publication journal was trusted")
        assert malformed_database.read_bytes() == malformed_database_before
        assert malformed_manifest.read_bytes() == malformed_manifest_before
        for path in (
            malformed_journal,
            malformed_database_temporary,
            malformed_manifest_temporary,
        ):
            lookup_tool.remove_owned_path(path)
        assert not list(work.glob("*.mapgames-*"))

        # File data and every directory-entry transition are explicitly synced.
        sync_database = work / "sync.sqlite"
        sync_manifest = work / "sync.json"
        sync_database_temporary = lookup_tool.temporary_sibling(
            sync_database, "build"
        )
        sync_manifest_temporary = lookup_tool.temporary_sibling(
            sync_manifest, "build"
        )
        sync_database_temporary.write_bytes(b"synced database\n")
        sync_manifest_temporary.write_bytes(b"synced manifest\n")
        sync_kinds = []
        real_fsync = os.fsync

        def track_fsync(descriptor):
            mode = os.fstat(descriptor).st_mode
            sync_kinds.append("directory" if stat.S_ISDIR(mode) else "file")
            return real_fsync(descriptor)

        with mock.patch.object(lookup_tool.os, "fsync", track_fsync):
            lookup_tool.publish_output_pair(
                sync_database_temporary,
                sync_database,
                sync_manifest_temporary,
                sync_manifest,
            )
        assert sync_kinds.count("file") >= 3, sync_kinds
        assert sync_kinds.count("directory") >= 5, sync_kinds
        assert not list(work.glob("*.mapgames-*"))

        # A subsequent valid rebuild publishes both newly validated outputs.
        run_builder(args.tool, args.native_tool, routes, database_path, manifest_path)
        assert database_path.read_bytes() != previous_database
        assert manifest_path.read_bytes() != previous_manifest
        manifest = json.loads(manifest_path.read_text())
        assert manifest["schema_version"] == 3 and manifest["edge_count"] == 2
        assert "edge_build_id" not in manifest
        assert [item["key"] for item in manifest["requirements"]] == [
            "coffee_walk", "pharmacy_walk"
        ]
        if args.publication_only:
            return

        def rejected_merge(network_out, groups_out, *extra):
            result = subprocess.run(
                [
                    args.native_tool, "--merge-network-db", network_out,
                    "0,0,3,3", database_path, "--groups-out", groups_out,
                    *extra,
                ],
                text=True,
                capture_output=True,
            )
            assert result.returncode != 0, result.stdout
            return result.stderr

        corrupt_database = work / "corrupt-geometry.sqlite"
        shutil.copy2(database_path, corrupt_database)
        with sqlite3.connect(corrupt_database) as corrupt:
            corrupt.execute(
                "UPDATE edges SET delta_coords=? WHERE edge_pk=(SELECT min(edge_pk) FROM edges)",
                (sqlite3.Binary(b"\0" * 8),),
            )
        corrupt_merge = subprocess.run(
            [
                args.native_tool, "--merge-network-db", work / "corrupt-network",
                "0,0,3,3", corrupt_database, "--groups-out", work / "corrupt-groups",
            ],
            text=True,
            capture_output=True,
        )
        assert corrupt_merge.returncode != 0
        assert "invalid delta E7 geometry" in corrupt_merge.stderr

        collision = work / "collision"
        assert "different files" in rejected_merge(
            collision, work / "missing-parent" / ".." / "collision"
        )
        real_parent = work / "real-parent"
        real_parent.mkdir()
        linked_parent = work / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        assert "different files" in rejected_merge(
            real_parent / "network", linked_parent / "network"
        )
        database_symlink = work / "database-symlink.sqlite"
        database_symlink.symlink_to(database_path)
        assert "different files" in rejected_merge(
            database_symlink, work / "unused-groups"
        )
        database_hardlink = work / "database-hardlink.sqlite"
        os.link(database_path, database_hardlink)
        assert "different files" in rejected_merge(
            work / "unused-network", database_hardlink
        )
        same_debug = work / "same-debug"
        assert "different files" in rejected_merge(
            same_debug, work / "other-groups", "--debug-segments", same_debug
        )

        old_network = work / "old-network.geojson"
        old_groups = work / "old-groups.json"
        old_network.write_bytes(b"old network\n")
        old_groups.write_bytes(b"old groups\n")
        if Path("/dev/full").exists():
            error = rejected_merge(
                old_network, old_groups, "--debug-segments", Path("/dev/full")
            )
            assert "flush output" in error or "close output" in error
            assert old_network.read_bytes() == b"old network\n"
            assert old_groups.read_bytes() == b"old groups\n"
            assert not list(work.glob("*.mapgames-*"))

        rollback_network = work / "rollback-network.geojson"
        rollback_groups = work / "rollback-groups"
        rollback_network.write_bytes(b"preserve me\n")
        rollback_groups.mkdir()
        rejected_merge(rollback_network, rollback_groups)
        assert rollback_network.read_bytes() == b"preserve me\n"
        assert rollback_groups.is_dir()
        assert not list(work.glob("*.mapgames-*"))

        database = sqlite3.connect(database_path)
        try:
            edge_count = database.execute("SELECT count(*) FROM edges").fetchone()[0]
            spatial_hit_count = database.execute(
                "SELECT count(*) FROM spatial_hits"
            ).fetchone()[0]
            assert edge_count == 2 and spatial_hit_count >= 2
            assert dict(database.execute("SELECT key,value FROM metadata")) == {
                "schema_version": "3",
                "spatial_zoom": "15",
                "edge_count": str(edge_count),
                "spatial_hit_count": str(spatial_hit_count),
            }
            assert lookup_tool.normalization_counts(database) == (
                edge_count, spatial_hit_count
            )
            tables = {
                row[0] for row in database.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            assert "relations" not in tables
            assert "relation_runs" in tables and "relation_points" in tables
            assert "member_hash" not in {
                row[1] for row in database.execute("PRAGMA table_info(sets)")
            }
            assert [
                row[1] for row in database.execute("PRAGMA table_info(edges)")
            ] == ["edge_pk", "edge_id", "delta_coords", "mode_mask"]
            assert [
                row[1] for row in database.execute("PRAGMA table_info(spatial_hits)")
            ] == ["x", "y", "edge_id"]
            assert [row[1] for row in database.execute("PRAGMA table_info(relation_runs)") if row[5]] == [
                "edge_pk", "requirement", "minute", "sequence"
            ]
            assert "geometry" not in {
                row[1] for row in database.execute("PRAGMA table_info(memberships)")
            }
            assert database.execute(
                "SELECT value FROM metadata WHERE key='edge_build_id'"
            ).fetchone() is None
            entries = list(catalog_tool.edge_entries(database))
            geometry_blob = struct.pack(
                "<iiii", 10_000_000, 20_000_000, 10_000_000, 0
            )
            edge_id = database.execute(
                "SELECT edge_id FROM edges WHERE delta_coords=?",
                (sqlite3.Binary(geometry_blob),),
            ).fetchone()[0]
            coffee_five = entries[edge_id][1][0][1][0]
            sets = {
                row[0]: list(struct.unpack(f"<{len(row[1]) // 4}I", row[1]))
                for row in database.execute(
                    "SELECT set_id,members FROM sets WHERE requirement=0 AND minute=5"
                )
            }
            coffee_runs = [(a, b, sets[s]) for a, b, s in coffee_five[1]]
            assert coffee_runs == [
                (0, 0.5, [2]), (0.5, 1, [5])
            ], coffee_runs
            assert [(p, sets[s]) for p, s in coffee_five[2]] == [
                (0, [2]), (0.5, [2, 5]), (1, [5])
            ]
            pharmacy_runs = [
                (start, end, list(struct.unpack(f"<{len(members) // 4}I", members)))
                for start, end, members in database.execute(
                    "SELECT r.start,r.end,s.members FROM relation_runs r "
                    "JOIN sets s ON s.requirement=r.requirement "
                    "AND s.minute=r.minute AND s.set_id=r.set_id "
                    "WHERE r.requirement=1 AND r.minute=5 "
                    "ORDER BY r.edge_pk,r.sequence"
                )
            ]
            assert pharmacy_runs == [
                (0.25, 0.5, [3]), (0.5, 0.75, [3, 4]), (0.75, 1, [4, 5])
            ]
            pharmacy_points = [
                (point, list(struct.unpack(f"<{len(members) // 4}I", members)))
                for point, members in database.execute(
                    "SELECT p.point,s.members FROM relation_points p "
                    "JOIN sets s ON s.requirement=p.requirement "
                    "AND s.minute=p.minute AND s.set_id=p.set_id "
                    "WHERE p.requirement=1 AND p.minute=5 "
                    "ORDER BY p.edge_pk,p.sequence"
                )
            ]
            assert pharmacy_points == [
                (0.125, [6]), (0.25, [3]), (0.5, [3, 6]),
                (0.6, [3, 6]), (0.75, [3, 4, 5]), (1, [4, 5]),
            ]
            catalog_plan = database.execute(
                "EXPLAIN QUERY PLAN SELECT edge_pk,requirement,minute,0,sequence,start,end,set_id "
                "FROM relation_runs ORDER BY edge_pk,requirement,minute,sequence"
            ).fetchall()
            catalog_points_plan = database.execute(
                "EXPLAIN QUERY PLAN SELECT edge_pk,requirement,minute,1,sequence,point,NULL,set_id "
                "FROM relation_points ORDER BY edge_pk,requirement,minute,sequence"
            ).fetchall()
            merge_edges_plan = database.execute(
                "EXPLAIN QUERY PLAN SELECT edge_pk,delta_coords FROM edges ORDER BY edge_pk"
            ).fetchall()
            merge_runs_plan = database.execute(
                "EXPLAIN QUERY PLAN SELECT edge_pk,requirement,minute,start,end "
                "FROM relation_runs ORDER BY edge_pk,requirement,minute,sequence"
            ).fetchall()
            for name, plan in (
                ("catalog runs", catalog_plan),
                ("catalog points", catalog_points_plan),
                ("merge edges", merge_edges_plan),
                ("merge runs", merge_runs_plan),
            ):
                assert not any("TEMP B-TREE" in row[3] for row in plan), (name, plan)
        finally:
            database.close()

        # Many sources on one edge must remain near-linear in source events.
        # Nested intervals with identical membership keep the emitted data
        # linear too, isolating accidental event-by-source rescans.
        stress_source_count = 2048
        stress_relations = work / "relations-stress-walk.bin"
        write_relations(stress_relations, [5], [
            (
                [[3]],
                [(9, GEOMETRY_A, [(
                    0,
                    [(index / (4 * stress_source_count),
                      1 - index / (4 * stress_source_count), 0)],
                    [],
                )])],
            )
            for index in range(stress_source_count)
        ])
        stress_database = work / "stress.sqlite"
        run_builder(
            args.tool, args.native_tool,
            [f"stress:walk:{stress_relations}"],
            stress_database, work / "stress.json",
        )
        with sqlite3.connect(stress_database) as stress:
            assert stress.execute("SELECT count(*) FROM sets").fetchone()[0] == 1
            assert stress.execute("SELECT count(*) FROM relation_runs").fetchone()[0] == 1
            assert stress.execute("SELECT count(*) FROM relation_points").fetchone()[0] == (
                stress_source_count * 2 - 2
            )

        database_network = work / "network-from-database.geojson"
        database_groups = work / "network-groups-from-database.json"
        database_network.write_bytes(b"stale network\n")
        database_groups.write_bytes(b"stale groups\n")
        subprocess.run(
            [
                args.native_tool, "--merge-network-db", database_network,
                "0,0,3,3", database_path, "--groups-out", database_groups,
            ],
            check=True,
        )
        assert not list(work.glob("*.mapgames-*"))
        network = json.loads(database_network.read_text())
        groups_manifest = json.loads(database_groups.read_text())
        assert len(hashlib.sha256(database_network.read_bytes()).hexdigest()) == 64
        assert network["type"] == "FeatureCollection"
        assert network["features"]
        grouped_properties = []
        for feature_index, feature in enumerate(network["features"]):
            properties = feature["properties"]
            group = properties["g"]
            if group == len(grouped_properties):
                grouped_properties.append(properties)
            else:
                assert group == len(grouped_properties) - 1, (feature_index, group)
                assert properties == grouped_properties[group]
        assert groups_manifest == {
            "schema_version": 1,
            "group_count": len(grouped_properties),
            "groups": grouped_properties,
        }
        for feature in network["features"]:
            assert feature["geometry"]["type"] == "MultiLineString"
            assert feature["geometry"]["coordinates"]
            assert set(feature["properties"]) <= {"coffee_walk", "pharmacy_walk", "g"}

        # Spatial chunks are only a z14 encoder partition. The first two
        # features deliberately share g=0 and the interior point (0.01,0.01),
        # so both contribute to the same z14 tile despite their bbox centres
        # landing in different z10 buckets. Reassembling the ordered g run
        # must produce byte-identical complete and filtered skeletons.
        west = [[-1, 0.01], [0.01, 0.01]]
        east = [[0.01, 0.01], [1, 0.01]]
        assert web_mercator_tile((-1 + 0.01) / 2, 0.01, 10) != (
            web_mercator_tile((0.01 + 1) / 2, 0.01, 10)
        )
        assert west[-1] == east[0]
        assert web_mercator_tile(*west[-1], 14) == web_mercator_tile(*east[0], 14)
        chunked_features = [
            {
                "type": "Feature",
                "properties": {"coffee_walk": 5, "g": 0},
                "geometry": {"type": "MultiLineString", "coordinates": [west]},
            },
            {
                "type": "Feature",
                "properties": {"coffee_walk": 5, "g": 0},
                "geometry": {"type": "MultiLineString", "coordinates": [east]},
            },
            {
                "type": "Feature",
                "properties": {"coffee_walk": 10, "g": 1},
                "geometry": {
                    "type": "MultiLineString",
                    "coordinates": [[[0, 0.2], [0.1, 0.2]]],
                },
            },
        ]
        chunked_network = work / "network-chunked.geojson"
        canonical_network = work / "network-canonical.geojson"
        canonical_features = [
            {
                **chunked_features[0],
                "geometry": {
                    "type": "MultiLineString",
                    "coordinates": [west, east],
                },
            },
            chunked_features[2],
        ]
        for path, features in (
            (chunked_network, chunked_features),
            (canonical_network, canonical_features),
        ):
            path.write_text(
                json.dumps(
                    {"type": "FeatureCollection", "features": features},
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                + "\n",
                encoding="utf-8",
            )
        skeletons = []
        for label, source in (
            ("chunked", chunked_network),
            ("canonical", canonical_network),
        ):
            lowzoom = work / f"network-lowzoom-{label}.geojson"
            z67 = work / f"network-z67-{label}.geojson"
            subprocess.run(
                [
                    sys.executable,
                    args.coarsen_tool,
                    source,
                    lowzoom,
                    "--z67-out",
                    z67,
                    "--n-drop",
                    "64",
                ],
                check=True,
            )
            skeletons.append((lowzoom, z67))
        assert skeletons[0][0].read_bytes() == skeletons[1][0].read_bytes()
        assert skeletons[0][1].read_bytes() == skeletons[1][1].read_bytes()
        subprocess.run(
            [
                sys.executable,
                args.coarsen_check_tool,
                chunked_network,
                skeletons[0][0],
                "--z67",
                skeletons[0][1],
                "--n-drop",
                "64",
            ],
            check=True,
        )

        objects = [
            {
                "index": index, "place_id": f"coffee:n{index}", "service": "coffee",
                "lon": 25 + index / 1000, "lat": 55,
            }
            for index in range(10)
        ]
        objects_path = work / "objects.json"
        objects_path.write_text(json.dumps(objects))
        catalog_path = work / "catalog.mbtiles"
        catalog_manifest_path = work / "catalog.json"
        catalog = catalog_tool.pack(
            objects_path, database_path, catalog_path, catalog_manifest_path
        )
        assert catalog["schema_version"] == 4
        assert len(catalog["edge_build_id"]) == 64
        assert catalog["collections"]["destination_edges"]["count"] == 2
        assert catalog["collections"]["object_locations"]["page_size"] == 512
        assert catalog["object_locations"]["service_ordinals"] == ["coffee"]
        assert catalog["spatial"]["tiles"] >= 1
        assert catalog["collections"]["destination_edges"]["page_size"] == 64
        fanout = catalog["spatial"]["fanout_stats"]
        gates = catalog["spatial"]["fanout_gate"]
        assert (
            catalog["collections"]["destination_edges"]["max_request_pages"]
            == fanout["relation_pages_per_lookup_raw_max"]
        )
        assert fanout["candidates_per_tile_max"] <= fanout["candidates_per_lookup_max"]
        assert fanout["relation_pages_per_tile_max"] <= fanout["relation_pages_per_lookup_raw_max"]
        assert fanout["candidates_per_lookup_max"] <= gates["candidates_per_lookup"]
        assert (
            gates["postfilter_relation_pages_per_lookup"]
            == fanout["relation_pages_per_lookup_raw_max"]
        )
        set_collections = [
            collection
            for name, collection in catalog["collections"].items()
            if name.startswith("destination_edge_set:")
        ]
        assert catalog["reference_fanout"]["destination_set_pages_per_lookup"] == sum(
            collection["max_request_pages"] for collection in set_collections
        )
        assert catalog["reference_fanout"]["destination_set_members_per_lookup"] == sum(
            collection["max_request_members"] for collection in set_collections
        )
        assert catalog["reference_fanout"]["object_location_pages_per_lookup"] == (
            catalog["collections"]["object_locations"]["pages"]
        )
        pages = sqlite3.connect(catalog_path).execute(
            "SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles"
        ).fetchall()
        assert any(zoom == catalog["spatial"]["zoom"] for zoom, *_ in pages)
        assert max(len(payload) for *_, payload in pages) <= catalog_tool.MAX_PAGE_GZIP_BYTES
        assert max(len(gzip.decompress(payload)) for *_, payload in pages) <= catalog_tool.MAX_PAGE_RAW_BYTES

        # Route CLI order cannot affect the normalized catalog or build id.
        database_two = work / "lookup-two.sqlite"
        manifest_two = work / "lookup-two.json"
        run_builder(args.tool, args.native_tool, list(reversed(routes)), database_two, manifest_two)
        database_network_two = work / "network-from-database-two.geojson"
        database_groups_two = work / "network-groups-from-database-two.json"
        subprocess.run(
            [
                args.native_tool, "--merge-network-db", database_network_two,
                "0,0,3,3", database_two, "--groups-out", database_groups_two,
            ],
            check=True,
        )
        assert database_network.read_bytes() == database_network_two.read_bytes()
        assert database_groups.read_bytes() == database_groups_two.read_bytes()
        catalog_two = work / "catalog-two.mbtiles"
        catalog_manifest_two = work / "catalog-two.json"
        catalog_tool.pack(objects_path, database_two, catalog_two, catalog_manifest_two)
        assert manifest_path.read_bytes() == manifest_two.read_bytes()
        # SQLite rowids and page allocation are unpublished implementation
        # details. Determinism is required only at every published/derived
        # boundary consumed by the server or browser.
        assert catalog_path.read_bytes() == catalog_two.read_bytes()
        assert catalog_manifest_path.read_bytes() == catalog_manifest_two.read_bytes()

        # The ID is owned by the canonical packing stream: changing a valid
        # packed membership changes it, while malformed canonical contents are
        # rejected instead of receiving an identity.
        with sqlite3.connect(database_two) as changed:
            changed.execute(
                "UPDATE sets SET members=? WHERE requirement=0 AND minute=5 AND set_id=("
                "SELECT min(set_id) FROM sets WHERE requirement=0 AND minute=5)",
                (sqlite3.Binary(struct.pack("<II", 2, 9)),),
            )
        changed_catalog = catalog_tool.pack(
            objects_path, database_two, work / "catalog-changed.mbtiles",
            work / "catalog-changed.json",
        )
        assert changed_catalog["edge_build_id"] != catalog["edge_build_id"]
        with sqlite3.connect(database_two) as malformed:
            malformed.execute(
                "UPDATE sets SET members=? WHERE requirement=0 AND minute=5 AND set_id=("
                "SELECT min(set_id) FROM sets WHERE requirement=0 AND minute=5)",
                (sqlite3.Binary(struct.pack("<II", 9, 2)),),
            )
        try:
            catalog_tool.pack(
                objects_path, database_two, work / "catalog-malformed.mbtiles",
                work / "catalog-malformed.json",
            )
        except ValueError as error:
            assert "invalid destination set" in str(error)
        else:
            raise AssertionError("malformed destination set was accepted")


if __name__ == "__main__":
    main()
