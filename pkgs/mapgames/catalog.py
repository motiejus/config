#!/usr/bin/env python3

"""Stream canonical metadata and spatial-hit pages into one MBTiles file."""

import argparse
import gzip
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import struct


SCHEMA_VERSION = 3
PAGE_ZOOM = 18
SPATIAL_ZOOM = 15
OBJECT_PAGE_SIZE = 64
OBJECT_LOCATION_PAGE_SIZE = 512
DESTINATION_SET_PAGE_SIZE = 32
DESTINATION_EDGE_PAGE_SIZE = 64
RECORD_PAGE_SIZE = 32
PLACE_ID_BUCKETS = 256
MAX_PAGE_GZIP_BYTES = 64 * 1024
MAX_PAGE_RAW_BYTES = 512 * 1024
MAX_HIT_GZIP_BYTES = 64 * 1024
MAX_HIT_RAW_BYTES = 512 * 1024
MAX_LOOKUP_CANDIDATES = 20_000
MAX_LOOKUP_RELATION_PAGES = 512
MAX_EDGE_POINTS = 1_000_000
SQLITE_FETCH_BATCH = 8192

# The edge identity is the exact canonical byte stream consumed by catalog
# clients, not a second per-record JSON serialization beside that stream.
EDGE_BUILD_ID_DOMAIN = b"mapgames-catalog-edge-build-id-v3"


def canonical_json(value) -> bytes:
    return (
        json.dumps(
            value, ensure_ascii=False, allow_nan=False,
            separators=(",", ":"), sort_keys=True,
        ) + "\n"
    ).encode("utf-8")


def fnv1a32(value: str) -> int:
    result = 2_166_136_261
    for byte in value.encode("utf-8"):
        result ^= byte
        result = (result * 16_777_619) & 0xFFFFFFFF
    return result


def same_file_identity(left: Path, right: Path) -> bool:
    """Compare lexical, symlink, and (when both exist) hardlink identity."""
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


def require_distinct_io_paths(
    inputs: list[tuple[str, Path]], outputs: list[tuple[str, Path]],
) -> None:
    """Reject every destructive output/output and output/input alias."""
    require_distinct_paths(outputs)
    for output in outputs:
        for input_path in inputs:
            require_distinct_paths([output, input_path])


def iter_json_array(path: Path):
    """Incrementally decode one top-level JSON array."""
    decoder = json.JSONDecoder()
    with path.open(encoding="utf-8") as source:
        buffer = ""
        position = 0
        started = finished = False
        state = "value_or_end"
        while not finished:
            if position > 1024 * 1024:
                buffer, position = buffer[position:], 0
            chunk = source.read(64 * 1024)
            if chunk:
                buffer += chunk
            eof = not chunk
            while True:
                while position < len(buffer) and buffer[position].isspace():
                    position += 1
                if not started:
                    if position >= len(buffer):
                        break
                    if buffer[position] != "[":
                        raise ValueError(f"{path}: expected a top-level JSON array")
                    started, position = True, position + 1
                    continue
                while position < len(buffer) and buffer[position].isspace():
                    position += 1
                if position >= len(buffer):
                    break
                if state in ("value_or_end", "comma_or_end") and buffer[position] == "]":
                    finished, position = True, position + 1
                    break
                if state == "comma_or_end":
                    if buffer[position] != ",":
                        raise ValueError(f"{path}: expected ',' or ']' in JSON array")
                    state, position = "value", position + 1
                    continue
                if state == "value" and buffer[position] == "]":
                    raise ValueError(f"{path}: trailing comma in JSON array")
                try:
                    value, position = decoder.raw_decode(buffer, position)
                except json.JSONDecodeError:
                    if eof:
                        raise ValueError(f"{path}: truncated or invalid JSON array")
                    break
                yield value
                state = "comma_or_end"
            if eof:
                break
        if not finished or buffer[position:].strip():
            raise ValueError(f"{path}: invalid trailing JSON")
        while chunk := source.read(64 * 1024):
            if chunk.strip():
                raise ValueError(f"{path}: trailing data after JSON array")


