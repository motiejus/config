#!/usr/bin/env python3
"""Independent gate checker for the algorithm in docs/lowzoom-fastpath.md.

Deliberately separate code: this file re-derives everything it verifies
from the documented complete/filtered skeleton contract and shares no functions with
coarsen.py. Checks, per attribute-map group:

(i)   the multiset of undirected grid segments covered by the output
      chains equals, exactly, the set obtained by independently
      quantizing + deduplicating + boundary-splitting the input.
      Implementation: an exact consumption replay — the output chains are
      walked in file order against the independently derived per-(group,
      tile) segment sets; every step must consume exactly one unconsumed
      segment, interior points dropped by the collinear rule are
      re-expanded (each hidden step must be the smallest unconsumed
      neighbor and exactly collinear, strictly forward), and every
      segment set must be empty when the group's chains are exhausted.
      Lost, invented, or duplicated segments all fail loudly.
(ii)  output attribute maps equal input attribute maps, including `g`,
      carried through verbatim.
(iii) input `g` values are exactly 0..N-1 in file order.
(iv)  with --z67 and --n-drop: the filtered artifact is exactly the
      subset of complete-skeleton chains with grid length L >= N_drop, order
      preserved.

Usage:
  check-lowzoom-coarsen.py NETWORK LOWZOOM [--z67 Z67 --n-drop N]
"""

import argparse
import json
import math
import sys

Z = 10
TILE_EXTENT = 4096
GRID_UNIT = 360.0 / (TILE_EXTENT * 2**Z)


def to_latp(lat_degrees: float) -> float:
    return math.degrees(math.asinh(math.tan(math.radians(lat_degrees))))


def from_latp(latp_degrees: float) -> float:
    return math.degrees(math.atan(math.sinh(math.radians(latp_degrees))))


def grid_point(lon: float, lat: float) -> tuple[int, int]:
    return (round(lon / GRID_UNIT), round(to_latp(lat) / GRID_UNIT))


