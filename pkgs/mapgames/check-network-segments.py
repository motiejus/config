#!/usr/bin/env python3
"""Gate checker for the merge tool (unified-access-layer step 4).

Independently re-executes docs/unified-access-layer.md section 1.3 steps 0-3
from the per-route edge-interval dumps alone — its own dump parsing, step-0
geometry-string pre-merge across dumps, endpoint collection, 1e-12 first-wins
dedup, midpoint classification with the nesting abort, and coalescing — and
compares the result for EXACT equality (bitwise-equal doubles, identical
attribute maps, identical piece order) against the merge tool's
--debug-segments pre-slicing segmentation table. Both sides are keyed by the
canonical geometry string, the only cross-route join key (a dual-digitized
group's uint64 representative can differ per route). Shares no code with
valhalla-expand.cc.

usage: check-network-segments.py --debug-segments segments.tsv \
           work/edges-coffee-walk.tsv work/edges-fuel-drive.tsv ...

Requirement keys derive from the dump filenames (edges-<service>-<mode>.tsv
-> <service>_<mode>); band minute lists are the per-dump union of band
labels. Exits 0 on exact equality, 1 otherwise.
"""

import argparse
import json
import math
import os
import re
import sys

_NUMBER = r"[0-9.]+(?:[eE][-+]?[0-9]+)?"
_INTERVAL_RE = re.compile(rf"^({_NUMBER})-({_NUMBER})$")
# Grammar shared with requirement_key_from_dump() in valhalla-expand.cc and
# the authoritative-key assertion in generate.py. Keep the three in lockstep.
_DUMP_NAME_RE = re.compile(r"^edges-([a-z]+)-([a-z]+)\.tsv$")


def llround(value):
    if value >= 0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


def line_key(line):
    return "".join(
        "%d,%d;" % (llround(lon * 10000000), llround(lat * 10000000))
        for lon, lat in line
    )


def merge_intervals(intervals):
    merged = []
    for start, end in sorted(intervals):
        if end - start <= 1e-12:
            continue
        if not merged or start > merged[-1][1] + 1e-12:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return merged


def parse_dump(path):
    """Returns (entries, minutes): entries as (line, {minute: intervals}),
    minutes as the ascending union of band labels."""
    entries = []
    minutes = set()
    previous_id = None
    with open(path, "r", encoding="ascii") as handle:
        for line_number, raw in enumerate(handle, 1):
            raw = raw.rstrip("\n")
            if not raw:
                continue
            fields = raw.split("\t")
            if len(fields) != 3:
                raise SystemExit(f"{path}:{line_number}: expected 3 TSV fields")
            edge_id = int(fields[0])
            if previous_id is not None and edge_id <= previous_id:
                raise SystemExit(
                    f"{path}:{line_number}: keys not in ascending uint64 order"
                )
            previous_id = edge_id
            geometry = []
            for token in fields[1].split(";"):
                lon, lat = token.split(",")
                geometry.append((float(lon), float(lat)))
            if len(geometry) < 2:
                raise SystemExit(f"{path}:{line_number}: degenerate geometry")
            bands = {}
            for band_token in fields[2].split("|"):
                label, _, rest = band_token.partition(":")
                minute = int(label)
                if minute in bands:
                    raise SystemExit(f"{path}:{line_number}: duplicate band")
                intervals = []
                for interval_token in rest.split(","):
                    match = _INTERVAL_RE.match(interval_token)
                    if not match:
                        raise SystemExit(
                            f"{path}:{line_number}: bad interval {interval_token!r}"
                        )
                    intervals.append((float(match.group(1)), float(match.group(2))))
                bands[minute] = intervals
                minutes.add(minute)
            if not bands:
                raise SystemExit(f"{path}:{line_number}: entry with no bands")
            entries.append((geometry, bands))
    return entries, sorted(minutes)


