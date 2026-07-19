#!/usr/bin/env python3
"""Encoder-grid skeleton of the unified access network for z6-12 tiles.

Implements docs/lowzoom-fastpath.md section 2.2 (normative), plus the
Variant-B short-chain filter of section 4.6. Input is the merge tool's
work/network.geojson (one Feature per attribute-map group, MultiLineString
of pieces, each carrying its group index `g` = feature index in file
order). Output is work/network-lowzoom.geojson: one LineString Feature per
chain, properties carried through verbatim, features ordered by
(g, tile, chain emission order).

Per group: quantize every vertex to the z10 MVT coordinate grid
(extent 4096, lon/latp projected degrees), deduplicate undirected grid
segments, split segments at z10 tile boundaries by recursive integer
midpoint bisection, chain the per-(group, tile) segment graph with a fully
deterministic two-phase walk, and drop exactly-collinear interior points
(integer cross/dot test, zero displacement).

The generated geometry stays on that fixed z10 grid when served at z11-13;
those zooms overzoom the skeleton rather than changing this algorithm's grid.

Single-threaded by design: determinism for free (section 2.2). Integer
arithmetic everywhere except the fixed latp/inv_latp formulas.

Variant B (--z67-out): a second artifact holding exactly the subset of
Variant-A chains whose z10-grid length L (sum of Euclidean segment lengths
in grid units over the post-collinear-drop points, accumulated in emission
order) satisfies L >= N_drop; order preserved, no re-ranking (section 4.6).
"""

import argparse
import json
import math
import sys
import time

GRID_ZOOM = 10
EXTENT = 4096
# One grid unit in (lon, latp) projected degrees — exactly the grid
# tilemaker's encoder rounds to at z10 (section 2.2).
UNIT = 360.0 / (EXTENT * (1 << GRID_ZOOM))


def latp(lat: float) -> float:
    return math.degrees(math.asinh(math.tan(math.radians(lat))))


def inv_latp(y: float) -> float:
    return math.degrees(math.atan(math.sinh(math.radians(y))))


def quantize(lon: float, lat: float) -> tuple[int, int]:
    return (round(lon / UNIT), round(latp(lat) / UNIT))


