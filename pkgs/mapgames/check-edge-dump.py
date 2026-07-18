#!/usr/bin/env python3
"""Independent checker for the edge-interval dump (unified-access-layer).

Re-derives legacy-format coverage GeoJSON from edges-<route_key>.tsv alone —
running the single-service degenerate case of the docs/unified-access-layer.md
section 1.3 segmentation, including the mandatory step-0 geometry-string
pre-merge of dual-digitized edges — enforcing the dump invariants on the way
(canonical geometry orientation, dual-digitization geometry consistency, band
nesting). This is deliberately independent code: it shares no functions with
valhalla-expand.cc, only its normative constants (1e-12 tolerances, 1e-7
rounding, 0.01 m minimum length) and output format.

The pipeline stopped writing coverage-<route_key>.geojson at step 7 of the
design doc's phasing, so there is no in-tree reference to byte-compare by
default; the derivation itself is the check. Because the derived bytes are
pure geometry (no uint64 edge ids, which are stable only within one graph
build), --write-derived output from two different graph builds of the same
extract is directly comparable — use it to diff dump content across rebuilds.

usage: check-edge-dump.py --dump edges-coffee-walk.tsv \
           --bounds 24.95,54.52,25.55,54.92 --minutes 5,10,20 \
           --service coffee --mode walk \
           [--coverage reference.geojson] [--write-derived derived.geojson]

Exits 0 and prints a verdict when the derivation succeeds (and, with
--coverage, the re-derived bytes equal the reference); exits 1 otherwise.
"""

import argparse
import math
import re
import sys

EARTH_RADIUS_METERS = 6371008.8
RADIANS_PER_DEGREE = 3.14159265358979323846 / 180.0

_NUMBER = r"[0-9.]+(?:[eE][-+]?[0-9]+)?"
# Fractions are non-negative, so within one "<start>-<end>" token a '-' is
# either the separator or part of an exponent ("1e-05"); the regex resolves
# the ambiguity.
_INTERVAL_RE = re.compile(rf"^({_NUMBER})-({_NUMBER})$")


def llround(value):
    """C++ std::llround: round half away from zero. Inputs here are always
    within 2**52, where adding/subtracting 0.5 is exact, so floor/ceil of the
    sum reproduces llround bit-for-bit."""
    if value >= 0:
        return int(math.floor(value + 0.5))
    return int(math.ceil(value - 0.5))


def clamp(value, low, high):
    if value < low:
        return low
    if high < value:
        return high
    return value


def same_point(left, right):
    return abs(left[0] - right[0]) < 1e-12 and abs(left[1] - right[1]) < 1e-12


def point_key(point):
    return "%d,%d" % (llround(point[0] * 10000000), llround(point[1] * 10000000))


def line_key(line):
    return "".join(point_key(point) + ";" for point in line)


def rounded_line(line):
    normalized = []
    for lon, lat in line:
        rounded = (
            llround(lon * 10000000) / 10000000.0,
            llround(lat * 10000000) / 10000000.0,
        )
        if not normalized or not same_point(normalized[-1], rounded):
            normalized.append(rounded)
    if len(normalized) < 2:
        return []
    return normalized


def canonical_line(line):
    """Returns (key, canonical-orientation line) or None for degenerate."""
    normalized = rounded_line(line)
    if not normalized:
        return None
    forward = line_key(normalized)
    backward = line_key(normalized[::-1])
    if backward < forward:
        return backward, normalized[::-1]
    return forward, normalized


def segment_length(first, second):
    first_lat = first[1] * RADIANS_PER_DEGREE
    second_lat = second[1] * RADIANS_PER_DEGREE
    delta_lat = (second[1] - first[1]) * RADIANS_PER_DEGREE
    delta_lon = (second[0] - first[0]) * RADIANS_PER_DEGREE
    sin_lat = math.sin(delta_lat / 2.0)
    sin_lon = math.sin(delta_lon / 2.0)
    haversine = (
        sin_lat * sin_lat
        + math.cos(first_lat) * math.cos(second_lat) * sin_lon * sin_lon
    )
    return (
        2.0
        * EARTH_RADIUS_METERS
        * math.asin(min(1.0, math.sqrt(haversine)))
    )


