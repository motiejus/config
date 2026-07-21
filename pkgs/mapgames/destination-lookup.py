#!/usr/bin/env python3

"""Build the normalized shared-destination SQLite handoff."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import secrets
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time


MODE_BITS = {"walk": 1, "drive": 2}
EDGE_COLLECTION = "destination_edges"
SCHEMA_VERSION = 3
SPATIAL_ZOOM = 15
_ROUTE = re.compile(r"([a-z]+):([a-z]+):(.+)")
_TRANSACTION_ID = re.compile(r"[0-9a-f]{32}")
TRANSACTION_SCHEMA_VERSION = 2


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


def temporary_sibling(target: Path, purpose: str) -> Path:
    absolute = target.absolute()
    descriptor, path = tempfile.mkstemp(
        prefix=f"{absolute.name}.mapgames-{purpose}-", dir=absolute.parent
    )
    os.close(descriptor)
    return Path(path)


def canonical_target(path: Path) -> Path:
    absolute = path.absolute()
    return absolute.parent.resolve(strict=True) / absolute.name


def path_present(path: Path) -> bool:
    return os.path.lexists(path)


def remove_owned_path(path: Path | None) -> None:
    if path is None:
        return
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def fsync_file(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"publication artifact is not a regular file: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fsync_directory(directory: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(directory, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fsync_parent_directories(*paths: Path) -> None:
    for parent in sorted({path.parent for path in paths}, key=str):
        fsync_directory(parent)


def durable_replace(source: Path, target: Path) -> None:
    os.replace(source, target)
    fsync_parent_directories(source, target)


def durable_unlink(path: Path) -> None:
    if not path_present(path):
        return
    path.unlink()
    fsync_directory(path.parent)


def durable_link(source: Path, target: Path) -> None:
    os.link(source, target, follow_symlinks=False)
    fsync_directory(target.parent)


def publication_journal_path(database_target: Path, manifest_target: Path) -> Path:
    digest = hashlib.sha256(
        os.fsencode(database_target) + b"\0" + os.fsencode(manifest_target)
    ).hexdigest()[:16]
    return manifest_target.with_name(
        f".{manifest_target.name}.mapgames-transaction-{digest}.json"
    )


@contextmanager
def publication_lock(database_target: Path, manifest_target: Path):
    descriptors = []
    try:
        for parent in sorted(
            {database_target.parent, manifest_target.parent}, key=str
        ):
            flags = (
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_DIRECTORY", 0)
            )
            descriptor = os.open(parent, flags)
            descriptors.append(descriptor)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def transaction_record(target: Path, temporary: Path, transaction_id: str) -> dict:
    if temporary.parent != target.parent:
        raise ValueError("publication temporary must be a sibling of its target")
    status = None
    try:
        status = os.stat(target, follow_symlinks=False)
    except FileNotFoundError:
        pass
    if status is not None and not stat.S_ISREG(status.st_mode):
        raise ValueError(f"existing publication target is not a regular file: {target}")
    staged = artifact_description(temporary)
    return {
        "target": str(target),
        "temporary": str(temporary),
        "backup": str(
            target.with_name(f".{target.name}.mapgames-backup-{transaction_id}")
        ),
        "restore": str(
            target.with_name(f".{target.name}.mapgames-restore-{transaction_id}")
        ),
        "had_target": status is not None,
        "original_identity": (
            None if status is None else [status.st_dev, status.st_ino]
        ),
        "staged_identity": staged["identity"],
        "staged_size": staged["size"],
        "staged_sha256": staged["sha256"],
    }


def artifact_description(path: Path) -> dict:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError(f"publication artifact is not regular: {path}")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
            (before.st_dev, before.st_ino, before.st_size)
            != (after.st_dev, after.st_ino, after.st_size)
        ):
            raise RuntimeError(f"publication artifact changed while hashing: {path}")
        return {
            "identity": [after.st_dev, after.st_ino],
            "size": after.st_size,
            "sha256": digest.hexdigest(),
        }
    finally:
        os.close(descriptor)


def write_transaction_journal(path: Path, state: dict) -> None:
    temporary = temporary_sibling(path, "state")
    try:
        with temporary.open("wb") as output:
            output.write(canonical_json(state) + b"\n")
            output.flush()
            os.fsync(output.fileno())
        durable_replace(temporary, path)
    finally:
        remove_owned_path(temporary)


def begin_output_pair_transaction(
    database_temporary: Path,
    database_target: Path,
    manifest_temporary: Path,
    manifest_target: Path,
) -> dict:
    transaction_id = secrets.token_hex(16)
    journal = publication_journal_path(database_target, manifest_target)
    # Sync before hashing so the immutable journal describes durable bytes.
    fsync_file(database_temporary)
    fsync_file(manifest_temporary)
    fsync_parent_directories(database_temporary, manifest_temporary)
    state = {
        "schema_version": TRANSACTION_SCHEMA_VERSION,
        "transaction_id": transaction_id,
        "database": transaction_record(
            database_target, database_temporary, transaction_id
        ),
        "manifest": transaction_record(
            manifest_target, manifest_temporary, transaction_id
        ),
    }
    for record in (state["database"], state["manifest"]):
        for key in ("backup", "restore"):
            if path_present(Path(record[key])):
                raise RuntimeError(f"publication artifact already exists: {record[key]}")

    # The immutable journal is made durable before the first live mutation.
    # Directory syncs make its referenced staging entries recoverable too.
    write_transaction_journal(journal, state)
    for record in (state["database"], state["manifest"]):
        if record["had_target"]:
            durable_link(Path(record["target"]), Path(record["backup"]))
    return state


def validate_transaction_state(
    value: object, database_target: Path, manifest_target: Path
) -> dict:
    if not isinstance(value, dict) or set(value) != {
        "schema_version", "transaction_id", "database", "manifest"
    }:
        raise RuntimeError("invalid destination publication transaction journal")
    transaction_id = value.get("transaction_id")
    if (
        value.get("schema_version") != TRANSACTION_SCHEMA_VERSION
        or not isinstance(transaction_id, str)
        or _TRANSACTION_ID.fullmatch(transaction_id) is None
    ):
        raise RuntimeError("invalid destination publication transaction journal")
    for key, expected_target in (
        ("database", database_target), ("manifest", manifest_target)
    ):
        record = value.get(key)
        if not isinstance(record, dict) or set(record) != {
            "target", "temporary", "backup", "restore", "had_target",
            "original_identity", "staged_identity", "staged_size",
            "staged_sha256",
        }:
            raise RuntimeError("invalid destination publication transaction journal")
        if not isinstance(record["temporary"], str):
            raise RuntimeError("invalid destination publication transaction journal")
        temporary = Path(record["temporary"])
        expected_backup = expected_target.with_name(
            f".{expected_target.name}.mapgames-backup-{transaction_id}"
        )
        expected_restore = expected_target.with_name(
            f".{expected_target.name}.mapgames-restore-{transaction_id}"
        )
        identity = record["original_identity"]
        valid_identity = (
            isinstance(identity, list)
            and len(identity) == 2
            and all(type(part) is int and part >= 0 for part in identity)
        )
        staged_identity = record["staged_identity"]
        valid_staged_identity = (
            isinstance(staged_identity, list)
            and len(staged_identity) == 2
            and all(type(part) is int and part >= 0 for part in staged_identity)
        )
        if (
            record["target"] != str(expected_target)
            or type(record["had_target"]) is not bool
            or (record["had_target"] and not valid_identity)
            or (not record["had_target"] and identity is not None)
            or not valid_staged_identity
            or type(record["staged_size"]) is not int
            or record["staged_size"] < 0
            or not isinstance(record["staged_sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", record["staged_sha256"]) is None
            or not temporary.is_absolute()
            or temporary.parent != expected_target.parent
            or not temporary.name.startswith(expected_target.name + ".mapgames-build-")
            or temporary.name == expected_target.name + ".mapgames-build-"
            or record["backup"] != str(expected_backup)
            or record["restore"] != str(expected_restore)
        ):
            raise RuntimeError("invalid destination publication transaction journal")
    return value


def artifact_matches_staged(path: Path, record: dict) -> bool:
    if not path_present(path):
        return False
    try:
        description = artifact_description(path)
    except (OSError, RuntimeError):
        return False
    return (
        description["identity"] == record["staged_identity"]
        and description["size"] == record["staged_size"]
        and description["sha256"] == record["staged_sha256"]
    )


def artifact_matches_original(path: Path, record: dict) -> bool:
    if not record["had_target"] or not path_present(path):
        return False
    try:
        status = os.stat(path, follow_symlinks=False)
    except OSError:
        return False
    return (
        stat.S_ISREG(status.st_mode)
        and [status.st_dev, status.st_ino] == record["original_identity"]
    )


def classify_target(record: dict) -> str:
    target = Path(record["target"])
    if not path_present(target):
        return "missing" if record["had_target"] else "old"
    if artifact_matches_staged(target, record):
        return "new"
    if artifact_matches_original(target, record):
        return "old"
    return "unknown"


def restore_backup(record: dict) -> None:
    target = Path(record["target"])
    backup = Path(record["backup"])
    restore = Path(record["restore"])
    if not path_present(backup):
        raise RuntimeError(f"destination publication backup is missing: {backup}")
    backup_status = os.stat(backup, follow_symlinks=False)
    if (
        not stat.S_ISREG(backup_status.st_mode)
        or [backup_status.st_dev, backup_status.st_ino]
        != record["original_identity"]
    ):
        raise RuntimeError(f"destination publication backup identity changed: {backup}")
    durable_unlink(restore)
    durable_link(backup, restore)
    durable_replace(restore, target)


def recover_pending_publication(
    database_target: Path, manifest_target: Path
) -> bool:
    journal = publication_journal_path(database_target, manifest_target)
    if not path_present(journal):
        return False
    try:
        encoded = json.loads(journal.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(
            f"could not read destination publication transaction {journal}"
        ) from error
    state = validate_transaction_state(encoded, database_target, manifest_target)
    records = (state["database"], state["manifest"])
    # Staging names are evidence only when their durable identity and content
    # match the journal. Their absence is never interpreted as publication.
    for record in records:
        temporary = Path(record["temporary"])
        if path_present(temporary) and not artifact_matches_staged(temporary, record):
            raise RuntimeError(
                f"destination publication staging identity changed: {temporary}"
            )
        for key in ("backup", "restore"):
            artifact = Path(record[key])
            if path_present(artifact) and not artifact_matches_original(
                artifact, record
            ):
                raise RuntimeError(
                    f"destination publication recovery artifact changed: {artifact}"
                )

    target_states = [classify_target(record) for record in records]
    if "unknown" in target_states:
        raise RuntimeError(
            "destination publication targets do not match either durable generation"
        )

    if target_states != ["new", "new"]:
        # Any non-committed matrix is rolled back. Restoration is repeatable:
        # backups remain until both live targets prove they are the old pair.
        for record, target_state in zip(records, target_states, strict=True):
            target = Path(record["target"])
            if target_state in ("new", "missing"):
                if record["had_target"]:
                    restore_backup(record)
                else:
                    durable_unlink(target)
        target_states = [classify_target(record) for record in records]
        if target_states != ["old", "old"]:
            raise RuntimeError(
                "destination publication rollback did not restore the old pair"
            )

    # Cleanup is permitted only after the live pair is proven wholly new or
    # wholly old. Unknown/mixed failures retain every recovery input.
    for record in records:
        durable_unlink(Path(record["temporary"]))
        durable_unlink(Path(record["restore"]))
        durable_unlink(Path(record["backup"]))
    durable_unlink(journal)
    return True


def recover_output_pair(database_target: Path, manifest_target: Path) -> bool:
    database_target = canonical_target(database_target)
    manifest_target = canonical_target(manifest_target)
    with publication_lock(database_target, manifest_target):
        return recover_pending_publication(database_target, manifest_target)


def remove_unjournaled_temporary(path: Path, journal: Path) -> None:
    # A surviving journal owns every staging/recovery artifact. In particular,
    # do not erase the only remaining evidence after publication and rollback
    # both failed; the next invocation must classify the live targets first.
    if path_present(journal):
        return
    remove_owned_path(path)


def publish_output_pair(
    database_temporary: Path,
    database_target: Path,
    manifest_temporary: Path,
    manifest_target: Path,
) -> None:
    database_target = canonical_target(database_target)
    manifest_target = canonical_target(manifest_target)
    database_temporary = canonical_target(database_temporary)
    manifest_temporary = canonical_target(manifest_temporary)
    with publication_lock(database_target, manifest_target):
        recover_pending_publication(database_target, manifest_target)
        journal = publication_journal_path(database_target, manifest_target)
        try:
            state = begin_output_pair_transaction(
                database_temporary,
                database_target,
                manifest_temporary,
                manifest_target,
            )
            # The CLI exposes two independent paths, so readers can observe a
            # mixed generation between these individually atomic renames. The
            # durable journal makes that window recoverable for writers, but a
            # reader needing pair atomicity must wait for command completion.
            durable_replace(database_temporary, database_target)
            durable_replace(manifest_temporary, manifest_target)
            for record in (state["database"], state["manifest"]):
                durable_unlink(Path(record["backup"]))
            durable_unlink(journal)
        except BaseException as publish_error:
            try:
                recover_pending_publication(database_target, manifest_target)
            except BaseException as recovery_error:
                raise BaseExceptionGroup(
                    "destination publication failed and recovery also failed",
                    [publish_error, recovery_error],
                )
            raise


def build(routes, database_path: Path, manifest_path: Path,
          native_tool: Path) -> dict:
    started = time.perf_counter()
    ordered = sorted(routes, key=lambda route: (route[0], route[1]))
    if not ordered or len({(service, mode) for service, mode, _ in ordered}) != len(ordered):
        raise ValueError("routes must be nonempty and unique by service/mode")
    database_path = canonical_target(database_path)
    manifest_path = canonical_target(manifest_path)
    journal_path = publication_journal_path(database_path, manifest_path)
    outputs = [
        ("database output", database_path),
        ("manifest output", manifest_path),
        ("publication journal", journal_path),
    ]
    route_inputs = [
        (f"route input {service}/{mode}", path)
        for service, mode, path in ordered
    ]
    require_distinct_paths(outputs)
    for output in outputs:
        for route_input in route_inputs:
            require_distinct_paths([output, route_input])
    # Recover before doing another expensive native build. Publication also
    # repeats this check while holding the same directory locks, covering a
    # concurrent builder that finished staging in the meantime.
    recover_output_pair(database_path, manifest_path)
    database_temporary = temporary_sibling(database_path, "build")
    manifest_temporary = temporary_sibling(manifest_path, "build")
    try:
        command = [
            native_tool,
            "--finalize-relations",
            "--database",
            database_temporary,
        ]
        for service, mode, path in ordered:
            command.extend(("--route", f"{service}:{mode}:{path}"))
        subprocess.run([str(value) for value in command], check=True)
        database = sqlite3.connect(f"file:{database_temporary}?mode=ro", uri=True)
        try:
            edge_count, _spatial_hit_count = normalization_counts(database)
            empty = database.execute(
                "SELECT requirement,minute FROM presets "
                "WHERE set_count IS NULL OR set_count=0 LIMIT 1"
            ).fetchone()
            if empty is not None:
                raise ValueError(f"native relation finalizer left empty preset {empty}")
            requirements = requirements_manifest(database)
        finally:
            database.close()
        # Native publication is itself durable, but explicitly sync the closed,
        # validated staging database before this wrapper journals it as ready.
        fsync_file(database_temporary)
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
        with manifest_temporary.open("wb") as output:
            output.write(canonical_json(manifest) + b"\n")
            output.flush()
            os.fsync(output.fileno())
        database_size = database_temporary.stat().st_size
        publish_output_pair(
            database_temporary,
            database_path,
            manifest_temporary,
            manifest_path,
        )
        elapsed = time.perf_counter() - started
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        print(
            f"[mapgames] lookup complete: {manifest['edge_count']} edges, {elapsed:.3f}s, "
            f"maxrss={rss} KiB, sqlite={database_size} bytes",
            file=sys.stderr,
        )
        return manifest
    finally:
        remove_unjournaled_temporary(database_temporary, journal_path)
        remove_unjournaled_temporary(manifest_temporary, journal_path)


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
