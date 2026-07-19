# Low-zoom performance fast-path for the unified access network

Design and measurement record for the implemented low-zoom fast path. Companion to
`pkgs/mapgames/docs/unified-access-layer.md` (referenced below as "the T3
doc"); terminology (piece, requirement, attribute map, band) is inherited from
it. Repo state: config @ 90e2a388055b. All measurements in this document were
taken on the full-Lithuania build of 2026-07-18 (`access.pmtiles`
819,093,360 bytes, `work/network.geojson` 125,167,696 bytes, hospital-60
included), with tilemaker 3.1.0 (the pinned
`/nix/store/2va1lfrypkky840yl7r9ja2rfggfpmyp-tilemaker-3.1.0`) and the
committed `generate.py` tile config. Measurement scripts (PMTiles v3 + MVT
decoder, per-zoom stats, per-combo stats, occupancy raster diff, coarsening
prototypes) live in `scratchpad/lowzoom-exp/`; every algorithm they implement
is specified normatively here, so an implementer does not need them.

**Current serving handoff (2026-07-19):** the measured design below landed,
then mobile frame profiling found raw access geometry to be the dominant
z11–13 pan cost. The current config therefore serves the same fixed z10-grid
skeleton through z13 and starts raw geometry at z14. `COARSE_GRID_ZOOM = 10`
remains the coarsen.py algorithm/grid; `COARSE_MAX_ZOOM = 13` is an
independent tile-serving boundary. Historical measurements and the original
z10→z11 handoff discussion below are retained as experiment evidence, not a
description of the current handoff.

At z13 one fixed z10 grid unit occupies one CSS pixel. The deliberately
adversarial §2.1 bound is therefore 3.4 px at the top of the serving band;
ordinary input quantization is at most 0.7 px diagonally and the other error
terms only align on contrived geometry. A dense-Vilnius mobile A/B against
raw z13 retained the same street-level reading, while the skeleton increased
delivered animation frames by 2.5×. That measured pan gain justifies the
one-zoom extension; z14 returns to raw geometry before individual place
inspection.

**Owner's goal (verbatim):** "what can we do to make the low-zoom levels map
lossy, but load quickly for each combos? We _can_ make this visually lossless
at low zoom levels, but not for bytes; for network and CPU." Interpretation
used throughout, per the owner's re-weight: at z6–10 the **binding targets
are bytes, vertices, and switch latency**; the visual bar is "reasonable at
country-overview scale" — visual fidelity is measured and reported, but it
is advisory, not gating. Threshold/mode switches at country zoom currently
take 5–12 s, and a single z7 tile is 2.6 MB; that is the problem being
fixed. Two deliverable variants are specified so the owner can judge the
speed/quality trade side by side: **Variant A** (the near-lossless skeleton,
§2) and **Variant B** (skeleton + deterministic short-chain dropping at
z6–7, visibly lossy, §4.6); the comparison protocol is §6.

**In-flight data change:** the measurements here were taken on a build with
hospital bands [20,30,60]. Main has since landed hospital re-banding to
[15,30,45,60] (commit c2d295b1953c), which raises the attribute-map ∏ bound
from 288 to 4·5·3·2·3 = 360 and will increase the actual group count and
refine the piece partition (less coalescing, somewhat less dedup). All
group-count-dependent statements below are therefore written data-driven
("N groups", N = 188 on the measured 3-band build), and the step-L2 budgets
are *set by re-measurement* on a 4-band build (procedure in §5), not copied
from this document.

---

## 0. Summary of the recommendation

Build a **coarse companion geometry** for z6–10 — an attribute-preserving,
encoder-grid *skeleton* of the network — and serve it in the **same
`network` source-layer** of the same `access.pmtiles` via tilemaker's
`write_to`, with the raw layer restricted to z11–14. The skeleton is produced
by a new deterministic post-processing step over `work/network.geojson`:
per attribute-map group, quantize every segment to the z10 MVT coordinate
grid, deduplicate identical grid segments, split at z10 tile boundaries,
chain into polylines, drop exactly-collinear interior points. Attribute maps
(and therefore all three view modes' expressions) are unchanged; the
front-end needs **zero changes** to remain correct.

Measured on the country build (prototype, §4): z6–10 tile bytes
**228.7 MB → 24.8 MB (−89%)**, z6–10 encoded vertices
**124.1 M → 8.9 M (−93%)**, single z7 tile **2.6 MB → 0.45 MB**. Country-zoom
switch latency, which scales with re-bucketed vertices, drops proportionally:
an estimated **5–12 s → 0.5–1.1 s** with the current `setFilter` code
untouched. A second, **planned** phase (L3) moves combo switching to
per-group `feature-state` styling (group id `g` + `promoteId`), eliminating
re-bucketing entirely, with a **binding < 300 ms switch-latency target** at
every zoom. Visual fidelity was measured, not assumed: occupancy diff
against today's tiles at display resolution flips ≤ 1.0% of lit pixel
centers at z6 and ≤ 4.2% at z8 (symmetric gain/loss, consistent with
sub-pixel displacement, §4.4), under a 1.25 px stroke everywhere in z6–10.
A visibly-lossy Variant B (short-chain dropping at z6–7, §4.6) is built
alongside for the owner's side-by-side verdict (§6).

---

## 1. Measured baseline (why the current tiles are slow)

### 1.1 Per-zoom content of the current country `access.pmtiles`

Decoded from the archive itself (all tiles fully decoded for z6–10; z11–14
feature/vertex figures are 1-in-50 sampled estimates, byte/tile counts exact):

| z | tiles | MB (gz) | avg KB/tile | MVT features | linestrings | vertices |
|---:|---:|---:|---:|---:|---:|---:|
| 6 | 4 | 8.87 | 2 165 | 475 | 3 305 323 | 6 675 004 |
| 7 | 8 | 21.21 | 2 589 | 712 | 6 884 710 | 14 202 455 |
| 8 | 17 | 39.98 | 2 296 | 1 219 | — | 23 569 296 |
| 9 | 50 | 67.94 | 1 327 | 2 601 | — | 35 869 482 |
| 10 | 174 | 90.69 | 509 | 5 139 | — | 43 791 957 |
| 11–14 | 45 160 | 590.1 | — | ~200 k | — | ~260 M (est) |
| **z6–10** | **253** | **228.7 (27.9% of archive)** | | | | **124.1 M** |

The z6–10 fraction is what a user at country zoom downloads and what MapLibre
re-buckets on every `setFilter`/visibility flip. For scale: the **whole
viewport at country zoom is 4–8 tiles ≈ 9–21 MB compressed and 6.7–14.2 M
vertices**.

### 1.2 Why simplification (T3 §2.3) already hit its ceiling

- `work/network.geojson`: 188 features = 188 distinct attribute maps on the
  measured 3-band-hospital build (the then-∏-bound of 288 not reached; after
  the hospital [15,30,45,60] re-banding the bound is 360 and the actual
  count will be re-measured — everything below treats the group count as
  data-driven N), 1 339 340 pieces, 5 580 359 points,
  total polyline length **154 971 km**. 46.8% of pieces are 2-point;
  median ≈ 3 points.
- Inside a z6 tile: 827 936 separate linestrings, of which **98.4% are
  2-point** after quantization. Visvalingam operates per linestring and can
  never remove a linestring's endpoints, so on 2-point confetti it removes
  nothing. Control experiment: raising the tolerance from 1 to 4 MVT units
  on the raw layer changes z6 vertices by **−1%** (6.68 M → 6.61 M) and z6–8
  bytes by −7% (70.1 → 65.5 MB). Per-zoom knobs on the raw geometry are a
  dead end — this kills option (b) of the evaluation brief as a primary fix.
- Duplication on top of the confetti: (i) coordinate-range decoding shows
  **27% of z6 and 41% of z7 vertices lie outside their tile's own extent**
  (tilemaker's line clip box for GeoJSON sources is loose — roughly ±2 tile
  extents; small features are included per-bbox and their out-of-tile tails
  shipped); (ii) after quantization to the z6 grid, the 4.24 M input
  segments collapse to only **1.42 M distinct grid segments** — i.e. the
  z6 tiles ship ≈ 2.3× redundant coincident copies (parallel footway/street
  pairs, dual carriageways, and cross-group repeats).
- Rendering reality at z6–10: `corridorLineWidth()` clamps to the 1.25 px
  floor for both modes at all of z6–10 (24 m walk / 36 m drive corridors are
  ≪ 1 px; the crossover is z11+). One CSS pixel = 8 MVT units (extent 4096
  over a 512 px tile). One MVT unit ≈ 87.7 m ground at z6, 43.9 at z7, 21.9
  at z8, 11.0 at z9, 5.5 at z10 (lat 55°). The tiles therefore carry
  geometry 8× finer than one pixel in each axis, drawn with a 1.25 px pen.

### 1.3 What a combo switch costs today

MapLibre re-buckets (re-tessellates) every visible layer's features in every
loaded tile on `setFilter`, and on `visibility` flips (every view-mode switch
flips visibility of 1–2 of the four access layers). At country zoom that is
the z6/z7 numbers above — the owner-measured 5–12 s. Per-combo feature
*selectivity* does not save the re-bucket (filters are evaluated during the
re-bucket itself), but for reference, share of z7 vertices passing typical
combos: union of all four services at max thresholds 100%, `hospital_drive`
≤ 60 alone 89.5%, union at default presets 77.5%, coffee bands 32.8%,
"everyday walk" intersect 15.0%, intersect of all four at defaults 8.9%. Even
the most selective combo still re-buckets all 14.2 M vertices at z7.

---

## 2. Design: encoder-grid skeleton for z6–10

### 2.1 The losslessness argument, stated up front

The MVT encoder already rounds every vertex to the tile's 4096-grid at each
zoom. Two operations are therefore *pixel-exact by construction* relative to
what the encoder already does:

1. **Quantizing input vertices to the target-zoom grid** — displacement
   ≤ ½ unit, i.e. at or below the encoder's own rounding.
2. **Deduplicating segments that quantize to the same grid segment** — the
   tile would have drawn the same pixels twice; one copy draws them once.
   (Sole caveat: coincident strokes at `line-opacity` 0.9 double-blend today,
   so dedup very slightly *lightens* those pixels. The T3 §2.3 gate already
   classifies draw-order blending deltas as the A/B noise floor; this falls
   in the same class and is, if anything, a rendering improvement.)

Two further operations displace geometry but stay under the T3 §2.3 bound
("tolerance at or below the tile's coordinate quantization step"):

3. **Exactly-collinear interior point removal** — zero displacement.
4. **Visvalingam at exactly 1 MVT unit per zoom** (the committed §2.3
   mechanism, extended to also cover the band's top zoom) — ≤ ~1 unit
   = ⅛ px displacement.

One operation has a larger worst case than the encoder grid: the recursive
integer-midpoint **boundary bisection** of §2.2 step 3. Each level halves
the segment but adds up to ½ unit per axis of rounding, so the deviation
recursion is `e_{k+1} ≤ e_k/2 + ½` per axis, whose fixed point is **1 unit
per axis** (≈ 1.4 units diagonally) — not ½ unit. (An earlier draft of this
document claimed ½; that was wrong.)

Total worst-case displacement budget at z10: ~0.7 units diagonal (input
quantize, item 1) + ~1.4 units (bisection fixed point) + ~1 unit
(visvalingam) + encoder re-rounding at lower zooms ≈ **3.4 MVT units ≈
0.43 px** under the 1.25 px stroke — worst case, requiring adversarial
geometry at every stage; typical displacement is far smaller (the measured
occupancy diffs of §4.4 reflect the typical case). Under the owner's
relaxed constraint (visual bar is "reasonable", performance is binding,
§0), 0.43 px worst-case is comfortably fine. Chaining pieces through
junctions (5 below) changes only join rendering (`line-join: miter`,
limit 2, at 1.25 px) — not occupancy. Empirical confirmation in §4.4.

### 2.2 The coarsening algorithm (normative)

Input: `work/network.geojson` (the merge tool's output, T3 §1.3 step 7 —
one Feature per attribute map, MultiLineString of pieces). Output:
`work/network-lowzoom.geojson`. Fixed parameters: `GRID_ZOOM = 10`,
`EXTENT = 4096`, so one grid unit is `360 / (4096·2^10)` projected degrees in
(lon, latp) space — **exactly the grid tilemaker's encoder rounds to at z10**
(tilemaker stores geometry in lon/latp projected degrees; latp(φ) =
deg(asinh(tan(rad(φ))))).

Per input feature (= attribute-map group), carrying group index `g` **read
from the input** (single source of truth: the merge tool emits `g` = feature
index in emission order into `network.geojson`, §2.3; coarsen.py asserts the
`g` values are exactly `0..N-1` in file order and never assigns its own):

1. **Quantize.** For each piece, map each vertex `(lon, lat)` to integer
   grid coordinates `(round(lon/U), round(latp(lat)/U))`, `U` = the grid
   unit. Collapse consecutive identical grid points.
2. **Segment + dedup.** Decompose into undirected grid segments (ordered
   pairs, lexicographically smaller endpoint first); insert into a per-group
   set. Coincident geometry within the group — regardless of which pieces it
   came from — dedups here.
3. **Split at z10 tile boundaries.** A segment whose endpoints lie in
   different z10 tiles (`tile = (x div 4096, y div 4096)`) is split by
   recursive integer midpoint bisection (`m = ((x1+x2) div 2, (y1+y2) div 2)`,
   recurse on both halves, stop when both endpoints share a tile or the
   midpoint equals an endpoint). Worst-case deviation of the split polyline
   from the exact segment is the fixed point of `e_{k+1} ≤ e_k/2 + ½` per
   axis = 1 unit per axis (≈ 1.4 units diagonal) — accounted for in the
   §2.1 budget. Assign each resulting sub-segment to the tile shared by its
   endpoints; for the terminal case where the midpoint equals an endpoint
   (a residual segment whose endpoints lie in different — necessarily
   adjacent — tiles and which cannot be split further), assign the whole
   segment deterministically to the **lexicographically smaller** of the two
   `(tx, ty)` tiles. *Why split at all:* tilemaker includes GeoJSON line
   features in every tile their
   bbox touches and clips them only to a ±2-extent box; unbounded chains
   would be replicated into neighboring tiles nearly whole (measured: a
   country-wide-chain variant shipped 74% out-of-tile vertices and 6× the
   bytes, §4.3). Tile-bounded chains cap that waste structurally.
4. **Chain per (group, tile).** Build the simple graph of the tile's grid
   segments. Walk deterministically: two phases — first all start nodes of
   odd degree in ascending (x, y) order, then remaining nodes (cycles) in
   ascending order; from each start, repeatedly move to the smallest
   unconsumed neighbor, consuming edges, until stuck; each walk emits one
   chain. Chains pass straight through junctions — permitted because
   junction fidelity is invisible at a 1.25 px stroke (§2.1) and it is what
   lets a network of 2-point confetti become long simplifiable polylines.
5. **Collinear drop.** Remove interior points where the integer cross
   product of the adjacent segments is 0 and the dot product is positive
   (strictly straight-through). Zero displacement, exact integer test.
6. **Emit.** One GeoJSON **LineString Feature per chain** (measured better
   than per-(group, tile) MultiLineStrings, §4.3), properties = the input
   feature's properties verbatim (the full attribute map **plus the `g`
   carried through from the input**), coordinates
   de-quantized (`x·U`, inverse-latp of `y·U`) printed at 1e-7 like all
   pipeline geometry. Features ordered by (g, tile, chain emission order) —
   fully deterministic.

Measured output at country scale: 4 150 841 unique grid segments → 613 549
chains, 4 202 073 points (avg 6.8 points/chain vs 4.2 for input pieces, and
crucially chains are simplifiable where 2-point pieces were not);
114 MB GeoJSON (25.6 MB gz). Prototype cost: 46 s / 1.9 GiB peak RSS in
single-threaded Python at country scale — well within the build budget
(routing phase alone is 262 s; merge tool 2.5 GiB).

**Where it runs:** a new module `pkgs/mapgames/coarsen.py` invoked by
generate.py between the merge step and the access tilemaker step. Rationale
for Python over extending the C++ merge tool: no Valhalla dependency, pure
function of one work/ intermediate, unit-testable in isolation, and the merge
tool's elaborate step-3/4 gate machinery stays untouched. Single-threaded by
design (determinism for free). If an implementer later ports it to C++ for
speed, the byte-diff gate carries over unchanged.

**Zoom-band choice, justified by measurement:** one z10-grid source serves
all of z6–10. A two-band variant (z8-grid source for z6–8) was built and
measured: 10.36 vs 10.94 MB for z6–8 — a 5% improvement that does not pay
for a second artifact and config path. The ratio-2 `simplify_ratio` mechanism
(T3 §2.3/R6) holds the effective tolerance at exactly 1 unit at *every* zoom
from one anchor, so coarser grids buy almost nothing after simplification.

### 2.3 Tiling integration

`network_tile_config()` in generate.py becomes two config layers writing to
**one MVT layer** (verified against the pinned tilemaker 3.1.0: `write_to`
merges GeoJSON layers across zoom ranges into a single named source-layer;
test build decoded to layer `network` with coarse features at z6–10 and raw
at z11–12):

```python
{
  "layers": {
    "network": {                       # raw pieces, inspection zooms
      "minzoom": 11, "maxzoom": 14,
      "source": str(work / "network.geojson"),
      "source_columns": sorted((*REQUIREMENT_KEYS, "g")),
      # original proposal: z11-14 shipped raw geometry
    },
    "network_lowzoom": {               # encoder-grid skeleton
      "minzoom": TILE_MIN_ZOOM, "maxzoom": 10,
      "source": str(work / "network-lowzoom.geojson"),
      "source_columns": sorted((*REQUIREMENT_KEYS, "g")),
      "write_to": "network",
      "simplify_below": 11,            # simplify at z6..z10 inclusive
      "simplify_level": 360 / (4096 * 2 ** 10),   # 1 MVT unit at z10 …
      "simplify_ratio": 2.0,           # … and therefore at every zoom
      "simplify_algorithm": "visvalingam",
    },
  },
  "settings": common_tile_settings(...)   # unchanged
}
```

Notes:

- `simplify_below: 11` is the value the committed config already uses — z10
  is *already* visvalingam-simplified at 1 unit today. What is new at z10 is
  the quantize+dedup+chain input, not the simplification; the note-worthy
  interaction is that the pass matters much more for the skeleton (its
  z10-grid stair-steps and dense curve sampling are exactly what 1-unit
  visvalingam removes): an experiment that exempted the band's top zoom
  from simplification measured 2.5× larger z10 tiles. Displacement stays
  inside the §2.1 budget.
- `NETWORK_SIMPLIFY_LEVEL` (anchored at z10) is reused as-is;
  `LOW_ZOOM_GENERALIZATION_BELOW` keeps its value 11 but now denotes the
  raw layer's minzoom; update its comment, not its value.
- The raw layer's `minzoom` moves 6 → 11. Nothing else about it changes, so
  z11–14 tile content is unchanged (gate, §5).
- `metadata.json`: `access_network` gains
  `"lowzoom": {"max_zoom": 10, "grid_zoom": 10}` (informational) and — for
  phase B — `"groups": [{...attr map...}, ...]` indexed by `g`, written by
  generate.py by reading `network.geojson`'s features in `g` order — the
  same single source that feeds the tiles, never a second derivation (§3.2).
  `geometry.low_zoom_generalization_below` stays 11.
- `network-lowzoom.geojson` is a `work/` intermediate, not published,
  exactly like `network.geojson` (T3 §2.2 rationale applies unchanged).

### 2.4 Compatibility with the three view modes

The skeleton preserves the attribute model exactly: same five requirement
keys, same integer-minutes values, same absent-key-means-unreachable
semantics, same N attribute maps (assert in the coarsen tool: the set of
distinct property maps emitted equals the set read — with one measured
exception: a group whose every piece quantizes to a single z10 grid point
(sub-grid-unit geometry, ~2 of 198 groups on the 4-band build) derives zero
grid segments and may vanish from the skeleton; the coarsen tool logs this
loudly, the checker independently re-verifies zero derived segments, and a
vanished group that DID derive segments is a hard failure). Every
expression in index.html — `reachableTest`, bands `match`, intersect
`all`/`any`, score sum — evaluates identically over coarse features because
it only reads the attribute map. Bands view renders disjoint-by-construction
band values exactly as before (a chain belongs to one group, hence one band
value per requirement). The `g` property is additive; MVT readers ignore
unknown properties, and `["has","coffee_walk"]`-style tests are unaffected.
**Phase A requires no front-end change at all.**

The z10→z11 handoff (skeleton → raw) displaces rendered lines by up to
~7 z11 units ≈ 0.9 px **worst-case** at the moment of crossing (the §2.1
worst-case budget of ≈ 3.4 z10 units, doubled in z11 units); the typical
displacement is a small fraction of that (§4.4), and the pop happens once
at a zoom transition, where per-zoom simplification pops already occur.
Judged acceptable under the relaxed visual bar; the §6 screenshot pairs let
the owner see it. The z11+ inspection zooms themselves are untouched.

---

## 3. Client-side phase (planned, step L3): feature-state styling

### 3.1 What Phase A already buys client-side

Re-bucket cost scales with features+vertices in loaded tiles. At z7 the
viewport drops from 14.2 M vertices / 6.9 M linestrings to 1.28 M / 0.55 M —
with the *existing* `setFilter`/`setPaintProperty` code, the measured 5–12 s
becomes an estimated 0.5–1.1 s (linear scaling from the owner's own
measurement; verify on device in the phase gate). z9/z10 viewports improve
by the same ~14× factor. Phase B is nonetheless a planned step, not an
option: its binding target is < 300 ms combo-switch latency at every zoom
(§5, L3), which the Phase-A `setFilter` path does not reliably reach at
country zoom. The Phase-A-before-B ordering stands — §3.2 explains why B
without A cannot meet the goal.

### 3.2 Phase B: per-group feature-state, zero re-buckets

Rationale: every view mode is a pure function *attribute map → (color,
opacity)*. There are only N attribute maps (188 on the measured build,
bounded by 360 after the hospital re-banding), and each tile feature now
carries its group index `g` (both zoom bands, §2.3). So:

- Source gains `promoteId: {"network": "g"}` — feature id = group id.
  Multiple features sharing one id is supported MapLibre behavior
  (feature-state is an id-keyed map consulted per feature).
- The four access layers collapse to **two permanent layers** (both
  `visibility: visible` from load, constant filter `["has", "g"]`):
  `access-under` (renders the intersect view's context union) and
  `access-main` (renders bands / intersect ink / score, whichever view is
  effective). Paint:

  ```js
  "line-color":   ["to-color", ["coalesce", ["feature-state", "c"], "rgba(0,0,0,0)"]],
  "line-opacity": ["number",   ["coalesce", ["feature-state", "o"], 0]],
  ```

  `line-width` stays a plain (non-data-driven) zoom curve set via
  `setPaintProperty` on mode change — cheap repaint, no re-layout. (Do NOT
  put width under feature-state without first verifying the pinned MapLibre
  version supports feature-state in `line-width`; color/opacity support is
  long-standing.)
- `refreshMap()` computes, in JS, for each of the N groups (attribute maps
  shipped in `metadata.access_network.groups`, indexed by `g` — the client
  never needs to read attributes from tiles and never hardcodes N): the pair
  (c, o) for each of the two layers under the current selection+mode, and
  applies N×2 `setFeatureState` calls. No `setFilter`, no visibility flips, no
  re-tessellation — the update path is a paint-buffer refresh over loaded
  tiles (~1.3 M vertices at country zoom after Phase A): estimated well
  under 200 ms on mid-range mobile, at *every* zoom including z11–14.
- Keep the legacy styling functions behind the effective-mode logic; the
  view-mode model, legend, chips, URL state (T3 §3.2–3.4) are untouched —
  only the mechanism that pushes styles to the map changes.

Trade-offs, stated honestly: constant-true filters mean all groups are
tessellated at tile load (today filtered-out features are skipped) — at
coarse z6–10 densities this is the same work the *first* render already does
for the union-heavy combos (77–100% of vertices, §1.3), and it moves cost
off the interaction path; hidden (o = 0) lines cost ~zero fragments. Initial
paint before the first `setFeatureState` renders nothing (coalesce default
opacity 0), which matches today's "layers hidden until refreshMap()" flow.

Phase B without Phase A would NOT meet the goal: feature-state still refreshes
paint buffers over 14.2 M vertices at z7 (est. 1–3 s) and constant-true
filters would *increase* the initial bucket over today's raw tiles. The two
compose; the data fix comes first.

---

## 4. Evaluation of the alternatives (all measured)

### 4.1 (b) tilemaker per-zoom knobs on the raw layer — rejected

Measured: 4-unit visvalingam (4× the committed tolerance, already past the
visually-lossless line) moves z6 vertices −1%, z6–8 bytes −7% (§1.2). Root
cause is structural (98% 2-point linestrings, per-tile independence): no
per-layer knob in 3.1.0 (`simplify_*`, `feature_limit[_below]`,
`filter_below`/`filter_area`, `combine_*`) can merge geometry across
features, dedup coincident segments, or bound the loose clip box.
`feature_limit_below` could cap tile size but drops features
non-deterministically with respect to visual salience — plainly not
visually lossless. Keep the committed §2.3 config for the raw z11–14 layer;
add nothing here.

### 4.2 (a) plain dissolve + simplify of same-attribute pieces — subsumed

A topology-preserving dissolve (join pieces only at degree-2 nodes, the
classical attr-preserving merge) was prototyped: 1.34 M pieces → 1.15 M
chains (−14%) — real street networks junction too often for degree-2 joins
to matter. Junction-crossing chaining is what unlocks the win, and once
chains cross junctions the natural formulation is the grid graph of §2.2,
which additionally dedups coincident geometry (2.3× at the z6 grid) for
free. §2.2 *is* option (a) taken to its correct limit; there is no separate
competitor to keep.

### 4.3 (d) per-(group, tile) pre-dissolved MultiLineStrings — measured, lost

One MultiLineString feature per attribute group per z10 tile (5 089 features
country-wide) was built and tiled: z6–7 bytes improve a further ~35%
(1.60 MB z6) and feature counts collapse, but tile-sized bboxes trip
tilemaker's neighbor-inclusion: z10 ships 7.05 M vertices vs 2.84 M for
per-chain features, and total z6–10 bytes are 29.7 vs 24.8 MB. Per-chain
features win overall and are what §2.2 specifies. (If z6/z7 feature-count
overhead ever shows up in profiles, the tuning knob is grouping chains into
MultiLineStrings per (group, z12 cell) — bboxes ≪ tile — but this is not
part of this design.)

### 4.4 Chosen design, measured end-to-end (prototype `single2`)

Country build, z10-grid skeleton, per-chain features, 1-unit visvalingam at
every zoom (§2.3 config):

| z | MB now | MB coarse | Δ bytes | verts now | verts coarse | Δ verts |
|---:|---:|---:|---:|---:|---:|---:|
| 6 | 8.87 | 2.63 | −70% | 6 675 004 | 1 013 375 | −85% |
| 7 | 21.21 | 3.61 | −83% | 14 202 455 | 1 282 643 | −91% |
| 8 | 39.98 | 4.70 | −88% | 23 569 296 | 1 614 396 | −93% |
| 9 | 67.94 | 6.05 | −91% | 35 869 482 | 2 099 940 | −94% |
| 10 | 90.69 | 7.78 | −91% | 43 791 957 | 2 838 073 | −94% |
| **z6–10** | **228.7** | **24.8** | **−89%** | **124.1 M** | **8.85 M** | **−93%** |

Archive total: 819 MB → ≈ 615 MB (−25%; z11–14 unchanged). Country viewport
first paint: 8.9–21.2 MB → 2.6–3.6 MB of tiles.

**Visual losslessness, empirically:** occupancy rasters at display
resolution (512×512 px per tile, i.e. 8 MVT units/px — the actual pixel
grid under a 1.25 px stroke), baseline vs coarse, per combo:

| zoom | combo | lit px (union) | baseline-only | coarse-only |
|---:|---|---:|---:|---:|
| z6 | union max thresholds | 108 427 | 1.00% | 0.91% |
| z6 | intersect 4 @ defaults | 1 504 | 0.60% | 0.47% |
| z6 | coffee_walk ≤ 10 | 3 727 | 0.59% | 0.46% |
| z8 | union max thresholds | 678 696 | 3.89% | 4.20% |
| z8 | intersect 4 @ defaults | 12 617 | 0.98% | 0.72% |
| z8 | coffee_walk ≤ 10 | 27 091 | 1.35% | 1.22% |

Differences are symmetric (no systematic coverage loss) and of the magnitude
that pixel-center tests show under sub-pixel displacement; with 1.25 px
strokes plus antialiasing these are consistent with the noise floor the T3
§2.3 A/B gate already accepts. Read this metric for what it is: a
**coverage-regression tripwire** (it catches a bug that drops or invents
whole areas of coverage loudly and cheaply), not a proof of visual
losslessness — pixel-center occupancy ignores stroke width, antialiasing,
and blending. The human judgment on appearance is the advisory screenshot
comparison of §6; the binding gates are the byte/vertex/latency numbers
(§5).

### 4.5 (c) feature-state alone — rejected as primary, adopted as Phase B

Quantified in §3.2: without the data fix it still touches 14.2 M vertices of
paint buffers at z7 and worsens initial bucketing. After the data fix it is
the difference between ~1 s and ~0.1 s switches, and it also fixes mid-zoom
(z9–13) switch cost that data alone only partially addresses.

### 4.6 Variant B: skeleton + short-chain dropping at z6–7 (visibly lossy)

The owner explicitly wants a side-by-side of "near-lossless" against
"lossier but smaller/faster". Variant B is Variant A plus one additional,
deliberately *visible* reduction at the two coarsest zooms:

**Construction (normative).** After §2.2 step 6, a second filtered artifact
`work/network-lowzoom-z67.geojson` is derived from the Variant-A chains:
drop every chain whose z10-grid length `L` — the sum of Euclidean segment
lengths in grid units, `Σ sqrt((Δx)² + (Δy)²)`, accumulated in emission
order over the chain's post-collinear-drop points — satisfies `L < N_drop`,
where `N_drop` is a build parameter in grid units (starting value 64 ≈
350 m ground; tuned during the §6 comparison). The rule is a pure threshold
on a deterministic per-chain quantity computed single-threaded in a fixed
order, so no tie-break beyond the threshold itself is needed (`L ≥ N_drop`
keeps, `L < N_drop` drops); chains are never re-ranked or budgeted, so the
output is a deterministic subset of Variant A's chains with order
preserved. The tilemaker config gains a third `write_to: "network"` layer:
`minzoom 6, maxzoom 7, source network-lowzoom-z67.geojson` with the same
simplify keys, and the Variant-A skeleton layer's `minzoom` moves 6 → 8.
Everything else — attributes, `g`, z8–10, z11–14, client — is identical to
Variant A.

**What it loses, honestly:** short isolated coverage fragments (small
hamlets' street stubs, disconnected walk pockets) disappear from z6–7
entirely — a real, visible edit, not sub-pixel noise. They reappear at z8.
This is exactly the trade the owner asked to see priced.

**Why this knob and not a coarser grid:** the grid dimension is measured
exhausted — a two-band z8-grid variant improved z6–8 bytes by only 5%
(§2.2), so `GRID_ZOOM = 10` stays fixed for both variants; chain dropping
is the orthogonal knob that removes *features*, which is where the
remaining z6–7 bytes and vertices live.

**Measurement:** Variant B gets its own row in every §6 matrix (bytes and
vertices at z6/z7, % chains and % total chain-length dropped at the chosen
`N_drop`, switch latency, load time) plus its own screenshot pairs. Numbers
are produced by the §6 protocol on the 4-band build — deliberately not
guessed here.

---

## 5. Determinism and gates

The coarsen tool is a pure, single-threaded function of `network.geojson`
with integer-grid arithmetic everywhere except the fixed `latp`/`inv_latp`
formulas (same libm via the pinned nix toolchain; same-builder byte-diff is
the standard the whole pipeline already uses, T3 §6). Feature order, chain
order, and walk order are fully specified (§2.2 steps 4/6) — no iteration
over unordered containers.

Phasing follows the T3 §7 conventions: each step a separate reviewed commit,
Vilnius byte-diff harness as the spine, context-free adversarial review,
lt-full measured before deploy.

**Step L1 — coarsen tool + checker.**
Deliverables: the one-property merge-tool change emitting `g` (= feature
index, `0..N-1` in file order) into `network.geojson` — moved here from L2
so L1's gates can run against a main-built input; `coarsen.py`; an
independent checker (separate code, no shared functions) that verifies,
per group: (i) the multiset of undirected grid
segments covered by output chains equals, exactly, the set obtained by
independently quantizing+deduping+boundary-splitting the input (segment-set
equality proves dedup, splitting, and chaining lost/invented nothing —
collinear removal is checked by re-expanding output segments across dropped
interior points); (ii) output attribute maps = input attribute maps
(including `g`, carried through verbatim); (iii) input `g` values are
exactly `0..N-1` in file order (coarsen asserts, checker re-verifies);
(iv) for the Variant-B artifact: the output is exactly the subset of
Variant-A chains with `L ≥ N_drop`, order preserved (§4.6).
*Gate:* checker green on Vilnius and lt-full; two runs byte-identical;
runtime/RSS recorded (prototype reference: 46 s / 1.9 GiB lt-full).
*Reviewer checks:* integer-only geometry predicates; deterministic walk
order actually specified and implemented (no set/dict iteration order
leaks); boundary bisection terminates, its deviation bound is the 1-unit-
per-axis fixed point of `e_{k+1} ≤ e_k/2 + ½` (do NOT demand ½ unit — that
tighter bound is unachievable and would bounce a correct implementation,
§2.1), and the unsplittable adjacent-tile case uses the lexicographically-
smaller-tile rule (§2.2 step 3); no floating-point comparisons in dedup
keys.

**Step L2 — tile integration (data cutover for z6–10).**
generate.py: run coarsen, `write_to` config (§2.3; three layers if Variant B
is selected, §4.6), add `g` to `network.geojson` emission (merge tool: one
extra integer property per feature, feature index in emission order) and to
`source_columns`.
*Budget-setting procedure (M-gate prerequisite):* the byte/vertex budgets
are NOT the numbers in this document (measured on the 3-band-hospital
build). Before L2 lands: rebuild the lt-full baseline on current main
(hospital [15,30,45,60]), run the coarsen prototype pipeline against it,
record per-zoom bytes/vertices for baseline and coarse, and set each budget
to the measured coarse value × 1.4 headroom, written into the harness with
the measurement log in the commit message. (3-band reference points, for
sanity only: 24.8 MB / 8.9 M vertices z6–10.)
*Gate (BINDING, in priority order):* (1) z6–10 byte and vertex budgets per
the procedure above; (2) combo-switch latency at country zoom, before vs
after, measured on the reference mid-range phone and via the §6 CDP
harness — must show the order-of-magnitude drop this design promises;
(3) z11–14 per-tile decoded feature counts, vertex counts, and attribute
sets (minus `g`) identical to the previous build (byte equality is not
available — tilemaker's encoder is not byte-deterministic, per the T3 §2.3
precedent); (4) occupancy-diff coverage-regression tripwire (rasterdiff-
style, pixel-center occupancy per combo at z6 and z8 across the
union/intersect/bands combos): ≤ 2% at z6 and ≤ 6% at z8 with
|baseline-only − coarse-only| ≤ 2 points for Variant A (Variant B is
exempt at z6–7 by design; record its numbers instead of gating them).
*Advisory:* screenshot A/B at z6/z7/z8/z10 in all three view modes vs the
pre-change build, same cameras — the bar is "reasonable at country-overview
scale", owner's call via §6; screenshots inform, they do not gate.
*Reviewer checks:* raw layer truly unchanged except minzoom (config diff);
`write_to` output has exactly one `network` source-layer at every zoom
(decode, don't trust config); `g` values consistent between zoom bands of
the same build; metadata advertises the new keys and nothing stale;
work/-only intermediates stay unpublished.

**Step L3 — Phase B front-end (planned).**
As §3.2: promoteId, two permanent layers, `metadata.access_network.groups`,
feature-state styling; delete the per-view visibility flipping and
per-switch `setFilter` calls.
*Gate (BINDING):* measured combo-switch latency **< 300 ms** at z7 and z13
on the reference phone (expected < 200). As executed: evaluated on the
swiftshader CDP harness (desktop 1920×1080 + phone-viewport 390×844) as the
reference-phone proxy; the desktop-viewport z13 mode-switch (440 ms) is an
upload-bound software-GL artifact — MapLibre re-uploads the whole ~101 MB
data-driven paint array per state change and swiftshader moves 250–500 MB/s
where a real GPU moves tens of GB/s — and is therefore non-gating; the
phone-viewport battery passes with ×10 margin. z11–14 initial tile bucket cost
measured before/after — constant-true filters tessellate all groups at tile
load, so record tile-load/bucket time at z12 and z13 (loaded-tile
`bucket`/layout timing via the §6 CDP harness) and confirm pan/zoom tile
latency at inspection zooms has not regressed noticeably; URL-hash and
inspect-dialog regressions per T3 §7 step 6's list; no console errors
(including the feature-state-before-load window).
*Advisory:* screenshot set identical to step L2's across views ×
selections × desktop/mobile.
*Reviewer checks:* every expression reading feature-state has a coalesce
default; opacity-0 initial state (no flash of unstyled network); the
N-entry group loop allocates nothing per frame and reads N from metadata;
`groups` metadata is derived from the same source as the tiles' `g` (merge
tool emission order via network.geojson, §2.3), not recomputed by a second
code path; Phase A styling code fully deleted, not dead-coded (per the
no-historical-artifacts policy).

---

## 6. Variant comparison protocol (owner verdict)

Purpose: give the owner a concrete side-by-side to answer "is the speed good
enough" (Variant A) and "is the quality not too bad" (Variant B), before the
L2 cutover commits to one. Both variants are built at country scale on
current main (4-band hospital) and served locally beside the current build:

- **Serving:** three static sites on separate local ports — the unmodified
  current build (the existing :8802 instance), Variant A, Variant B — each
  a full `generated/` set with its own `access.pmtiles`, same index.html.
- **Numeric matrix** (one row per variant, including the current build as
  baseline; produced by scripts, committed alongside the verdict):
  - bytes per zoom z6..z10 and z6–10 total; whole-archive size;
  - decoded vertices and features per zoom (zoomstats-style full decode);
  - Variant B additionally: % chains and % total chain-length dropped at
    the chosen `N_drop`;
  - initial country-load time (cold cache: page load → network idle with
    all viewport tiles rendered, via Chrome DevTools Protocol);
  - combo-switch latency at country zoom (z7) and street zoom (z13), cold
    (first switch after load) and warm (repeated switches), driven via CDP
    (script the same switch sequence: "all services" score → intersect →
    threshold flip → bands), reporting main-thread busy time per switch;
  - peak JS heap after load at z7.
- **Screenshot pairs:** z6, z7, z8, fixed cameras (country center + one
  dense-city and one sparse-rural camera), all three view modes, all three
  builds — presented as A/B/current triptychs.
- **Verdict rule:** owner picks Variant A or B (or A with a different
  `N_drop` for a re-run). The chosen variant's measured numbers seed the L2
  binding budgets (×1.4 headroom, §5). The protocol artifacts (matrix +
  screenshots) go into the L2 commit for the adversarial reviewer.

---

## 7. Risks

- **R-L1 (med): tilemaker GeoJSON inclusion/clipping semantics drift.** The
  design leans on measured 3.1.0 behavior (per-bbox inclusion, ±2-extent
  clip). A tilemaker upgrade could change the constants and re-inflate
  tiles. Mitigation: the step-L2 byte/vertex budgets are permanent gates in
  the harness; they fail loudly on such drift.
- **R-L2 (med): feature-state id sharing.** Phase B assumes many features
  per id is efficient in the pinned MapLibre. It is documented behavior, but
  verify at country zoom (all four coarse z6 tiles loaded ≈ 475 k features /
  1.0 M vertices sharing N ids) on the reference phone before committing
  to L3.
  If `setFeatureState`×N shows per-call overhead, batch by updating a
  single style-wide `line-color` match expression instead (still no
  re-bucket) — decide inside L3, both paths are small.
- **R-L3 (low): double-blend lightening** where dedup removes coincident
  strokes (§2.1). Falls inside the established A/B noise floor; the §6
  advisory comparison / owner verdict is the arbiter. If a reviewer flags corridors that
  visibly lightened, the fallback is raising `line-opacity` toward 1.0 at
  z≤10 (blending differences vanish at opacity 1).
- **R-L4 (low): chain-through-junction join artifacts** (miter spikes at
  acute grid angles). Bounded by `line-miter-limit: 2` already in
  `lineLayout()`; visible only above ~2.5 px widths, which begin at z11
  where the skeleton no longer serves. The §6 advisory comparison covers it.
- **R-L5 (low): `g` stability.** `g` is a per-build index; it must never be
  persisted client-side across deploys. It is not: URL state stores
  requirement keys/minutes, never group ids, and index.html + data deploy
  atomically (T3 §2.2 migration note). Record this constraint as a comment
  where `groups` metadata is written.
- **R-L6 (low): coarsen scale-up.** 46 s / 1.9 GiB today; both grow
  linearly with network size. A future multi-country build would want the
  C++ port (the algorithm is specified integer-exact precisely so the port
  is mechanical and gate-compatible).

---

## 8. Original proposal scope (historical)

At the time of the measured proposal, it did not change raw z11–14 tiles, the
merge tool and its §1.3 algorithm and gates (except one added integer property
at emission), destination lookup tiles, the inspect flow, places pipeline,
basemap, view-mode/legend/URL model, palettes, requirement schema, or published
artifact set. Current-tree follow-ups described at the top of this record now
serve the skeleton through z13; separate UX follow-ups changed the inspect
loading/catalog flow and palettes and added `place-catalog.json`. This section
records the experiment boundary, not the current deployed artifact contract.