def measure_line(line):
    cumulative = [0.0]
    total = 0.0
    for index in range(1, len(line)):
        total += segment_length(line[index - 1], line[index])
        cumulative.append(total)
    return cumulative, total


def interpolate(first, second, fraction):
    return (
        first[0] + (second[0] - first[0]) * fraction,
        first[1] + (second[1] - first[1]) * fraction,
    )


def slice_line(line, cumulative, total, start_fraction, end_fraction):
    start_fraction = clamp(start_fraction, 0.0, 1.0)
    end_fraction = clamp(end_fraction, start_fraction, 1.0)
    if total <= 0.01 or end_fraction - start_fraction <= 1e-12:
        return []
    start_distance = start_fraction * total
    end_distance = end_fraction * total
    result = []
    for index in range(1, len(line)):
        first = line[index - 1]
        second = line[index]
        segment_start = cumulative[index - 1]
        segment_end = cumulative[index]
        length = segment_end - segment_start
        if length <= 0 or segment_end <= start_distance or segment_start >= end_distance:
            continue
        overlap_start = max(start_distance, segment_start)
        overlap_end = min(end_distance, segment_end)
        clipped_first = interpolate(first, second, (overlap_start - segment_start) / length)
        clipped_second = interpolate(first, second, (overlap_end - segment_start) / length)
        if not result:
            result.append(clipped_first)
        elif not same_point(result[-1], clipped_first):
            result.append(clipped_first)
        if not same_point(result[-1], clipped_second):
            result.append(clipped_second)
    if len(result) < 2:
        return []
    return result


def clip_test(p, q, span):
    if p == 0:
        return q >= 0
    ratio = q / p
    if p < 0:
        if ratio > span[1]:
            return False
        span[0] = max(span[0], ratio)
    else:
        if ratio < span[0]:
            return False
        span[1] = min(span[1], ratio)
    return True


def clip_segment(first, second, bounds):
    min_lon, min_lat, max_lon, max_lat = bounds
    delta_lon = second[0] - first[0]
    delta_lat = second[1] - first[1]
    span = [0.0, 1.0]
    if not (
        clip_test(-delta_lon, first[0] - min_lon, span)
        and clip_test(delta_lon, max_lon - first[0], span)
        and clip_test(-delta_lat, first[1] - min_lat, span)
        and clip_test(delta_lat, max_lat - first[1], span)
    ):
        return None
    clipped_first = (first[0] + span[0] * delta_lon, first[1] + span[0] * delta_lat)
    clipped_second = (first[0] + span[1] * delta_lon, first[1] + span[1] * delta_lat)
    if same_point(clipped_first, clipped_second):
        return None
    return clipped_first, clipped_second


def clip_line(line, bounds):
    result = []
    current = []
    for index in range(1, len(line)):
        clipped = clip_segment(line[index - 1], line[index], bounds)
        if clipped is None:
            if len(current) >= 2:
                result.append(current)
            current = []
            continue
        first, second = clipped
        if not current:
            current = [first, second]
        elif same_point(current[-1], first):
            if not same_point(current[-1], second):
                current.append(second)
        else:
            if len(current) >= 2:
                result.append(current)
            current = [first, second]
    if len(current) >= 2:
        result.append(current)
    return result


def merge_intervals(intervals):
    merged = []
    for start, end in sorted(intervals):
        if end - start <= 1e-12:
            continue
        if not merged or start > merged[-1][1] + 1e-12:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return [(start, end) for start, end in merged]


def unique_endpoints(values):
    values = sorted(values)
    kept = []
    for value in values:
        if kept and abs(value - kept[-1]) <= 1e-12:
            continue
        kept.append(value)
    return kept


