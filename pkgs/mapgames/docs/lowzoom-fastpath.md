# Access network low-zoom path: current implementation

This note records the algorithm that currently feeds `access.pmtiles`.
Published archive details are in [`format.md`](format.md). The former document
mixed old measurements, rejected variants, and already-completed phases; those
are intentionally not retained as serving documentation.

## Zoom handoff

All three representations write to the same MVT layer, `network`, and preserve
the same attribute-map group `g`:

| Native zoom | Geometry |
|---:|---|
| z6–7 | z10-grid skeleton after deterministic short-chain filtering |
| z8–13 | unfiltered z10-grid skeleton (encoder-simplified through z10) |
| z14 | raw merged routing-edge geometry |

MapLibre overzooms z14 above the archive maximum. The fixed skeleton grid zoom
and the serving handoff are intentionally independent constants.

## Skeleton algorithm

`coarsen.py` processes each attribute group independently:

1. project and round every input vertex to the z10 MVT coordinate grid;
2. collapse consecutive equal points and deduplicate undirected segments;
3. split segments at z10 tile boundaries by deterministic integer midpoint
   bisection;
4. chain segments within each `(g, tile)` graph using sorted starts and
   neighbors;
5. remove exactly collinear interior points;
6. emit stable ordered LineStrings carrying the original properties and `g`;
7. derive the z6–7 subset by retaining chains at least 64 grid units long.

Tilemaker applies Visvalingam simplification at one MVT coordinate unit for
z6–10. The z11–13 tiles use the same z10-grid source without additional
simplification. Raw z14 geometry is not simplified by this path.

The intermediate files `network.geojson`, `network-lowzoom.geojson`, and
`network-lowzoom-z67.geojson` never enter the published derivation output.

## Required invariants

- Input group IDs are exactly `0..N-1` in feature order.
- Every emitted feature retains its original group ID and attribute map.
- Deduplication occurs only inside one attribute group.
- Output does not depend on Python hash iteration order.
- Boundary splitting and chain walking have explicit stable tie-breaks.
- From the complete skeleton, a group may disappear only if all of its geometry
  quantizes below one grid point. The intentionally filtered z6–7 subset may
  also omit a group when all of its chains are shorter than 64 grid units;
  metadata retains the full group table in either case.

`check-lowzoom-coarsen.py` independently exercises quantization, filtering,
ordering, group preservation, and repeatability. It and the edge-dump and
unified-network segment checkers are explicit development tools, not automatic
steps of the ordinary `default.nix` build.

## Why this exists

Raw routing output is dominated by tiny, often coincident edge fragments. At
country and regional zoom those fragments cost network bytes and mobile GPU/CPU
time without exposing extra visible information. The shared z10 grid merges
that confetti while retaining the exact accessibility attribute model. Feature
state then makes every service/view switch a paint update over the already
loaded tiles rather than a filter-driven rebucket.