def validate_object(record, index: int) -> None:
    if not isinstance(record, dict) or type(record.get("index")) is not int or record["index"] != index:
        raise ValueError(f"object {index} has invalid index")
    if not isinstance(record.get("place_id"), str) or not record["place_id"]:
        raise ValueError(f"object {index} has invalid place_id")
    if not isinstance(record.get("service"), str) or not record["service"]:
        raise ValueError(f"object {index} has invalid service")
    for coordinate in ("lon", "lat"):
        value = record.get(coordinate)
        if type(value) not in (int, float) or not math.isfinite(value):
            raise ValueError(f"object {index} has invalid {coordinate}")


def compact_display(record: dict) -> tuple[str, str]:
    candidates = [record.get("name"), record.get("brand")]
    label = next((value for value in candidates if isinstance(value, str) and value), "")
    kind = record.get("kind")
    return label, kind if isinstance(kind, str) else ""


def require_lookup_schema(database: sqlite3.Connection) -> None:
    required = {
        "metadata", "requirements", "presets", "edges", "sets",
        "relation_runs", "relation_points", "spatial_hits",
    }
    tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not required <= tables:
        raise ValueError(f"lookup database missing tables: {sorted(required - tables)}")
    expected_columns = {
        "edges": ["edge_pk", "edge_id", "delta_coords", "mode_mask"],
        "spatial_hits": ["x", "y", "edge_id"],
    }
    for table, expected in expected_columns.items():
        actual = [row[1] for row in database.execute(f"PRAGMA table_info({table})")]
        if actual != expected:
            raise ValueError(f"lookup database has incompatible {table} schema")
    metadata = dict(database.execute("SELECT key,value FROM metadata"))
    if metadata.get("schema_version") != str(SCHEMA_VERSION):
        raise ValueError("lookup database has incompatible schema_version")
    if metadata.get("spatial_zoom") != str(SPATIAL_ZOOM):
        raise ValueError("lookup database has incompatible spatial_zoom")
    if "edge_build_id" in metadata:
        raise ValueError("lookup database contains a provisional edge_build_id")


def requirements_manifest(database: sqlite3.Connection) -> list[dict]:
    result = []
    previous_key = ""
    for ordinal, key, service, mode, mode_bit in database.execute(
        "SELECT requirement,key,service,mode,mode_bit FROM requirements ORDER BY requirement"
    ):
        if (
            ordinal != len(result) or not isinstance(key, str) or key <= previous_key
            or re.fullmatch(r"[a-z]+", service or "") is None
            or mode not in ("walk", "drive") or key != f"{service}_{mode}"
            or mode_bit != {"walk": 1, "drive": 2}[mode]
        ):
            raise ValueError(f"invalid requirement {ordinal}")
        previous_key = key
        presets = []
        previous_minute = 0
        for minute, collection, count in database.execute(
            "SELECT minute,collection,set_count FROM presets WHERE requirement=? ORDER BY minute",
            (ordinal,),
        ):
            if (
                minute <= previous_minute
                or collection != f"destination_edge_set:{service}:{mode}:{minute}"
                or type(count) is not int or count <= 0
            ):
                raise ValueError(f"invalid preset for requirement {ordinal}")
            presets.append({"minutes": minute, "set_collection": collection, "set_count": count})
            previous_minute = minute
        if not presets:
            raise ValueError(f"requirement {ordinal} has no presets")
        result.append(
            {"key": key, "service": service, "mode": mode, "mode_bit": mode_bit, "presets": presets}
        )
    if not result:
        raise ValueError("lookup database has no requirements")
    return result


def decode_u32_blob(value: bytes, context: str) -> list[int]:
    if not isinstance(value, bytes) or not value or len(value) % 4:
        raise ValueError(f"invalid {context} encoding")
    return [item[0] for item in struct.iter_unpack("<I", value)]


def decode_i32_blob(value: bytes, context: str) -> list[int]:
    if not isinstance(value, bytes) or len(value) < 16 or len(value) % 8:
        raise ValueError(f"invalid {context} encoding")
    return [item[0] for item in struct.iter_unpack("<i", value)]