def parse_dump(path, minutes):
    """Returns a list of (line, bands) dump entries; bands is a list of
    interval lists indexed like `minutes`."""
    entries = []
    minute_index = {minute: index for index, minute in enumerate(minutes)}
    with open(path, "r", encoding="ascii") as handle:
        for line_number, raw in enumerate(handle, 1):
            raw = raw.rstrip("\n")
            if not raw:
                continue
            fields = raw.split("\t")
            if len(fields) != 3:
                raise SystemExit(f"{path}:{line_number}: expected 3 TSV fields")
            geometry = []
            for token in fields[1].split(";"):
                lon, lat = token.split(",")
                geometry.append((float(lon), float(lat)))
            if len(geometry) < 2:
                raise SystemExit(f"{path}:{line_number}: degenerate geometry")
            bands = [[] for _ in minutes]
            for band_token in fields[2].split("|"):
                label, _, rest = band_token.partition(":")
                minute = int(label)
                if minute not in minute_index:
                    raise SystemExit(
                        f"{path}:{line_number}: unexpected band minute {minute}"
                    )
                if bands[minute_index[minute]]:
                    raise SystemExit(
                        f"{path}:{line_number}: duplicate band {minute}"
                    )
                intervals = []
                for interval_token in rest.split(","):
                    match = _INTERVAL_RE.match(interval_token)
                    if not match:
                        raise SystemExit(
                            f"{path}:{line_number}: bad interval {interval_token!r}"
                        )
                    intervals.append((float(match.group(1)), float(match.group(2))))
                if not intervals:
                    raise SystemExit(f"{path}:{line_number}: empty band {minute}")
                bands[minute_index[minute]] = intervals
            if not any(bands):
                raise SystemExit(f"{path}:{line_number}: entry with no intervals")
            entries.append((geometry, bands))
    return entries


def premerge_by_geometry(entries, minutes):
    """Section 1.3 step 0: group dump entries by canonical geometry string,
    concatenate per-band interval lists, re-merge per band."""
    groups = {}
    for geometry, bands in entries:
        forward = line_key(geometry)
        if line_key(geometry[::-1]) < forward:
            raise SystemExit("dump geometry is not in canonical orientation")
        group = groups.get(forward)
        if group is None:
            group = (geometry, [[] for _ in minutes])
            groups[forward] = group
        elif group[0] != geometry:
            raise SystemExit("dump entries with equal keys disagree on geometry")
        for index, band in enumerate(bands):
            group[1][index].extend(band)
    return {
        key: (geometry, [merge_intervals(band) for band in bands])
        for key, (geometry, bands) in groups.items()
    }


def derive_coverage(groups, minutes, bounds):
    """Sections 1.3 steps 1-3 degenerate to one service (the semantics of the
    retired coverage_lines() writer): classify by first containing band,
    coalesce runs, slice against one shared measure, clip, canonicalize,
    min/max on collision."""
    result = {}

    def add_segment(line, cumulative, total, start, end, min_minutes, max_minutes):
        segment = slice_line(line, cumulative, total, start, end)
        for clipped in clip_line(segment, bounds):
            canonical = canonical_line(clipped)
            if canonical is None:
                continue
            key, canonical_points = canonical
            existing = result.get(key)
            if existing is None:
                result[key] = [canonical_points, min_minutes, max_minutes]
            else:
                existing[1] = min(existing[1], min_minutes)
                existing[2] = max(existing[2], max_minutes)

    for _key, (line, bands) in groups.items():
        cumulative, total = measure_line(line)
        endpoints = unique_endpoints(
            [value for band in bands for interval in band for value in interval]
        )
        pending_minute = None
        pending_start = 0.0
        pending_end = 0.0

        def flush():
            nonlocal pending_minute
            if pending_minute is not None:
                add_segment(
                    line,
                    cumulative,
                    total,
                    pending_start,
                    pending_end,
                    minutes[pending_minute],
                    minutes[-1],
                )
                pending_minute = None

        for index in range(1, len(endpoints)):
            start = endpoints[index - 1]
            end = endpoints[index]
            if end - start <= 1e-12:
                continue
            midpoint = (start + end) / 2.0
            first_minute = None
            for band_index, band in enumerate(bands):
                present = any(
                    interval[0] <= midpoint <= interval[1] for interval in band
                )
                if present and first_minute is None:
                    first_minute = band_index
                elif not present and first_minute is not None:
                    raise SystemExit(
                        "reachable edge intervals are not nested by minute threshold"
                    )
            if (
                first_minute == pending_minute
                and pending_minute is not None
                and abs(pending_end - start) <= 1e-12
            ):
                pending_end = end
            else:
                flush()
                if first_minute is not None:
                    pending_minute = first_minute
                    pending_start = start
                    pending_end = end
        flush()
    return result