def build_expected(dumps):
    """Steps 0-3. dumps: ordered list of (key, entries, minutes). Returns
    {geometry_key: [(start, end, {requirement_key: minute})]}."""
    groups = {}
    for requirement_index, (_key, entries, _minutes) in enumerate(dumps):
        for geometry, bands in entries:
            forward = line_key(geometry)
            if line_key(geometry[::-1]) < forward:
                raise SystemExit("dump geometry is not in canonical orientation")
            group = groups.get(forward)
            if group is None:
                group = (geometry, [{} for _ in dumps])
                groups[forward] = group
            elif group[0] != geometry:
                raise SystemExit(
                    "dump entries with equal keys disagree on geometry"
                )
            requirement_bands = group[1][requirement_index]
            for minute, intervals in bands.items():
                requirement_bands.setdefault(minute, []).extend(intervals)

    expected = {}
    for geometry_key, (_geometry, per_requirement) in groups.items():
        merged = [
            {minute: merge_intervals(intervals) for minute, intervals in bands.items()}
            for bands in per_requirement
        ]
        endpoints = sorted(
            value
            for bands in merged
            for intervals in bands.values()
            for interval in intervals
            for value in interval
        )
        deduped = []
        for value in endpoints:
            if deduped and abs(value - deduped[-1]) <= 1e-12:
                continue
            deduped.append(value)

        pieces = []
        pending = None

        def flush():
            nonlocal pending
            if pending is not None:
                pieces.append(pending)
                pending = None

        for index in range(1, len(deduped)):
            start = deduped[index - 1]
            end = deduped[index]
            if end - start <= 1e-12:
                continue
            midpoint = (start + end) / 2.0
            attr = {}
            for (key, _entries, minutes), bands in zip(dumps, merged):
                found = False
                for minute in minutes:
                    present = any(
                        interval[0] <= midpoint <= interval[1]
                        for interval in bands.get(minute, ())
                    )
                    if present and not found:
                        found = True
                        attr[key] = minute
                    elif not present and found:
                        raise SystemExit(
                            "reachable edge intervals are not nested by minute"
                            " threshold"
                        )
            if not attr:
                flush()
                continue
            if (
                pending is not None
                and pending[2] == attr
                and abs(pending[1] - start) <= 1e-12
            ):
                pending = (pending[0], end, pending[2])
            else:
                flush()
                pending = (start, end, attr)
        flush()
        if pieces:
            expected[geometry_key] = pieces
    return expected


def parse_debug_segments(path):
    actual = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            raw = raw.rstrip("\n")
            if not raw:
                continue
            fields = raw.split("\t")
            if len(fields) != 4:
                raise SystemExit(f"{path}:{line_number}: expected 4 TSV fields")
            geometry_key, start, end, attributes = fields
            actual.setdefault(geometry_key, []).append(
                (float(start), float(end), json.loads(attributes))
            )
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug-segments", required=True)
    parser.add_argument("dumps", nargs="+")
    args = parser.parse_args()

    ordered = []
    for path in args.dumps:
        match = _DUMP_NAME_RE.match(os.path.basename(path))
        if not match:
            raise SystemExit(f"dump filename must be edges-<route_key>.tsv: {path}")
        key = f"{match.group(1)}_{match.group(2)}"
        entries, minutes = parse_dump(path)
        ordered.append((key, entries, minutes))
    if len({key for key, _entries, _minutes in ordered}) != len(ordered):
        raise SystemExit("duplicate requirement keys")
    ordered.sort(key=lambda item: item[0])

    expected = build_expected(ordered)
    actual = parse_debug_segments(args.debug_segments)

    failures = 0

    def report(message):
        nonlocal failures
        failures += 1
        if failures <= 20:
            print(f"MISMATCH: {message}", file=sys.stderr)

    for key in expected.keys() - actual.keys():
        report(f"geometry {key} expected but absent from debug table")
    for key in actual.keys() - expected.keys():
        report(f"geometry {key} in debug table but not expected")
    for key in expected.keys() & actual.keys():
        if expected[key] != actual[key]:
            report(
                f"geometry {key}: expected {expected[key]!r}"
                f" != actual {actual[key]!r}"
            )

    expected_pieces = sum(len(pieces) for pieces in expected.values())
    actual_pieces = sum(len(pieces) for pieces in actual.values())
    if failures:
        print(
            f"FAIL: {failures} mismatching geometries"
            f" ({expected_pieces} expected / {actual_pieces} actual pieces)",
            file=sys.stderr,
        )
        return 1
    print(
        f"OK: {len(expected)} geometries, {expected_pieces} pieces:"
        f" independent re-execution of steps 0-3 matches {args.debug_segments}"
        f" exactly"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