def tile_of(point: tuple[int, int]) -> tuple[int, int]:
    return (point[0] // EXTENT, point[1] // EXTENT)


def split_at_tile_boundaries(a, b, out):
    """Section 2.2 step 3: recursive integer midpoint bisection.

    Emits (tile, segment) pairs, segment endpoints ordered
    lexicographically smaller first. Terminal cases: both endpoints share
    a tile (assign that tile), or the midpoint equals an endpoint — a
    residual segment spanning two necessarily-adjacent tiles that cannot
    be split further, assigned whole to the lexicographically smaller of
    the two (tx, ty) tiles.
    """
    tile_a = tile_of(a)
    tile_b = tile_of(b)
    if tile_a == tile_b:
        out.append((tile_a, (a, b) if a < b else (b, a)))
        return
    m = ((a[0] + b[0]) // 2, (a[1] + b[1]) // 2)
    if m == a or m == b:
        out.append((min(tile_a, tile_b), (a, b) if a < b else (b, a)))
        return
    split_at_tile_boundaries(a, m, out)
    split_at_tile_boundaries(m, b, out)


def chain_tile_segments(segments):
    """Section 2.2 step 4: deterministic two-phase walk over the simple
    graph of one (group, tile)'s grid segments. Yields chains (lists of
    grid points). Phase one starts at nodes of odd degree in ascending
    (x, y) order, phase two at remaining nodes (cycles) in ascending
    order; each walk repeatedly moves to the smallest unconsumed neighbor
    until stuck, and emits one chain."""
    adjacency = {}
    for a, b in segments:
        adjacency.setdefault(a, set()).add(b)
        adjacency.setdefault(b, set()).add(a)
    for phase in (0, 1):
        if phase == 0:
            starts = sorted(
                node for node, peers in adjacency.items() if len(peers) % 2 == 1
            )
        else:
            starts = sorted(node for node, peers in adjacency.items() if peers)
        for start in starts:
            while adjacency[start]:
                chain = [start]
                node = start
                while adjacency[node]:
                    step = min(adjacency[node])
                    adjacency[node].discard(step)
                    adjacency[step].discard(node)
                    chain.append(step)
                    node = step
                yield chain


def drop_collinear(chain):
    """Section 2.2 step 5: remove interior points where the integer cross
    product of the adjacent segments is 0 and the dot product is positive
    (strictly straight-through). The test runs against the last kept
    point, so runs of collinear points collapse in one pass."""
    kept = [chain[0]]
    for index in range(1, len(chain) - 1):
        ax, ay = kept[-1]
        bx, by = chain[index]
        cx, cy = chain[index + 1]
        cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        dot = (bx - ax) * (cx - bx) + (by - ay) * (cy - by)
        if cross != 0 or dot <= 0:
            kept.append(chain[index])
    kept.append(chain[-1])
    return kept


def dequantize(point: tuple[int, int]) -> str:
    # 1e-7-rounded like all pipeline geometry; repr() of the rounded value
    # is the shortest round-tripping decimal (at most 7 fractional digits).
    lon = round(point[0] * UNIT, 7)
    lat = round(inv_latp(point[1] * UNIT), 7)
    return f"[{lon!r},{lat!r}]"


def feature_json(properties_json: str, chain) -> str:
    coordinates = ",".join(dequantize(point) for point in chain)
    return (
        '{"type":"Feature","properties":' + properties_json
        + ',"geometry":{"type":"LineString","coordinates":[' + coordinates + "]}}"
    )


def grid_length(chain) -> float:
    """Section 4.6: z10-grid length L — the sum of Euclidean segment
    lengths in grid units, accumulated in emission order over the chain's
    post-collinear-drop points."""
    total = 0.0
    for (ax, ay), (bx, by) in zip(chain, chain[1:]):
        total += math.sqrt((bx - ax) ** 2 + (by - ay) ** 2)
    return total


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("network", help="input work/network.geojson")
    parser.add_argument("output", help="output work/network-lowzoom.geojson")
    parser.add_argument(
        "--z67-out",
        help="also write the Variant-B z6-7 artifact (section 4.6): the "
        "subset of chains with grid length L >= N_drop, order preserved",
    )
    parser.add_argument(
        "--n-drop",
        type=float,
        default=64.0,
        help="Variant-B drop threshold in z10 grid units (default 64)",
    )
    args = parser.parse_args()

    started = time.perf_counter()
    with open(args.network, encoding="utf-8") as handle:
        collection = json.load(handle)
    features = collection["features"]

    # The merge tool is the single source of truth for `g` (= feature index
    # in emission order); assert the values are exactly 0..N-1 in file
    # order and never assign our own (section 2.2).
    for index, feature in enumerate(features):
        g = feature["properties"].get("g")
        if g != index:
            raise SystemExit(
                f"coarsen: feature {index} carries g={g!r}; expected the "
                "merge tool's file-order index — rebuild network.geojson "
                "with the g-emitting merge tool"
            )

    input_property_maps = set()
    emitted_property_maps = set()
    in_pieces = in_points = 0
    total_segments = total_chains = total_points = 0
    kept_chains = 0
    dropped_chains = 0
    kept_length = 0.0
    dropped_length = 0.0

    out_main = open(args.output, "w", encoding="utf-8")
    out_z67 = open(args.z67_out, "w", encoding="utf-8") if args.z67_out else None
    for handle in filter(None, (out_main, out_z67)):
        handle.write('{"type":"FeatureCollection","features":[')
    first_main = first_z67 = True

    for feature in features:
        properties = feature["properties"]
        properties_json = json.dumps(
            properties, ensure_ascii=False, separators=(",", ":")
        )
        input_property_maps.add(properties_json)
        geometry = feature["geometry"]
        pieces = (
            geometry["coordinates"]
            if geometry["type"] == "MultiLineString"
            else [geometry["coordinates"]]
        )
        in_pieces += len(pieces)

        # Steps 1-3: quantize (collapsing consecutive identical grid
        # points), decompose into undirected segments deduplicated in a
        # per-group set, split at z10 tile boundaries. Splitting is a
        # deterministic function of the segment, so deduplicating before
        # splitting equals the spec's step order; the per-tile sets give
        # step 4 its simple graph (sub-segments of distinct input segments
        # may coincide inside one tile).
        group_segments = set()
        for piece in pieces:
            in_points += len(piece)
            previous = quantize(*piece[0])
            for lon, lat in piece[1:]:
                current = quantize(lon, lat)
                if current == previous:
                    continue
                group_segments.add(
                    (previous, current) if previous < current else (current, previous)
                )
                previous = current
        by_tile = {}
        for a, b in group_segments:
            split = []
            split_at_tile_boundaries(a, b, split)
            for tile, segment in split:
                by_tile.setdefault(tile, set()).add(segment)
        total_segments += sum(len(segments) for segments in by_tile.values())

        # Section 2.4 asks for emitted-property-maps == read-property-maps;
        # measured 4-band data breaks the literal assert: groups whose whole
        # geometry is shorter than half a grid unit (~2.7 m at z10) quantize
        # to a single point and cannot emit a segment (lt-full 2026-07-18:
        # 2 of 198 groups, one ~1.8 m piece each — sub-pixel by ~40x at
        # z10). Tightened instead of dropped: a group may vanish only if it
        # derived zero grid segments; a vanished group WITH segments is
        # still a hard failure (that is the bug class the assert exists
        # for). Logged loudly either way.
        if not group_segments:
            print(
                "[coarsen] group emitted no chains (all pieces quantize to "
                f"single grid points): {properties_json}",
                file=sys.stderr,
            )
            input_property_maps.discard(properties_json)
            continue

        # Steps 4-6: chain per (group, tile) in ascending tile order, drop
        # collinear interior points, emit one LineString Feature per chain
        # — features ordered by (g, tile, chain emission order).
        emitted_any = False
        for tile in sorted(by_tile):
            for chain in chain_tile_segments(by_tile[tile]):
                chain = drop_collinear(chain)
                total_chains += 1
                total_points += len(chain)
                emitted_any = True
                serialized = feature_json(properties_json, chain)
                if not first_main:
                    out_main.write(",")
                first_main = False
                out_main.write(serialized)
                if out_z67 is not None:
                    length = grid_length(chain)
                    if length >= args.n_drop:
                        kept_chains += 1
                        kept_length += length
                        if not first_z67:
                            out_z67.write(",")
                        first_z67 = False
                        out_z67.write(serialized)
                    else:
                        dropped_chains += 1
                        dropped_length += length
        if emitted_any:
            emitted_property_maps.add(properties_json)

    for handle in filter(None, (out_main, out_z67)):
        handle.write("]}\n")
        handle.close()

    # Attribute-model preservation assert (section 2.4): the set of
    # distinct property maps emitted equals the set read.
    if emitted_property_maps != input_property_maps:
        missing = sorted(input_property_maps - emitted_property_maps)
        raise SystemExit(
            f"coarsen: {len(missing)} attribute group(s) emitted no chains: "
            + "; ".join(missing[:5])
        )

    elapsed = time.perf_counter() - started
    print(
        f"[coarsen] {len(features)} groups, {in_pieces} pieces / {in_points} "
        f"points -> {total_segments} grid segments, {total_chains} chains / "
        f"{total_points} points "
        f"(avg {total_points / max(total_chains, 1):.1f} points/chain) "
        f"in {elapsed:.1f}s",
        file=sys.stderr,
    )
    if out_z67 is not None:
        total = kept_chains + dropped_chains
        total_len = kept_length + dropped_length
        print(
            f"[coarsen] variant B (N_drop={args.n_drop:g}): dropped "
            f"{dropped_chains} of {total} chains "
            f"({100 * dropped_chains / max(total, 1):.1f}%), "
            f"{dropped_length:.0f} of {total_len:.0f} grid-units length "
            f"({100 * dropped_length / max(total_len, 1e-9):.1f}%)",
            file=sys.stderr,
        )


if __name__ == "__main__":
    sys.setrecursionlimit(10000)
    main()