def format_number(value):
    """C++ ostream << std::setprecision(15) default-float formatting."""
    return "%.15g" % value


def write_coverage(result, bounds, service, mode):
    groups = {}
    for key, (line, min_minutes, max_minutes) in result.items():
        groups.setdefault((min_minutes, max_minutes), {})[key] = line
    parts = []
    bbox = ",".join(format_number(value) for value in bounds)
    parts.append('{"type":"FeatureCollection","bbox":[%s],"features":[' % bbox)
    first_feature = True
    for (min_minutes, max_minutes), lines in sorted(groups.items()):
        if not first_feature:
            parts.append(",")
        first_feature = False
        parts.append(
            '{"type":"Feature","properties":{'
            '"direction":"to_destination","min_minutes":%d,"max_minutes":%d,'
            '"mode":"%s","service":"%s"},"geometry":'
            '{"type":"MultiLineString","coordinates":['
            % (min_minutes, max_minutes, mode, service)
        )
        first_line = True
        for key in sorted(lines):
            if not first_line:
                parts.append(",")
            first_line = False
            parts.append(
                "["
                + ",".join(
                    "[%s,%s]" % (format_number(lon), format_number(lat))
                    for lon, lat in lines[key]
                )
                + "]"
            )
        parts.append("]}}")
    parts.append("]}\n")
    return "".join(parts).encode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", required=True)
    parser.add_argument("--coverage")
    parser.add_argument("--write-derived")
    parser.add_argument("--bounds", required=True)
    parser.add_argument("--minutes", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--mode", required=True)
    args = parser.parse_args()

    bounds = tuple(float(field) for field in args.bounds.split(","))
    if len(bounds) != 4:
        raise SystemExit("bounds must contain four comma-separated numbers")
    minutes = [int(field) for field in args.minutes.split(",")]
    if minutes != sorted(set(minutes)) or not minutes or min(minutes) <= 0:
        raise SystemExit("minutes must be positive, sorted, and unique")

    entries = parse_dump(args.dump, minutes)
    groups = premerge_by_geometry(entries, minutes)
    coverage = derive_coverage(groups, minutes, bounds)
    if not coverage:
        raise SystemExit(f"{args.dump}: derived coverage is empty")
    derived = write_coverage(coverage, bounds, args.service, args.mode)
    if args.write_derived:
        with open(args.write_derived, "wb") as handle:
            handle.write(derived)
    summary = (
        f"{args.dump}: {len(entries)} dump entries -> "
        f"{len(groups)} merged geometries -> {len(coverage)} pieces "
        f"({len(derived)} derived bytes)"
    )
    if args.coverage is None:
        print(f"OK: {summary}; dump invariants hold")
        return 0
    with open(args.coverage, "rb") as handle:
        reference = handle.read()
    if derived == reference:
        print(f"OK: {summary}; byte-identical to {args.coverage}")
        return 0
    print(
        f"MISMATCH: re-derived coverage ({len(derived)} bytes) differs from "
        f"{args.coverage} ({len(reference)} bytes)",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