def decode_delta_e7_blob(value: bytes, context: str) -> list[int]:
    """Validate one bounded geometry while preserving its delta representation."""
    if isinstance(value, bytes) and len(value) > MAX_EDGE_POINTS * 8:
        raise ValueError(f"invalid {context} point count")
    coords = decode_i32_blob(value, context)
    point_count = len(coords) // 2
    if point_count > MAX_EDGE_POINTS:
        raise ValueError(f"invalid {context} point count")

    lon, lat = coords[:2]

    def require_wgs84(current_lon: int, current_lat: int) -> None:
        if not (-1_800_000_000 <= current_lon <= 1_800_000_000) or not (
            -900_000_000 <= current_lat <= 900_000_000
        ):
            raise ValueError(f"{context} coordinate out of bounds")

    require_wgs84(lon, lat)
    for offset in range(2, len(coords), 2):
        delta_lon, delta_lat = coords[offset : offset + 2]
        if delta_lon == 0 and delta_lat == 0:
            raise ValueError(f"degenerate {context}")
        lon += delta_lon
        lat += delta_lat
        require_wgs84(lon, lat)

    # Native canonicalization compares the semicolon-terminated decimal E7
    # coordinate stream with its reverse. Compare one token at a time to avoid
    # retaining a second absolute-coordinate array or two large strings.
    forward_lon, forward_lat = coords[:2]
    reverse_lon, reverse_lat = lon, lat
    for index in range(point_count):
        forward = f"{forward_lon},{forward_lat};"
        reverse = f"{reverse_lon},{reverse_lat};"
        if reverse < forward:
            raise ValueError(f"non-canonical {context}")
        if reverse > forward:
            break
        if index + 1 < point_count:
            forward_offset = 2 * (index + 1)
            forward_lon += coords[forward_offset]
            forward_lat += coords[forward_offset + 1]
            reverse_offset = 2 * (point_count - 1 - index)
            reverse_lon -= coords[reverse_offset]
            reverse_lat -= coords[reverse_offset + 1]
    return coords


def buffered_rows(cursor: sqlite3.Cursor):
    """Iterate an ordered SQLite cursor through bounded C-level batches."""
    while rows := cursor.fetchmany(SQLITE_FETCH_BATCH):
        yield from rows


def edge_entries(database: sqlite3.Connection):
    # Both source tables are WITHOUT ROWID and physically ordered by this key.
    # Merge their two streaming cursors rather than materializing and sorting a
    # 32M-row union in the handoff database.
    runs = buffered_rows(database.execute(
        "SELECT edge_pk,requirement,minute,0,sequence,start,end,set_id "
        "FROM relation_runs ORDER BY edge_pk,requirement,minute,sequence"
    ))
    points = buffered_rows(database.execute(
        "SELECT edge_pk,requirement,minute,1,sequence,point,NULL,set_id "
        "FROM relation_points ORDER BY edge_pk,requirement,minute,sequence"
    ))
    run = next(runs, None)
    point = next(points, None)
    expected_edge_id = 0
    for edge_pk, edge_id, mode_mask, encoded_coords in database.execute(
        "SELECT edge_pk,edge_id,mode_mask,delta_coords FROM edges ORDER BY edge_pk"
    ):
        if edge_pk != edge_id + 1 or edge_id != expected_edge_id or mode_mask not in (1, 2, 3):
            raise ValueError(f"invalid edge identity {edge_id}")
        # Validate every canonical geometry once at the producer boundary.
        # The spatial-hit pages retain the encoded geometry used by the
        # client; relation pages contain only their mode and routes.
        decode_delta_e7_blob(encoded_coords, f"edge coordinates {edge_id}")
        routes = []
        while (run is not None and run[0] == edge_pk) or (point is not None and point[0] == edge_pk):
            if point is None or (
                run is not None
                and (run[0], run[1], run[2], run[3], run[4])
                < (point[0], point[1], point[2], point[3], point[4])
            ):
                item = run
                run = next(runs, None)
            else:
                item = point
                point = next(points, None)
            _, requirement, minute, kind, sequence, a, b, set_id = item
            if not routes or routes[-1][0] != requirement:
                if routes and requirement <= routes[-1][0]:
                    raise ValueError(f"unsorted routes for edge {edge_id}")
                routes.append([requirement, []])
            if not routes[-1][1] or routes[-1][1][-1][0] != minute:
                if routes[-1][1] and minute <= routes[-1][1][-1][0]:
                    raise ValueError(f"unsorted presets for edge {edge_id}")
                routes[-1][1].append([minute, [], []])
            destination = routes[-1][1][-1][1 + kind]
            if sequence != len(destination):
                raise ValueError(f"non-contiguous relation sequence for edge {edge_id}")
            destination.append([a, b, set_id] if kind == 0 else [a, set_id])
        if not routes:
            raise ValueError(f"edge {edge_id} has no relations")
        yield [mode_mask, routes]
        expected_edge_id += 1
    if run is not None or point is not None:
        raise ValueError("relation references unknown edge")