def containing_tile(point: tuple[int, int]) -> tuple[int, int]:
    return (point[0] // TILE_EXTENT, point[1] // TILE_EXTENT)


def normalized(a: tuple[int, int], b: tuple[int, int]):
    return (a, b) if a < b else (b, a)


def boundary_split(a, b, collect):
    """Independent midpoint bisection; unsplittable
    adjacent-tile residuals go whole to the lexicographically smaller
    tile."""
    stack = [(a, b)]
    while stack:
        p, q = stack.pop()
        tile_p = containing_tile(p)
        tile_q = containing_tile(q)
        if tile_p == tile_q:
            collect.append((tile_p, normalized(p, q)))
            continue
        mid = ((p[0] + q[0]) // 2, (p[1] + q[1]) // 2)
        if mid == p or mid == q:
            collect.append((min(tile_p, tile_q), normalized(p, q)))
            continue
        stack.append((mid, q))
        stack.append((p, mid))


def derive_group_segments(geometry) -> dict:
    """Independently quantize + dedup + boundary-split one input feature.
    Returns {tile: {segment, ...}}."""
    lines = (
        geometry["coordinates"]
        if geometry["type"] == "MultiLineString"
        else [geometry["coordinates"]]
    )
    deduped = set()
    for line in lines:
        previous = grid_point(*line[0])
        for lon, lat in line[1:]:
            current = grid_point(lon, lat)
            if current != previous:
                deduped.add(normalized(previous, current))
                previous = current
    per_tile = {}
    for a, b in deduped:
        parts = []
        boundary_split(a, b, parts)
        for tile, segment in parts:
            per_tile.setdefault(tile, set()).add(segment)
    return per_tile


def fail(message: str):
    raise SystemExit(f"check-lowzoom-coarsen: FAIL: {message}")


def requantize_chain(feature, feature_index):
    """Map an output LineString back to grid integers, verifying each
    written coordinate sits within printing precision (1e-7) of the
    dequantized grid point."""
    geometry = feature["geometry"]
    if geometry["type"] != "LineString":
        fail(f"output feature {feature_index}: geometry {geometry['type']}")
    coords = geometry["coordinates"]
    if len(coords) < 2:
        fail(f"output feature {feature_index}: {len(coords)}-point chain")
    points = []
    for lon, lat in coords:
        gx, gy = grid_point(lon, lat)
        if abs(lon - gx * GRID_UNIT) > 1.001e-7 or abs(
            lat - from_latp(gy * GRID_UNIT)
        ) > 1.001e-7:
            fail(
                f"output feature {feature_index}: coordinate ({lon},{lat}) "
                "is not a 1e-7-printed z10 grid point"
            )
        points.append((gx, gy))
    for previous, current in zip(points, points[1:]):
        if previous == current:
            fail(f"output feature {feature_index}: repeated grid point")
    return points


def replay_chain(points, adjacency, feature_index):
    """Consume the chain's covered segments from the tile graph. Hidden
    (collinear-dropped) interior nodes are re-expanded: each must be the
    smallest unconsumed neighbor of its predecessor and pass the exact
    integer collinear/forward test against the last kept point."""
    anchor = points[0]
    cursor = points[0]
    kept_index = 1
    target = points[kept_index]
    while True:
        peers = adjacency.get(cursor)
        if not peers:
            fail(
                f"output feature {feature_index}: no unconsumed segment at "
                f"{cursor} while heading for {target}"
            )
        step = min(peers)
        peers.discard(step)
        adjacency[step].discard(cursor)
        if cursor != anchor:
            ax, ay = anchor
            bx, by = cursor
            cx, cy = step
            cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            dot = (bx - ax) * (cx - bx) + (by - ay) * (cy - by)
            if cross != 0 or dot <= 0:
                fail(
                    f"output feature {feature_index}: dropped interior point "
                    f"{cursor} is not exactly-collinear straight-through "
                    f"between {anchor} and {step}"
                )
        cursor = step
        if cursor == target:
            anchor = cursor
            kept_index += 1
            if kept_index == len(points):
                break
            target = points[kept_index]
    if adjacency.get(cursor):
        fail(
            f"output feature {feature_index}: chain ends at {cursor} with "
            f"unconsumed segments {sorted(adjacency[cursor])[:3]} remaining"
        )


def check_variant_b(lowzoom_features, z67_path, n_drop):
    with open(z67_path, encoding="utf-8") as handle:
        z67 = json.load(handle)
    expected = []
    for index, feature in enumerate(lowzoom_features):
        points = [grid_point(*c) for c in feature["geometry"]["coordinates"]]
        length = sum(
            math.sqrt((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2)
            for a, b in zip(points, points[1:])
        )
        if length >= n_drop:
            expected.append(index)
    actual = z67["features"]
    if len(actual) != len(expected):
        fail(
            f"variant B: {len(actual)} features, expected {len(expected)} "
            f"(subset of A with L >= {n_drop})"
        )
    for position, index in enumerate(expected):
        a_feature = lowzoom_features[index]
        b_feature = actual[position]
        if (
            a_feature["properties"] != b_feature["properties"]
            or a_feature["geometry"] != b_feature["geometry"]
        ):
            fail(
                f"filtered output: feature {position} differs from complete-skeleton "
                f"feature {index} (order or content not preserved)"
            )
    print(
        f"[check] (iv) variant B: exact subset of A, {len(actual)} of "
        f"{len(lowzoom_features)} chains kept at N_drop={n_drop:g}, "
        "order preserved"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("network")
    parser.add_argument("lowzoom")
    parser.add_argument("--z67")
    parser.add_argument("--n-drop", type=float, default=64.0)
    args = parser.parse_args()

    with open(args.network, encoding="utf-8") as handle:
        network = json.load(handle)
    network_features = network["features"]

    # (iii) input g values are exactly 0..N-1 in file order.
    for index, feature in enumerate(network_features):
        if feature["properties"].get("g") != index:
            fail(
                f"input feature {index} has g="
                f"{feature['properties'].get('g')!r}, expected {index}"
            )
    print(f"[check] (iii) input g values are exactly 0..{len(network_features) - 1}")

    with open(args.lowzoom, encoding="utf-8") as handle:
        lowzoom = json.load(handle)
    lowzoom_features = lowzoom["features"]

    # (ii) properties carried through verbatim, keyed by g.
    for index, feature in enumerate(lowzoom_features):
        g = feature["properties"].get("g")
        if not isinstance(g, int) or not 0 <= g < len(network_features):
            fail(f"output feature {index}: bad group id {g!r}")
        if feature["properties"] != network_features[g]["properties"]:
            fail(
                f"output feature {index}: properties differ from input "
                f"group {g}"
            )
    # A group may be absent only if its whole geometry quantizes to single
    # grid points (zero derivable segments) — verified independently in the
    # replay below, where such a group must also own zero output chains.
    groups_seen = {feature["properties"]["g"] for feature in lowzoom_features}
    print(
        f"[check] (ii) properties verbatim for {len(lowzoom_features)} chains "
        f"across {len(groups_seen)} of {len(network_features)} groups"
    )

    # (i) exact segment-coverage replay, group by group in file order.
    ordered = [(f["properties"]["g"], i) for i, f in enumerate(lowzoom_features)]
    if ordered != sorted(ordered):
        fail("output features are not ordered by group id")
    position = 0
    total_segments = 0
    segmentless = 0
    for g, feature in enumerate(network_features):
        per_tile = derive_group_segments(feature["geometry"])
        if not per_tile:
            if g in groups_seen:
                fail(f"group {g}: chains emitted for a zero-segment group")
            segmentless += 1
        elif g not in groups_seen:
            fail(
                f"group {g}: derived {sum(len(s) for s in per_tile.values())} "
                "segments but the output has no chains for it"
            )
        total_segments += sum(len(s) for s in per_tile.values())
        for tile in sorted(per_tile):
            adjacency = {}
            for a, b in per_tile[tile]:
                adjacency.setdefault(a, set()).add(b)
                adjacency.setdefault(b, set()).add(a)
            remaining = len(per_tile[tile])
            while remaining:
                if (
                    position >= len(lowzoom_features)
                    or lowzoom_features[position]["properties"]["g"] != g
                ):
                    fail(
                        f"group {g} tile {tile}: {remaining} segments never "
                        "covered by any chain"
                    )
                points = requantize_chain(lowzoom_features[position], position)
                before = sum(len(peers) for peers in adjacency.values())
                replay_chain(points, adjacency, position)
                after = sum(len(peers) for peers in adjacency.values())
                remaining -= (before - after) // 2
                position += 1
        if position < len(lowzoom_features) and (
            lowzoom_features[position]["properties"]["g"] == g
        ):
            fail(f"group {g}: extra chains beyond the derived segment set")
    if position != len(lowzoom_features):
        fail(f"{len(lowzoom_features) - position} trailing unmatched chains")
    print(
        f"[check] (i) segment coverage exact: {total_segments} derived grid "
        f"segments == segments covered by {len(lowzoom_features)} chains"
        + (f" ({segmentless} zero-segment group(s) legitimately absent)"
           if segmentless else "")
    )

    if args.z67:
        check_variant_b(lowzoom_features, args.z67, args.n_drop)
    print("[check] OK")


if __name__ == "__main__":
    main()