def pack(
    objects_path: Path,
    lookup_path: Path,
    mbtiles_path: Path,
    manifest_path: Path,
    record_collections: dict[str, Path] | None = None,
) -> dict:
    inputs = [
        ("objects input", objects_path),
        ("lookup database input", lookup_path),
        *(
            (f"record collection input {name!r}", path)
            for name, path in sorted((record_collections or {}).items())
        ),
    ]
    outputs = [
        ("MBTiles output", mbtiles_path),
        ("manifest output", manifest_path),
    ]
    # Validate before opening the lookup or unlinking/recreating either output.
    require_distinct_io_paths(inputs, outputs)
    lookup = sqlite3.connect(f"file:{lookup_path}?mode=ro", uri=True)
    require_lookup_schema(lookup)
    requirements = requirements_manifest(lookup)
    # Compute the published content identity from the exact canonical page
    # bytes clients consume. Length-prefix every component so collection and
    # page boundaries are unambiguous without a second per-record encoding.
    build_digest = hashlib.sha256()
    build_digest.update(EDGE_BUILD_ID_DOMAIN)

    def update_build_digest(
        kind: int, name: str, page_number: int, raw: bytes,
        tile: tuple[int, int, int] | None = None,
    ) -> None:
        encoded_name = name.encode("utf-8")
        build_digest.update(
            struct.pack(
                ">BIQQB", kind, len(encoded_name), page_number, len(raw), tile is not None,
            )
        )
        build_digest.update(encoded_name)
        if tile is not None:
            build_digest.update(struct.pack(">BQQ", *tile))
        build_digest.update(raw)

    update_build_digest(0, "requirements", 0, canonical_json(requirements))

    if mbtiles_path.exists():
        mbtiles_path.unlink()
    output = sqlite3.connect(mbtiles_path)
    try:
        output.executescript(
            """
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE tiles (
              zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB,
              PRIMARY KEY (zoom_level,tile_column,tile_row)
            );
            CREATE TABLE work_objects (
              object_id INTEGER PRIMARY KEY, place_id TEXT NOT NULL UNIQUE,
              service TEXT NOT NULL, lon REAL NOT NULL, lat REAL NOT NULL,
              display_label TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL
            );
            CREATE TABLE work_place_ids (
              place_id TEXT PRIMARY KEY, object_id INTEGER NOT NULL,
              bucket INTEGER NOT NULL
            );
            CREATE INDEX work_place_ids_bucket ON work_place_ids(bucket,place_id);
            """
        )
        object_count = 0
        for index, record in enumerate(iter_json_array(objects_path)):
            validate_object(record, index)
            display_label, kind = compact_display(record)
            output.execute(
                "INSERT INTO work_objects VALUES (?,?,?,?,?,?,?,?)",
                (
                    index, record["place_id"], record["service"], record["lon"], record["lat"],
                    display_label, kind,
                    canonical_json(record).decode("utf-8").rstrip("\n"),
                ),
            )
            indexed_place_id = record["place_id"]
            try:
                output.execute(
                    "INSERT INTO work_place_ids VALUES (?,?,?)",
                    (
                        indexed_place_id,
                        index,
                        fnv1a32(indexed_place_id) & (PLACE_ID_BUCKETS - 1),
                    ),
                )
            except sqlite3.IntegrityError as error:
                raise ValueError(f"duplicate place identity {indexed_place_id}") from error
            object_count += 1
        if object_count == 0:
            raise ValueError("objects must be a non-empty array")
        collections = {}
        next_x = 0
        page_stats = {}

        def insert_payload(
            zoom, x, y, value, name, page_number, spatial=False, identity=False,
        ):
            raw = canonical_json(value)
            if identity:
                update_build_digest(
                    1, name, page_number, raw,
                    tile=(zoom, x, y) if spatial else None,
                )
            # Level 6 is materially faster for the tens of thousands of build
            # pages and only marginally larger. Preserve the hard mobile gate
            # by retrying an oversized page at level 9 before rejecting it.
            payload = gzip.compress(raw, compresslevel=6, mtime=0)
            raw_limit = MAX_HIT_RAW_BYTES if spatial else MAX_PAGE_RAW_BYTES
            gzip_limit = MAX_HIT_GZIP_BYTES if spatial else MAX_PAGE_GZIP_BYTES
            if len(payload) > gzip_limit:
                payload = gzip.compress(raw, compresslevel=9, mtime=0)
            if len(raw) > raw_limit or len(payload) > gzip_limit:
                raise ValueError(
                    f"catalog page {name}[{page_number}] exceeds mobile size gate: "
                    f"{len(raw)} raw, {len(payload)} gzip bytes"
                )
            output.execute(
                "INSERT INTO tiles VALUES (?,?,?,?)",
                (zoom, x, 2**zoom - 1 - y, payload),
            )
            stats = page_stats.setdefault(name, {"raw_max": 0, "gzip_max": 0, "gzip_total": 0})
            stats["raw_max"] = max(stats["raw_max"], len(raw))
            stats["gzip_max"] = max(stats["gzip_max"], len(payload))
            stats["gzip_total"] += len(payload)

        def add_collection(
            name, count, page_size, values, allow_empty=False,
            max_request_pages=None, identity=False,
        ):
            nonlocal next_x
            base = next_x
            pages = 0
            item_count = 0
            iterator = iter(values)
            while batch := list(itertools.islice(iterator, page_size)):
                if next_x >= 2**PAGE_ZOOM:
                    raise ValueError("catalog page count exceeds synthetic x range")
                insert_payload(
                    PAGE_ZOOM, next_x, 0, batch, name, pages,
                    identity=identity,
                )
                next_x += 1
                pages += 1
                item_count += len(batch)
            if pages == 0 and not allow_empty:
                raise ValueError(f"empty catalog collection {name}")
            if count is not None and item_count != count:
                raise ValueError(
                    f"catalog collection {name} has {item_count} records, expected {count}"
                )
            count = item_count if count is None else count
            collections[name] = {
                "base": base, "count": count, "page_size": page_size, "pages": pages,
            }
            if max_request_pages is not None:
                collections[name]["max_request_pages"] = max_request_pages
            return item_count

        add_collection(
            "objects", object_count, OBJECT_PAGE_SIZE,
            (json.loads(row[0]) for row in output.execute("SELECT payload FROM work_objects ORDER BY object_id")),
        )
        services = [row[0] for row in output.execute("SELECT DISTINCT service FROM work_objects ORDER BY service")]
        service_ordinals = {service: ordinal for ordinal, service in enumerate(services)}
        add_collection(
            "object_locations", object_count, OBJECT_LOCATION_PAGE_SIZE,
            (
                [
                    round(lon * 10_000_000), round(lat * 10_000_000),
                    service_ordinals[service], display_label, kind,
                ]
                for lon, lat, service, display_label, kind in output.execute(
                    "SELECT lon,lat,service,display_label,kind "
                    "FROM work_objects ORDER BY object_id"
                )
            ),
        )

        bucket_base = next_x
        for bucket in range(PLACE_ID_BUCKETS):
            value = {
                place_id: object_id
                for place_id, object_id in output.execute(
                    "SELECT place_id,object_id FROM work_place_ids WHERE bucket=? ORDER BY place_id",
                    (bucket,),
                )
            }
            insert_payload(PAGE_ZOOM, next_x, 0, value, "place_id_index", bucket)
            next_x += 1
        collections["place_id_index"] = {
            "base": bucket_base, "count": PLACE_ID_BUCKETS, "page_size": 1, "pages": PLACE_ID_BUCKETS,
        }

        for name, path in sorted((record_collections or {}).items()):
            if (
                re.fullmatch(r"[a-z][a-z0-9_]*", name) is None
                or name in collections
                or name in ("destination_edges", "destination_hit")
            ):
                raise ValueError(f"invalid record collection {name!r}")

            def records():
                for number, record in enumerate(iter_json_array(path)):
                    if not isinstance(record, dict):
                        raise ValueError(f"invalid {name} record {number}")
                    yield record

            add_collection(name, None, RECORD_PAGE_SIZE, records(), allow_empty=True)

        for ordinal, requirement in enumerate(requirements):
            for preset in requirement["presets"]:
                minute = preset["minutes"]

                def destination_sets():
                    expected_set_id = 0
                    for set_id, members in lookup.execute(
                        "SELECT set_id,members FROM sets "
                        "WHERE requirement=? AND minute=? ORDER BY set_id",
                        (ordinal, minute),
                    ):
                        decoded = decode_u32_blob(
                            members, f"destination set {ordinal}/{minute}/{set_id}"
                        )
                        valid_members = bool(decoded)
                        previous_member = -1
                        for member in decoded:
                            if member <= previous_member or member >= object_count:
                                valid_members = False
                                break
                            previous_member = member
                        if set_id != expected_set_id or not valid_members:
                            raise ValueError(
                                f"invalid destination set {ordinal}/{minute}/{set_id}"
                            )
                        expected_set_id += 1
                        yield decoded

                add_collection(
                    preset["set_collection"], preset["set_count"], DESTINATION_SET_PAGE_SIZE,
                    destination_sets(), identity=True,
                )
        add_collection(
            "destination_edges", None, DESTINATION_EDGE_PAGE_SIZE,
            edge_entries(lookup), identity=True,
        )

        spatial_zoom = int(
            lookup.execute("SELECT value FROM metadata WHERE key='spatial_zoom'").fetchone()[0]
        )
        spatial_tiles = spatial_candidates = 0
        spatial_candidate_max = spatial_relation_page_max = 0
        lookup_candidate_max = lookup_relation_page_max = 0
        previous_column_x = None
        previous_column = {}
        first_column_x = None
        first_column = {}
        current_column_x = None
        current_column = {}

        def measure_spatial_columns(left, right):
            nonlocal lookup_candidate_max, lookup_relation_page_max
            anchors = {
                anchor
                for y in (*left.keys(), *right.keys())
                for anchor in (y - 1, y)
            }
            for anchor in anchors:
                edges = set()
                pages = set()
                for column in (left, right):
                    for y in (anchor, anchor + 1):
                        if y in column:
                            tile_edges, tile_pages = column[y]
                            edges.update(tile_edges)
                            pages.update(tile_pages)
                lookup_candidate_max = max(lookup_candidate_max, len(edges))
                lookup_relation_page_max = max(lookup_relation_page_max, len(pages))

        def finish_spatial_column():
            nonlocal previous_column_x, previous_column
            nonlocal first_column_x, first_column
            nonlocal current_column_x, current_column
            if current_column_x is None:
                return
            left = previous_column if previous_column_x == current_column_x - 1 else {}
            measure_spatial_columns(left, current_column)
            if first_column_x is None:
                first_column_x, first_column = current_column_x, current_column
            previous_column_x, previous_column = current_column_x, current_column
            current_column_x, current_column = None, {}

        def record_spatial_fanout(key, edge_ids, relation_pages):
            nonlocal current_column_x, current_column
            _zoom, x, y = key
            if current_column_x is not None and x != current_column_x:
                finish_spatial_column()
            if current_column_x is None:
                current_column_x = x
            # Ownership transfers with this page: the caller rebinds fresh
            # sets for the next page, so retaining these avoids two copies.
            current_column[y] = (edge_ids, relation_pages)

        def write_spatial_page(key, values, edge_ids, relation_pages):
            nonlocal spatial_tiles, spatial_candidates
            nonlocal spatial_candidate_max, spatial_relation_page_max
            relation_page_count = len(relation_pages)
            insert_payload(
                *key, values, "destination_hit", spatial_tiles,
                spatial=True, identity=True,
            )
            spatial_tiles += 1
            spatial_candidates += len(values)
            spatial_candidate_max = max(spatial_candidate_max, len(values))
            spatial_relation_page_max = max(
                spatial_relation_page_max, relation_page_count
            )
            record_spatial_fanout(key, edge_ids, relation_pages)

        current = None
        candidates = []
        candidate_edge_ids = set()
        candidate_relation_pages = set()
        for x, y, edge_id, mode_mask, encoded_coords in lookup.execute(
            "SELECT h.x,h.y,h.edge_id,e.mode_mask,e.delta_coords "
            "FROM spatial_hits h LEFT JOIN edges e ON e.edge_id=h.edge_id "
            "ORDER BY h.x,h.y,h.edge_id"
        ):
            key = (spatial_zoom, x, y)
            if current is not None and key != current:
                write_spatial_page(
                    current, candidates,
                    candidate_edge_ids, candidate_relation_pages,
                )
                candidates = []
                candidate_edge_ids = set()
                candidate_relation_pages = set()
            current = key
            if mode_mask is None or encoded_coords is None:
                raise ValueError("spatial hit references an unknown edge")
            candidates.append([
                edge_id,
                mode_mask,
                decode_i32_blob(encoded_coords, f"spatial edge coordinates {edge_id}"),
            ])
            candidate_edge_ids.add(edge_id)
            candidate_relation_pages.add(edge_id // DESTINATION_EDGE_PAGE_SIZE)
        if current is None:
            raise ValueError("lookup database has no spatial hit pages")
        write_spatial_page(
            current, candidates, candidate_edge_ids, candidate_relation_pages,
        )
        finish_spatial_column()
        if first_column_x == 0 and previous_column_x == 2**spatial_zoom - 1:
            # XYZ x wraps at the antimeridian; include the one 2x2 block that
            # is not adjacent in numeric sort order in the published worst
            # lookup fanout.
            measure_spatial_columns(previous_column, first_column)
        if (
            lookup_candidate_max > MAX_LOOKUP_CANDIDATES
        ):
            raise ValueError(
                "worst 2x2 spatial lookup exceeds candidate fanout gate: "
                f"{lookup_candidate_max} candidates"
            )
        if lookup_relation_page_max > MAX_LOOKUP_RELATION_PAGES:
            raise ValueError(
                "worst 2x2 spatial lookup exceeds relation-page resource gate: "
                f"{lookup_relation_page_max} pages"
            )
        # Geometry filtering can only remove candidates from this measured
        # raw 2x2 lookup. Publish that artifact-derived relation-page bound
        # instead of assuming a smaller postfilter result that is not proved.
        collections["destination_edges"]["max_request_pages"] = (
            lookup_relation_page_max
        )
        edge_build_id = build_digest.hexdigest()

        manifest = {
            "schema_version": SCHEMA_VERSION,
            "page_zoom": PAGE_ZOOM,
            "page_addressing": f"XYZ z={PAGE_ZOOM}, x=collection.base+page, y=0",
            "hash": {"buckets": PLACE_ID_BUCKETS, "name": "fnv1a32-utf8"},
            "collections": collections,
            "object_locations": {
                "collection": "object_locations",
                "encoding": "[lonE7,latE7,serviceOrdinal,displayLabel,kind]",
                "service_ordinals": services,
            },
            "edge_build_id": edge_build_id,
            "spatial": {
                "edge_build_id": edge_build_id,
                "zoom": spatial_zoom,
                "addressing": "XYZ direct tile coordinates in catalog.pmtiles",
                "candidate_encoding": "sorted [edge_id,modeMask,deltaE7] arrays",
                "neighbor_radius": 1,
                "tiles": spatial_tiles,
                "candidates": spatial_candidates,
                "fanout_gate": {
                    "candidates_per_lookup": MAX_LOOKUP_CANDIDATES,
                    "postfilter_relation_pages_per_lookup": lookup_relation_page_max,
                },
                "fanout_stats": {
                    "candidates_per_tile_max": spatial_candidate_max,
                    "relation_pages_per_tile_max": spatial_relation_page_max,
                    "candidates_per_lookup_max": lookup_candidate_max,
                    "relation_pages_per_lookup_raw_max": lookup_relation_page_max,
                },
                "page_size_gate": {"raw": MAX_HIT_RAW_BYTES, "gzip": MAX_HIT_GZIP_BYTES},
                "page_stats": page_stats["destination_hit"],
            },
            "page_stats": page_stats,
        }
        metadata = {
            "bounds": "-180,-85,180,85",
            "json": canonical_json(manifest).decode().strip(),
        }
        output.executemany("INSERT INTO metadata VALUES (?,?)", sorted(metadata.items()))
        output.execute("DROP TABLE work_place_ids")
        output.execute("DROP TABLE work_objects")
        output.commit()
        manifest_path.write_bytes(canonical_json(manifest))
        return manifest
    finally:
        output.close()
        lookup.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--objects", type=Path, required=True)
    parser.add_argument("--lookup-database", type=Path, required=True)
    parser.add_argument("--record-collection", action="append", default=[])
    parser.add_argument("--mbtiles-out", type=Path, required=True)
    parser.add_argument("--manifest-out", type=Path, required=True)
    args = parser.parse_args()
    record_collections = {}
    for value in args.record_collection:
        name, separator, path = value.partition("=")
        if not separator or name in record_collections:
            raise SystemExit("--record-collection must be unique NAME=PATH")
        record_collections[name] = Path(path)
    pack(
        args.objects,
        args.lookup_database,
        args.mbtiles_out,
        args.manifest_out,
        record_collections,
    )


if __name__ == "__main__":
    main()
