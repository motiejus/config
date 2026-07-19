# T3: Unified edge-attributed access network

Design for replacing mapgames' five per-service coverage overlays with one
edge-attributed network layer. Scope: `pkgs/mapgames/{valhalla-expand.cc,
generate.py, index.html, geojson.lua, basemap.json, default.nix}`. The goal
(one network, three view modes, Okabe-Ito palette) is committed; this doc
specifies the mechanism. Priority order, per project owner: UX and correctness
strictly before output size. Size numbers below are informational; no schema or
rendering decision is driven by bytes. A ≥5 GB deployable is acceptable.

Terminology used throughout, tied to current code:

- **canonical edge** — what `canonical_line()` in valhalla-expand.cc produces
  today: a direction-normalized, 1e-7-rounded polyline for one undirected road
  edge (Valhalla directed edge + its opposite).
- **requirement** — a (service, mode) pair, i.e. one entry of `ROUTE_SPECS` in
  generate.py: `coffee/walk`, `hospital/drive`, `supermarket/walk`,
  `supermarket/drive`, `fuel/drive`.
- **band** — one minute threshold of a requirement (`SERVICE_SPECS[...]["routes"]`):
  coffee_walk {5,10,20}, hospital_drive {15,30,45,60}, supermarket_walk {10,20},
  supermarket_drive {10}, fuel_drive {10,20}.
- **piece** — a sub-segment of a canonical edge produced by the segmentation
  algorithm (§1.3); the feature unit of the new layer.

---

## 1. Data model

### 1.1 Attribute schema per feature

Each output feature is a (Multi)LineString of pieces sharing one attribute map.
Attribute keys are requirement keys: `{service}_{mode}` with underscore —
exactly:

```
coffee_walk   supermarket_walk   supermarket_drive   hospital_drive   fuel_drive
```

(`route_key()` in generate.py currently produces `coffee-walk`; the attribute
key is the same string with `-` → `_` so MapLibre expressions read naturally.
Derive both from one helper; do not hand-maintain two lists.)

Value: **integer minutes** — the smallest configured threshold whose merged
interval set covers the piece. This is exactly the legacy `min_minutes`
semantics (the `first_minute` computed by the retired per-route
`coverage_lines()` writer), generalized to all
requirements at once. Integer minutes, not band indices: self-describing,
stable when a band list changes, directly comparable in expressions
(`["<=", ["get","coffee_walk"], 10]` ⇔ "reachable within 10 walk minutes",
because the nesting invariant — the
`"reachable edge intervals are not nested by minute threshold"` check, now
enforced at dump time — guarantees a piece in the 5-band is also in 10 and 20).

**Absent key = unreachable** within that requirement's largest threshold.
MVT has no null; absence is the only representation. Client-side tests MUST
guard with `["has", key]` before `["get", key]` — comparing `null` in a
MapLibre expression is an evaluation error (feature silently dropped from
filters, console warning). Canonical reachability test:

```js
["all", ["has", key], ["<=", ["get", key], selectedMinutes]]
```

Dropped fields relative to the legacy coverage features: `max_minutes` (was
constant `minutes.back()` per route — moves to metadata), `mode`, `service`
(encoded in the key), `direction` (constant `"to_destination"` — moves to
metadata). No per-feature score attribute: the glimpse score depends on the
user's selected subset and thresholds, so it is a client-side expression (§3.2).

### 1.2 Partial edges and slices

`reachable_interval()` produces per-(request, minute) fractional
intervals `[start, end] ⊂ [0,1]` along a canonical edge — including the
origin-edge case where the interval starts mid-edge (`start_fraction =
1.0 - origin_fraction`). The retired per-route writer merged those per service
(`merge_intervals()`) and each service independently sliced its own pieces
(`coverage_lines()` → `slice_line()`), so the same edge shipped up to 5 times
with incompatible cut points.

New model: a single segmentation per canonical edge over the **union of all
requirements' interval boundaries**, each resulting piece attributed
independently. When services cover different slices of the same edge, the edge
splits into pieces such that every piece has one constant attribute map.

### 1.3 Segmentation algorithm (normative)

Input per canonical edge: for each requirement `r` and band `b`, the merged
interval list `I[r][b]` (output of `merge_intervals()`, so sorted,
non-overlapping, gaps > 1e-12). This is the per-band structure the helper's
`DumpEdge` holds for one route; the merge tool holds it for all requirements.

**Step 0 — geometry-string pre-merge (dual digitization).** The legacy
string-keyed maps merged distinct graph edges that share identical 1e-7-rounded
geometry into one entry *before* `merge_intervals()`. Under uint64
keys (§5.1) such edges arrive as separate entries. Before segmentation, group
entries by their canonical geometry string (`canonical_line().key`),
concatenate the per-band interval lists of all members, and re-run
`merge_intervals()` per band on the concatenation. This pre-merge is mandatory
in every consumer of uint64-keyed data: the dump writer, the
check-edge-dump.py checker, and the merge tool. Segmentation then proceeds per
merged geometry, not per uint64 key.

1. **Endpoints.** `E` = all `start`/`end` values of every interval in every
   `I[r][b]`. Sort; dedupe with the 1e-12 tolerance (same predicate the retired
   per-route `coverage_lines()` writer used). Do NOT
   add 0/1: fractions outside all intervals are unreachable by every
   requirement and are simply not emitted, as today.
2. **Classify.** For each adjacent pair `(s, e)` with `e - s > 1e-12`, take
   `m = (s+e)/2`. For each requirement `r`, find the first band index `i` with
   `contains(I[r][i], m)` (existing `contains()`); attribute value =
   `minutes_r[i]`; verify nesting for all later bands (keep the
   abort). Result: attribute map `A(s,e)`. If `A` is empty, skip the piece.
3. **Coalesce.** Merge adjacent pieces with equal attribute maps and
   `|s_next - e_prev| <= 1e-12` (generalization of the retired writer's
   `pending_minute`/`flush_pending` run-length logic from a single
   `min_minutes` to a map).
4. **Slice.** One `measure_line()` per edge; walk the coalesced breakpoints in
   a single pass, computing each boundary `Point` (via `interpolate()`) **once**
   and sharing it as the last point of piece k and first point of piece k+1.
   This preserves a guarantee the retired per-route writer had —
   `coverage_lines()` sliced all of one edge's pieces against a single shared
   `LineMeasure`, so junction points within one service were bit-identical. The
   shared-point construction carries that guarantee into the multi-requirement
   code (it must hold across cuts introduced by *different* requirements);
   naive independent `slice_line()`
   calls per piece would regress it into hairline gaps/T-joins at z14+overzoom.
5. **Clip.** `clip_line(piece, bounds)` as today (may re-split a piece).
6. **Canonicalize + dedupe.** `canonical_line()` (string form) on each clipped
   piece; insert into the output `std::map<std::string, Piece>`. Whole-edge
   dual digitization is already handled by step 0, so key collisions here are
   rare degenerate cases (sub-slices of *different* edges that coincide after
   slicing/clipping). As a safety net, on collision merge attribute maps by
   **per-key minimum** (a point is reachable in the best band any coincident
   edge gives it). Deterministic and semantically correct.
7. **Group + emit.** Group pieces by serialized attribute map (JSON, sorted
   keys — mirrors `lookup_ids_json` grouping in
   `write_destination_collection()`); one Feature per group, MultiLineString
   members in canonical-key order, features in serialized-attribute-map order.

Distinct attribute maps are bounded by ∏(bands+1) = 4·5·3·2·3 = 360, so the
GeoJSON stays MultiLineString-grouped and small in feature count; tilemaker
splits per tile regardless.

**Size implication of splitting** (informational, measured on the Vilnius
build, §4): per-service coverage today has 128k–153k pieces per route, 712k
piece-lines summed over 5 routes, of which only 243k are unique polylines; at
maximum split granularity (every vertex) the union network has 531k unique
2-point segments vs 1.59M shipped today (3.00× duplication). Union
segmentation lands between 243k and 531k pieces — more pieces than any single
route, far fewer line-kilometres than the 5 routes combined.

---

## 2. Pipeline changes

### 2.1 Helper architecture: per-route routing + separate merge

Keep one `mapgames-valhalla-expand` invocation per route. Merging all routes
into one process run is rejected: `worker` in valhalla-expand.cc caches one
`cost_ptr_t costing` and one `traversal_seconds_cache` per worker, both
costing-specific (walk vs drive traversal seconds differ per edge), and the
program asserts `all requests must use the same costing`. Per-route runs also
keep step gates byte-diffable.

Flow:

1. **Per-route run**: routes, computes `destinations_by_minute` and the
   reachable-edge intervals; writes `destinations-<route_key>-<minutes>.geojson`
   (inspection unchanged) and the **edge-interval dump** (the per-route
   `coverage-<route_key>.geojson` writer is retired).
2. **Merge run** (a mode of the same binary,
   `mapgames-valhalla-expand --merge-network OUT BOUNDS DUMP...
   [--debug-segments FILE]`): reads all 5 dumps, runs §1.3, writes one
   `network.geojson`.

**Dump format** — `work/edges-<route_key>.tsv`, one line per canonical edge,
**sorted by ascending numeric uint64 key** (not lexicographic decimal-string
order — the k-way merge comparator is `uint64_t <`, and the sort order of the
file must match it exactly), ASCII, deterministic:

```
<canonical_key_u64>\t<lon,lat;lon,lat;...>\t<minutes>:<start>-<end>[,<start>-<end>...][|<minutes>:...]
```

- `canonical_key_u64` = `min(edge_id, opposing_edge_id)` (§5.1) — map key
  only.
- Geometry: 1e-7-rounded, **string-canonical orientation** — the orientation
  `canonical_line()` picks today (lexicographically smaller coordinate
  string), NOT id-derived; see §5.1 for why. `%.7f` fixed format.
- Intervals: per band, the `merge_intervals()` output, printed with a fixed
  precision (17 significant digits, matching `std::setprecision(17)` used for
  requests) so the dump round-trips exactly.

The merge tool requires identical geometry for the same key across dumps
(assert; guaranteed by construction — geometry and orientation both come from
`canonical_line()` over the same rounded polyline). **Memory model, stated
honestly:** the input side is a k-way merge over numerically-sorted dumps, but
the tool is **whole-network resident**: §1.3 step 0 must group entries by
geometry string across dumps (a dual-digitized group's uint64 representative
can differ per route, so alignment by uint64 alone is insufficient), and §1.3
steps 6–7 (output canonical-string map + attribute-map grouping) hold the
entire output before the first byte is written. This is a deliberate choice
over spill-per-group temp files:
the tool is a single sequential build-time process, and the resident set is
bounded by the output itself (estimate 1.5–4 GB RSS at full-Lithuania scale —
pieces + strings + grouping maps over a ~150–220 MB GeoJSON). The step-4 gate
(§7) includes an RSS measurement; spilling is the designated fallback only if
measured RSS exceeds 8 GB on the lt-full build. Merge output must not depend
on dump argument order; generate.py still passes them in `ROUTE_SPECS` order
for log stability.

Writer state in valhalla-expand.cc: the legacy per-route writer
(`write_coverage_collection()`, `CoverageLine`/`CoverageLines`, the
`coverage_lines()` band labeling) was deleted at §7 step 7; its segmentation
core — endpoints/midpoint/`contains()`/run-coalescing — lives on, generalized
per §1.3. `DumpEdge` feeds the dump writer; `write_network_collection()`
implements §1.3 step 7.

### 2.2 generate.py / tilemaker

- Module constant `REQUIREMENT_KEYS = tuple(f"{r['service']}_{r['mode']}"
  for r in ROUTE_SPECS)`.
- One archive replaces the legacy per-route tilemaker loop:

```python
def network_tile_config(work: Path) -> dict:
    return {
        "layers": {
            "network": {
                "minzoom": TILE_MIN_ZOOM,          # 6
                "maxzoom": TILE_MAX_ZOOM,          # 14
                "source": str(work / "network.geojson"),
                "source_columns": sorted(REQUIREMENT_KEYS),
                # one MVT coordinate unit per generalized zoom; see §2.3
                "simplify_below": LOW_ZOOM_GENERALIZATION_BELOW,
                "simplify_level": NETWORK_SIMPLIFY_LEVEL,
                "simplify_ratio": 2.0,
                "simplify_algorithm": "visvalingam",
            }
        },
        "settings": common_tile_settings(
            "Mapgames unified access network",
            "Edge-attributed everyday-access bands for all services"),
    }
```

  Output: `access.pmtiles`, source-layer `network`. `geojson.lua` is the
  mandatory empty process file, shared with the destination and places
  archives. (Naming: the file and the `--geojson-process` flag were called
  `coverage.lua`/`--coverage-process`, and `TILE_MIN_ZOOM`/`TILE_MAX_ZOOM`
  were `COVERAGE_*_ZOOM`, until the post-step-7 cleanup renamed them after
  the per-route coverage machinery they were named for was deleted.)
- Destination lookup configs (`destination_tile_config`) and
  `destinations-<route_key>.pmtiles` builds remain the source of point-verdict
  lookup features. In the current tree, the places encoder input is
  `work/places.geojson` (not published); the browser-facing detail data is the
  compact, index-addressed `place-catalog.json` described below.
- Attribute values serialize as JSON integers in `network.geojson` so
  tilemaker types the columns as ints and MapLibre `["get"]` returns numbers.

The edge-interval dumps and `network.geojson` are `work/` intermediates
(tilemaker inputs only, kept out of the published output directory). The
legacy `access-<route_key>.pmtiles` ×5, `coverage-<route_key>.geojson`
intermediates ×5, `coverage_tile_config()`, `coverage_filename()`, the
`access_tiles` metadata key, and the `count_bands` plumbing were all deleted
at §7 step 7, per the no-historical-artifacts policy.

**`network.geojson` is NOT published.** Decision: it stays a `work/`
intermediate (tilemaker input only), like the coverage GeoJSONs it replaced.
Rationale: coverage GeoJSON was deliberately moved out of the published
output; re-publishing a 150–220 MB raw export (plus the gz/br/zstd
sidecars `compressDrvWeb`'s `extraFormats = ["geojson", "pbf"]` would generate
for it, and the `.etag` sidecar from `writeEtags`) would reverse that decision
with no current consumer — the published access artifact is `access.pmtiles`.
Consequently metadata carries no `export` key and default.nix publishes only
the generated JSON/PMTiles artifacts (the GeoJSON lives in `work/`, not
`generated/`).

The same publication rule now applies to `places.geojson`: it is a tilemaker
input in `work/`, not a browser API. `places.pmtiles` remains the rendered-dot
archive, with one canonical z14 pyramid that MapLibre overzooms at higher
street zooms; it carries no duplicated z9–13 point pyramids. Human-facing
place details are projected into
`place-catalog.json`, an array in global `place_index` order containing only
stable `place_id`, service/name/brand/kind, address, opening-hours, phone, and
point-coordinate fields.
Destination lookup tiles already carry those integer indexes, so the dialog
does not need the full GeoJSON wrappers or unrelated OSM tags.

**metadata.json** replaces `access_tiles` with:

```json
"access_network": {
  "file": "access.pmtiles",
  "layer": "network",
  "format": "PMTiles v3 with Mapbox Vector Tiles",
  "min_data_zoom": 6, "max_data_zoom": 14,
  "requirements": [
    {"key": "coffee_walk", "service": "coffee", "mode": "walk", "minutes": [5,10,20]},
    ...
  ]
},
"destination_tiles": [
  {"service": "coffee", "mode": "walk",
   "file": "destinations-coffee-walk.pmtiles",
   "layers": {"5": "destinations_5", "10": "destinations_10", "20": "destinations_20"}},
  ...
],
"places": {
  "file": "places.pmtiles",
  "catalog_file": "place-catalog.json",
  "layer": "places",
  "min_data_zoom": 14, "max_data_zoom": 14
}
```

The current low-zoom fast path supersedes that original single-layer config:
the raw source serves z14, while a fixed z10-grid skeleton writes to the
same MVT layer at z6–13. See `docs/lowzoom-fastpath.md`; the grid zoom and the
raw/skeleton serving handoff are intentionally separate constants.

`services` (labels, presets, place_count) is unchanged — the front-end
requirements model keys off it.

**Migration/compat:** index.html and the data are one derivation (`www` wraps
`data` in default.nix) and deploy atomically, so tile/catalog indexes always
come from the same build. Shared marker links use stable place IDs rather than
those build-local indexes, so a later catalog reorder cannot retarget a link.
Destination inspect tiles keep
their names, layer names (`destination_layer_name()`), and schema
(`DESTINATION_SOURCE_COLUMNS`), so the geographic verdict path is unchanged.
The current dialog opens a loading state immediately, fetches
`metadata.places.catalog_file` only when a rendered marker or passing
destination needs details, and indexes the returned array with the tile's
`place_index`/`lookup_ids` values. A padded dot click selects only the nearest
marker, then snaps the one inspection origin (all service lookups, displayed
coordinates, and sharing state) to that catalog place. It shares the
URL-encoded stable identity as `#place=<place_id>` and resolves it through a
catalog-wide, duplicate-rejecting identity lookup on restore. A removed place
therefore fails closed instead of silently opening another marker. An ordinary
map point shares separately as exact `#at=<lon>,<lat>`.

### 2.3 Simplification per zoom (visually lossless only)

Quantization-bounded, zoom-scaled tolerance (landed at §7 step 8). Constraint
from the priority re-weight: simplification must be visually lossless at the
zooms users look at; no fidelity is traded for bytes.

Tilemaker stores geometry in (lon, latp) projected degrees — the same uniform
space as the web-mercator tile grid — so at zoom z one MVT coordinate unit at
the default tile extent 4096 spans `360 / (4096·2^z)` projected degrees in
both axes (≈ 0.34 m at z14, 22 m at z8, 87 m at z6 ground distance at
lat 55°). The tile encoder rounds every vertex to that grid anyway, so a
Visvalingam tolerance at or below the tile's coordinate quantization step
cannot produce displacement meaningfully beyond what encoding already
introduces. Concretely:

- z14: raw geometry.
- z11–13: the fixed z10-grid skeleton, overzoomed without further tilemaker
  simplification.
- z6–10: the same skeleton, with effective tolerance = exactly one MVT
  coordinate unit at each zoom.
  Mechanism (R6 resolved against the pinned 3.1.0 source): tilemaker scales
  the configured level per zoom —
  `simplifyLevel *= pow(simplifyRatio, (simplifyBelow-1) - zoom)`
  (src/tile_worker.cpp:438), with `simplify_ratio` defaulting to 2.0
  (src/shared_data.cpp:317, set explicitly in our config). The ratio-2
  doubling per zoom step down matches the coordinate unit's own doubling, so
  anchoring `simplify_level = 360/(4096·2^10)` ≈ 8.583e-5 (one unit at z10;
  `NETWORK_SIMPLIFY_LEVEL` in generate.py) holds the tolerance at one unit
  across all of z6–10. The zoom-banded-duplicate-layer fallback designed for
  the case where `simplify_ratio` was absent is moot and was not built.

Gate evidence (Vilnius c12, 2026-07-18, §7 step 8): `network.geojson`
byte-identical to the pre-change run; only 18 tiles differ between the
pre/post archives, all at z6–10 (z11–14 byte-identical); per-tile feature
counts unchanged at every zoom (no dropped features), vertex counts
−7.3% (z6) to −29.4% (z9); screenshot A/B at z6–z10 in bands and score
modes, same camera, against the pre-change output showed no visible line
displacement, corridor thinning, or dropout — remaining pixel deltas are
sub-pixel antialiasing shifts plus the draw-order blending noise that two
builds of *identical* config already exhibit (tilemaker's multithreaded
encoder is not byte-deterministic; measured as the A/B noise floor).
`access.pmtiles` 87,881,187 → 85,923,162 bytes (−2.2%, informational).

---

## 3. Front-end changes

### 3.1 Sources and layers

`addAccessSources()` is replaced by `addAccessNetwork()`:

- One vector source `access` → `pmtiles://…/access.pmtiles`.
- Destination sources: built from `metadata.destination_tiles` instead of
  `tile.destination_file` inside `access_tiles`; the per-preset records that
  `runtimeLayers` holds today survive as a `destinationRecords` map keyed by
  the existing `presetKey(service, mode, minutes)` — `inspectLocation()`,
  `destinationRecordsForRequirements()`, `failedDestinationSources`, and the
  whole inspect dialog flow are otherwise untouched.
- Four style layers over source-layer `network`, bottom to top:

| id | view | type | notes |
|---|---|---|---|
| `access-context` | intersect | line | union of selected requirements, subordinate dark gray — shows "reachable by something you selected" under the intersection |
| `access-score` | score | line | color by client-computed score |
| `access-bands` | bands | line | color by focused requirement's band value |
| `access-intersect` | intersect | line | solid high-contrast |

Only the active view's layers are `visibility: visible`; `refreshMap()` swaps
visibility and rebuilds filters/paint via `map.setFilter` /
`map.setPaintProperty`. Because all views read the same tiles, view and
threshold switches are pure restyles — no tile fetches — which is the fix for
the current change-blindness (threshold presets flipping whole sources).

`corridorLineWidth(mode)` stays. Width source per view: bands → the focused
requirement's mode; intersect/score → `"walk"` if any selected requirement is
walk, else `"drive"` (the narrower corridor is the honest one for a mixed
selection; a drive-width ribbon would overclaim walk coverage). Record this
rule in a comment; it is a judgment call (risk R7).

### 3.2 The three view modes

State: `serviceState` (per-service `enabled` + `preset`) is unchanged; add one
global `viewMode ∈ {"bands","intersect","score"}`.

**Selection cardinality: N = |R| ∈ 0..4, not 5.** There are 4 services, and
`serviceState` holds exactly one `preset` per service — supermarket walk and
drive are *alternatives* selected via that single preset (see the
`state.preset = target.dataset.preset` handler and `selectedPreset()`), so at
most one supermarket requirement is active at a time. This model is kept
deliberately: "supermarket reachable within my chosen preset" is one
requirement in the product's mental model, the inspect dialog already renders
one verdict card per service, and allowing both supermarket modes at once
would complicate state, URL encoding, and score semantics with no user story
behind it. The *data* still carries all 5 requirement keys (§1.1), so
revisiting this later is a front-end-only change. Every N-dependent surface
below (score ramp, legend chips, expressions) uses N ≤ 4.

**Mode preference vs. effective mode.** `viewMode` stores the user's
*preference* and is never overwritten by selection changes; rendering uses
`effectiveViewMode(selection, viewMode)`:

- |R| = 0 → no effective mode: all four access layers hidden (every view
  renders nothing), legend hidden, collapsed chip row and status show
  "No requirements selected" (today's behavior preserved).
- |R| = 1 → `bands` regardless of preference (intersect/score of one
  requirement degenerate to it).
- |R| ≥ 2 and preference = `bands` → coerced to `intersect`; the switcher
  shows `bands` disabled with a hint ("pick one service to see its time
  bands") — deliberately NOT re-enabling multi-service band compositing,
  which is the failure mode this rework removes.
- |R| ≥ 2 otherwise → the preference (`intersect` default; it is the headline
  feature).

Because the preference survives coercion, toggling a second service on and
off round-trips: bands → intersect → bands without user re-selection. The URL
hash records the *effective* mode (§3.4), so shared links reproduce what the
sharer saw.

**Bands** (`access-bands`), focused requirement key `K`, bands `M = [m1<m2<…]`:

```js
filter: ["has", K],
paint: { "line-color": ["match", ["get", K], m1, C1, m2, C2, m3, C3, FALLBACK],
         "line-opacity": 0.9, "line-width": corridorLineWidth(focusedMode) }
```

Pieces are disjoint by construction (each carries exactly one band value), so
nesting renders without overdraw or blending; dark→light by minutes (§3.3).
Preset buttons keep their role (they define the requirement used by
intersect/score/inspect); in bands view the legend marks the active preset's
band, and all bands render simultaneously — replacing the one-threshold-at-a-
time preset flipping.

**Intersection** (`access-intersect` + `access-context`), selected requirements
`R` with chosen minutes `t_r`:

```js
// access-intersect
filter: ["all", ...R.map(r => ["all", ["has", r.key], ["<=", ["get", r.key], r.t]])]
paint:  { "line-color": "#172033", "line-opacity": 0.95 }   // ink, no blending
// access-context
filter: ["any", ...R.map(r => ["all", ["has", r.key], ["<=", ["get", r.key], r.t]])]
paint:  { "line-color": "#596579", "line-opacity": 0.9 }
```

One solid layer — always-true requirements (hospital 60-drive) contribute a
boolean `true` to the `all`, not another translucent wash; the "dominates the
blend" pathology is structurally gone.

**Glimpse score** (`access-score`):

```js
const score = ["+", ...R.map(r =>
  ["case", ["all", ["has", r.key], ["<=", ["get", r.key], r.t]], 1, 0])];
filter: [">=", score, 1],                 // 0 = basemap, not drawn
paint: { "line-color": ["match", score, 1, S1, 2, S2, ..., N, SN, "rgba(0,0,0,0)"] }
```

Expressions are rebuilt in JS per `refreshMap()` with the current selection;
N = |R| ∈ 1..4 (one requirement per service, §3.2).

### 3.3 Palette (CVD-safe, light basemap)

Replace `serviceStyles` base hues with the Okabe-Ito subset (committed):
coffee `#E69F00`, hospital `#D55E00`, supermarket `#009E73`, fuel `#0072B2`.
Marker (`circle-stroke-color`) variants independently darken the same hue;
they are not entries in the time-band ramps. The intentionally quiet dots
share one circle shape, with textual service identity provided by the clicked
place chip. If the product later requires at-a-glance service classification,
use distinct service glyphs instead of adding concentric strokes that would
restore the dense-view clutter.

- Band ramps: discrete lightness steps within each service hue, darkest =
  smallest minutes. The steps are intentionally wider than the original
  near-continuous gradients: adjacent rendered colors have an OKLab distance
  of at least 0.10, lightness strictly increases with minutes, and every
  90%-opacity stroke retains at least 3:1 contrast against white, paper,
  forest, wetland, and road reference fills. The map, expanded legend, and
  collapsed gradient use the same RGBA colors:
  coffee 5/10/20 → `#3F2800 / #654100 / #8D5C00`;
  hospital 15/30/45/60 → `#350900 / #5B1900 / #842C00 / #B04700`;
  supermarket 10/20 → `#003D2C / #006D50` (drive-10 single band `#006D50`);
  fuel 10/20 → `#002D49 / #005E90`.
- Intersection: ink `#172033` at 0.95 opacity — outside every service hue,
  maximal contrast on the light Protomaps flavor, hue-free hence CVD-neutral.
- Score: an identity-neutral single-hue purple sequence, light→dark with
  count, explicitly tabulated for N=1..4. It deliberately avoids every
  service hue: with green supermarket and blue fuel selected, a green/blue
  score ramp misleadingly reads as *which* service is reachable rather than
  *how many*. Monotonic lightness preserves the order under color-vision
  deficiencies; the explicit tables keep legend and paint meanings fixed:
  N=1 → `#22062F`; N=2 → `#775A89 / #22062F`; N=3 →
  `#775A89 / #4B2F5B / #22062F`; N=4 →
  `#775A89 / #593D6A / #3C214C / #22062F`. Score strokes render at 0.9
  opacity. The N=4 adjacent OKLab distances are 0.105/0.107/0.105, and every
  rendered step retains at least 3:1 contrast against the white, paper,
  forest, wetland, and road reference fills.
- Map paint, expanded legend swatches, and collapsed-summary swatches use the
  same RGBA values for bands, intersection, context, and score; opacity must
  not be dropped when rendering either legend.
- All bands render at 0.9 opacity. The old 0.5 drive-outer exception made the
  most geographically widespread band nearly disappear on pale landcover and
  made its opaque legend swatch misrepresent the map; the ordered lightness
  ramp now supplies the intended outer-band de-emphasis without sacrificing
  visibility.

### 3.4 Panel, mobile, legend

- **View switcher:** a 3-option segmented control (`role="radiogroup"`,
  buttons ≥2.75rem touch targets, matching the existing coarse-pointer rules)
  placed in `.panel-content` between `.quick-actions` and `#service-list`, on
  both desktop and the mobile bottom sheet. Labels: "Time bands" / "Meets all"
  / "How many". Disabled options get `disabled` + title hint per §3.2.
- **Quick views** (`applyQuickView`): "Coffee & food only" → bands(coffee);
  "Everyday walk" → intersect(coffee walk:10, supermarket walk:10); "All
  services" → score(all four services, default presets); "Clear" unchanged.
- **Legend, expanded:** a legend block under the switcher rendered by a new
  `renderLegend()` from `refreshMap()`: bands → the focused service's ramp with
  minute labels and the active preset outlined; intersect → ink swatch "meets
  all N" + gray swatch "meets some"; score → N-step ramp with counts.
- **Legend, collapsed mobile (current gap):** `#panel-selection-summary`'s
  plain text is replaced by a chip row: one mini-swatch chip per active
  requirement plus a mode chip (bands: 3-step gradient chip; intersect: ink
  chip "all 3"; score: mini-ramp chip). Tapping the row expands the panel
  (existing `setPanelCollapsed(false)` path). Chip row participates in the
  existing `ResizeObserver`/`--mobile-panel-height` layout math — no new
  layout mechanism.
- **Inspect dialog:** destination layers and `queryRenderedFeatures` remain the
  geographic verdict path. The current dialog opens its loading state at click
  time and resolves human-facing details through the compact catalog. Its
  per-requirement verdicts are the ground truth the map views visualize; keep
  them in lockstep by deriving both from `activeRequirements()` +
  `selectedPreset()` as today.
- **URL state:** extend the hash with `&mode=bands|intersect|score` (the
  `view=` hash key already carries the camera in the view-state hash, so the
  view mode travels under `mode=`): `inspectionHash()` appends it;
  `applyLocationHash()` parses and validates it (unknown value → error via
  `reportMapError`, matching current strictness). Absent `mode` → derived
  default (§3.2), so existing shared links keep working.

---

## 4. Size / performance analysis (informational — not decision-driving)

Measured on the pre-unified pipeline with hospital_drive at [20,30] (the
analysis basis for this design; the hospital 60-band and the subsequent
[15,30,45,60] re-banding, both added 2026-07-18, are measured at the end of
this section):

**Vilnius** (`bbox 24.95,54.52,25.55,54.92`, scratchpad `vilnius/generated/`):

| artifact | size |
|---|---|
| access-{coffee-walk,supermarket-walk,supermarket-drive,fuel-drive,hospital-drive}.pmtiles | 58.4 + 58.3 + 68.6 + 79.4 + 80.6 = **345 MB** |
| coverage-*.geojson ×5 (build intermediates in `work/`, not deployed) | **51.7 MB** |
| destinations-*.pmtiles ×5 (unchanged by this design) | 558 MB |
| basemap lithuania.pmtiles | 13.1 MB |

Coverage geometry, Vilnius: per-route 128k–153k pieces / 421k–493k points;
712k piece-lines summed vs 243k unique canonical polylines; 1,593,266 2-point
segments shipped vs 530,745 unique — **3.00× geometry duplication**. Polyline
membership across the 5 routes: {1 route: 52k, 2: 67k, 3: 35k, 4: 25k, all 5:
64k}.

**Full Lithuania** (`lt-full/generated/`): access pmtiles 220.6 + 863.7 +
428.2 + 188.7 + 788.0 MB = **2.49 GB**; coverage geojson intermediates
**295 MB** (hospital 932k pieces / 4.19M points, fuel 902k/3.88M);
destinations pmtiles 2.30 GB; basemap 176 MB; places PMTiles ~0.55 MB. The
current compact `place-catalog.json` is also published (about 1.0 MB
uncompressed for the 4,398-place snapshot, including stable share IDs), while
`places.geojson` remains a
build intermediate. Deployed set
(current tree — coverage geojsons are `work/` intermediates and not
published): ≈ **4.97 GB** — acceptable under the new budget.

**Unified layer estimate.** Geometry: ÷3.0 dedup, ×~1.2–1.5 for union-split
pieces and per-piece attribute tags (MVT deduplicates key/value tables per
tile; a piece costs ~2 varints per present requirement on top of geometry).
Expected: Vilnius `access.pmtiles` ≈ 130–190 MB (vs 345 MB across 5);
Lithuania ≈ 1.0–1.3 GB (vs 2.49 GB). `network.geojson` (unpublished `work/`
intermediate, §2.2) ≈ 25–35 MB Vilnius / 150–220 MB Lithuania. Verify after
step 5; these are estimates, and per the priority re-weight a miss high is
not a design failure.

**Tile-fetch behavior (the UX-relevant part).** Today, "All services" fetches
4 access sources per viewport tile (one per enabled service's active preset;
all 5 sources are added but only visible layers trigger fetches) and inspect
adds destination sources; every threshold flip switches filters across 15
pre-added coverage layers but each enabled service still costs its own
source's tiles. New: exactly 1 access
fetch per viewport tile regardless of selection; enabling services, switching
thresholds, and switching view modes cause **zero** additional tile traffic —
instant restyle of already-loaded buffers. Individual tiles are larger than
any single current access tile but smaller than the five combined; z6–8 tiles
shrink further under §2.3 without visible change. Restyle cost (filter
re-evaluation per loaded tile) is the thing to measure on mobile (risk R2).

**Helper CPU/RAM (with §5 piggybacks).** `canonical_line()` +` point_key()`
build multi-hundred-byte strings per interval insertion (per edge × per minute
band × per request that reaches it) — profiling showed these string keys
dominate merge CPU+RAM. The uint64 keying removes string construction from the
hot path entirely (strings remain only in the once-per-output-piece
canonicalization). GraphReader cache cap bounds per-worker RAM (§5.2).

**Hospital 60-band (added 2026-07-18, measured at c12).** The 3600-second
reverse expansion runs over the whole country graph from every hospital, but
the graph itself is small (193 MB of Valhalla tiles — under even the 256 MiB
per-worker cache floor of §5.2), so cost grows with settled edges, not with
cache thrash. Hospital-drive route phase: Vilnius (40 origins) 21.9 s →
34.2 s; full Lithuania (190 origins) 69 s → 155 s (57 s routing + 94 s
interval union). Merge (lt-full): 19 s / 2.30 GiB peak RSS → 24 s / 2.48 GiB
— far under the 8 GB spill threshold (§2.1). `access.pmtiles`: Vilnius
85.9 → 86.6 MB (+0.75%); lt-full 747 → 819 MB (+9.7%). `network.geojson`
lt-full 116 → 125 MB. The 30-min bands already reach 894k of the 932k
hospital-reachable edges at lt-full — the 60-band adds only 38k
edges (+4%), mostly relabeling coverage that existed. Before the compact
accumulator described below, the expansion helper's peak RSS was
`RSS(K) ≈ 9.8 GiB + 1.14 GiB per worker` (measured at K = 2/6/12: 12.1,
16.6, ~23.4 GiB). Per-worker interval maps and edge caches converged to the
country-wide reachable set ×3 bands on top of a worker-count-independent
union/output floor. That historical spike motivated the accumulator rewrite;
it is not the current resource model. Behavioral note, measured on
Vilnius: raising the contour cap from
1800 s to 3600 s changed the 30-band intervals of exactly 1 edge of 182k
(an isochrone boundary-settlement artifact; nesting still holds — the 60
band covers it).

**Re-banding to [15,30,45,60] (2026-07-18, measured at c12; K = 2 clamp in
both columns).** Replacing the 20 band with 15 and adding 45 costs little:
the 45 band rides the same 3600 s Dijkstra the 60 band already pays for, and
15 only tightens the innermost threshold. Hospital-drive route phase:
Vilnius 71 s → 91 s; full Lithuania 269 s → 303 s. Expansion-helper peak
RSS on the lt-full hospital phase: 12.1 → 16.3 GiB at K = 2. This is the
pre-rewrite four-map measurement; it no longer predicts the compact
cross-band representation below. Merge (lt-full):
21.2 s / 2.57 GiB peak. `access.pmtiles`: Vilnius 86.6 → 85.6 MB, lt-full
819 → 810 MB (both ≈ −1.2%: the 15 band relabels fewer edges than 20
reached, outweighing the new 45 attribute); `network.geojson` lt-full
125.4 MB (1344032 output pieces vs 1339340). Gates green on Vilnius and
full Lithuania: tile `hospital_drive` values exactly {15,30,45,60},
check-edge-dump nesting clean, check-network-segments exact,
merge byte-deterministic across reruns.

**Compact cross-band accumulator + direct PBF (2026-07-18, current).** One
map node now owns all minute bands for a canonical edge. For routes with at
most 256 destinations, full `[0,1]` memberships are route-ordinal bitsets;
only fractional contour-frontier intervals remain individual records. Larger
routes use chunked 12-byte full records instead of a global-width bitset, so
2,441 coffee destinations cannot turn the hospital optimization into a new
memory spike. Canonical geometry is shared with the edge cache. Worker maps
are k-way merged for geometry extraction and the edge dump, and attribute
grouping keeps line references rather than geometry copies. Valhalla expansion
is consumed from its protobuf `Api` with a compact sorted predecessor index,
avoiding the expansion GeoJSON string, RapidJSON DOM, and country-wide
`map<uint64_t, Edge>`. Destination bands use separately bounded concurrency:
two maps may coexist under the selected Nix policy, instead of materializing
all bands at once.

The exact full-Lithuania hospital helper measurements (190 origins,
15/30/45/60, existing graph tiles) are:

| helper / routing workers / arenas / output workers | wall | peak RSS |
|---:|---:|---:|
| old / 2 / glibc default / 1 | 323.6 s | 16.32 GiB |
| compact / 2 / 2 / 1 | 150.4 s | 2.78 GiB |
| compact / 8 / 8 / 1 | 84.3 s | 8.22 GiB |
| compact / 8 / 8 / 2 | **77.2 s** | **8.57 GiB** |
| compact / 9 / 9 / 1 | 91.7 s | 9.01 GiB |

Eight routing workers and two output workers are the selected caps: the full
run stays 1.43 GiB below the 10 GiB RSS budget and is 4.19× faster than the old
helper. `default.nix` owns both worker-count policies
(`expansionConcurrencyCap = 8`, `expansionOutputConcurrencyCap = 2`), computes
each effective count against the general pipeline concurrency, sets allocator
arenas to the larger cap, and passes a wrapped helper plus the resulting
counts to `generate.py`; Python contains no route-size or memory policy. All
four hospital destination GeoJSON files and the edge TSV are byte-identical to
the old implementation at every measured worker count. The independent
edge-dump checker reports 932,024 entries and 996,130 valid derived pieces,
and the five-route merged `network.geojson` is also byte-identical. The
2,441-destination sparse fallback improved the coffee helper from 33.0 s /
6.01 GiB at 12 workers to 20.6 s / 2.91 GiB at the selected caps.

---

## 5. Efficiency piggyback (same series, same code)

### 5.1 uint64 canonical keys for the hot maps

Key all accumulation maps (`DestinationEdges` per worker/minute, the
`DumpEdge` map) by
`canonical_id = min(edge_id, opposing_edge_id)` (uint64). The uint64 is the
**map key only** — stored geometry keeps the string-canonical orientation.

- **Stored orientation stays string-canonical.** Deriving orientation from the
  id (e.g. "as seen by the smaller edge_id") would flip the slicing frame for
  roughly half of all edges relative to today: `slice_line()` fractions,
  `measure_line()` cumulative sums, and interval flips would run over reversed
  point orders, and float non-associativity plus the 1e-12/1e-7 tolerances
  make reversed-frame results non-byte-identical. Instead: on a worker's
  first encounter of a `canonical_id`, call `canonical_line()` **once** and
  cache `{key_string, canonical geometry}` per canonical_id. The `reversed`
  flag, however, is a property of each **directed** edge, not of the pair:
  expansions request `"skip_opposites":false` (valhalla-expand.cc:251), so
  BOTH directed edges of a pair arrive — with opposite line orientations and
  therefore opposite fraction frames. A single per-pair flag cached at first
  encounter would flip intervals wrongly for the other directed edge on
  roughly half the network. So each directed edge id gets its **own** flag,
  derived by comparing its incoming rounded line's direction against the
  cached canonical geometry (first/last endpoint comparison suffices when the
  endpoints differ; when the incoming line's first and last rounded points
  are EQUAL — a closed-loop edge, which is generally not palindromic — fall
  back to full point-sequence comparison against the cached canonical
  geometry, i.e. the first differing point pair decides the flag, matching
  `canonical_line()`'s full-string comparison today. Only for true
  palindromes (forward sequence == reverse sequence) is the flag ambiguous,
  and there today's `canonical_line()` has the same latent ambiguity — its
  output is direction-independent — so parity with current behavior is
  acceptable) and cached per directed edge id. Insertions flip intervals
  `{1-end, 1-start}` iff that directed edge's flag is set, exactly as
  `add_destination_interval()` does today for `canonical.reversed`. Geometry
  is bitwise-independent of which direction was seen first (assert equality
  on re-insert); the slicing frame is unchanged from today by construction.
- Opposing lookup: `reader.GetOpposingEdgeId(GraphId(edge.id), tile)` — already
  called in `reverse_edge_traversal_seconds()` for every non-origin edge and it
  already throws on absence. Replace the per-worker `traversal_seconds_cache`
  with `std::map<uint64_t, EdgeCacheEntry>` where

  ```cpp
  struct EdgeCacheEntry {
    uint64_t opposing;                  // filled on first touch (any edge)
    std::optional<double> reverse_secs; // filled lazily, non-origin use only
    // plus the cached canonical_line result: key string, geometry, reversed
  };
  ```

  `opposing` is computed on first touch (origin edges included — cheap,
  needed for the map key). `reverse_secs` is **not** filled for origin edges
  (`pred_id == kInvalidGraphId` — no traversal seconds exist there); it is
  filled lazily on the first *non-origin* use, with the existing
  `(seconds > 0) && isfinite` validation performed at fill time. A later
  non-origin hit on an entry first created by an origin edge therefore
  computes and validates rather than reading an uninitialized value — the
  `std::optional` makes bypassing the validation unrepresentable.
- **Preserving byte-identical output:** string keys today merge distinct edge
  pairs that share identical rounded geometry *before* `merge_intervals()`;
  uint64 keys keep them separate. Therefore every consumer performs the
  geometry-string pre-merge of §1.3 step 0 (group by cached `key_string`,
  concatenate interval lists, then `merge_intervals()`) before any band logic
  or output, and the output stage groups by the string key (per-key attribute
  min on residual collision, §1.3 step 6). Net effect: `canonical_line()`
  runs once per unique edge per worker plus once per output piece, instead of
  once per interval insertion; emitted bytes unchanged. This is what makes
  step 1 of §7 a byte-diff-gated refactor rather than a behavior change.
- Verification item: assert no shortcut edges appear in the expansion
  (`DirectedEdge::is_shortcut()` via the already-open tile); a shortcut's
  geometry spans several base edges and would break the 1:1 assumption between
  canonical id and canonical polyline (risk R5).

### 5.2 Cap per-worker GraphReader cache

Each worker constructs its own `valhalla::baldr::GraphReader` from
`config.get_child("mjolnir")`; the Valhalla default `mjolnir.max_cache_size`
is 1 GiB, so N workers can hold N GiB of tile cache. Cap it in the helper
(not in generate.py's valhalla.json, which `valhalla_build_tiles` also
consumes): after `valhalla::config(config_path)`, before spawning workers:

```cpp
auto mjolnir = config.get_child("mjolnir");           // copy per program run
mjolnir.put("max_cache_size",
            std::max<uint64_t>(256ull << 20, (4096ull << 20) / worker_count));
```

and construct each worker's GraphReader from that copy. 256 MiB floor holds
the working set for a Lithuania-sized graph; caching affects only speed, never
results, so this is byte-diff safe. Log the chosen value once at startup.

---

## 6. Determinism

Invariant to preserve: byte-identical output regardless of thread count and
scheduling. Today this holds because every output path funnels through ordered
`std::map`s and explicit sorts: workers grab requests via `next_request.fetch_add`
(nondeterministic assignment), per-worker maps are merged in worker-index order
into `std::map`s, interval vectors arrive in nondeterministic order but
`merge_intervals()` sorts them and `normalize_lookup_ids()` sorts+uniques
lookup ids; iteration for writing is map-ordered.

The new pipeline preserves it by the same discipline:

1. Per-worker uint64-keyed maps: `std::map<uint64_t, …>` (ordered); merged
   across workers in worker-index order; stored geometry and orientation come
   from `canonical_line()` (string-canonical, §5.1) and are therefore
   insertion-order-independent (asserted on re-insert).
2. Dump: written per uint64 key (no geometry pre-merge — a dual-digitized
   group's uint64 representative could differ across routes when a route
   reaches only one member, so the pre-merge of §1.3 step 0 belongs in every
   *consumer*, never in the dump itself); intervals per band pass through
   `merge_intervals()` before writing; lines written in ascending numeric
   uint64 key order (matching the merge comparator, §2.1); fixed numeric
   formatting (`%.7f` geometry, 17 significant digits for fractions). Gate:
   dumps from threads=1 and threads=N runs are byte-identical. Note that
   uint64 edge ids are stable only within one graph build (Valhalla assigns
   them per `valhalla_build_tiles` run), so comparing dumps across graph
   rebuilds is meaningless — compare post-step-0 geometry-string groupings or
   `network.geojson` instead.
3. Merge tool: single-threaded k-way merge over sorted dumps; endpoint dedup
   uses the same first-wins 1e-12 tolerance as `coverage_lines()`; output maps
   keyed by canonical string; feature groups ordered by serialized
   attribute-map JSON with sorted keys (same trick as `write_json(...,
   sort_keys=True)` in generate.py and `lookup_ids_json` grouping). No
   floating-point accumulation across edges — all per-edge computation.
4. tilemaker/metadata: unchanged determinism story (`write_json` sorts keys;
   tilemaker invocation is unchanged in kind).

Gate for every step in §7: build Vilnius twice with `concurrency` 1 and 4 and
byte-diff every artifact in `generated/`.

---

## 7. Phasing

Each step is a separate reviewed commit; the Vilnius byte-diff harness
(rebuild `generated/` and diff against the previous step's committed baseline)
is the spine. "Reviewer" = context-free adversarial reviewer per standing
policy.

1. **uint64 accumulation keys (§5.1).** Pure refactor.
   *Gate:* all Vilnius artifacts byte-identical to pre-change baseline; also
   identical across threads=1 vs 4. Log routing/merge phase timings before and
   after.
   *Reviewer checks:* stored orientation is string-canonical (uint64 is map
   key only — no slicing-frame change; §5.1); `reversed` is derived and cached
   **per directed edge id**, not per canonical pair — both directed edges of a
   pair arrive (`skip_opposites:false`) with opposite fraction frames, and the
   opposite edge must get the opposite interval flip; geometry-string
   pre-merge before `merge_intervals()` reproduces today's dual-digitized-edge
   merge (construct the case mentally or by fixture); `EdgeCacheEntry` lazy
   `reverse_secs` — an entry first created by an origin edge must compute and
   validate seconds on later non-origin use, never read an unset value; the
   shortcut assert is present and actually reachable.
2. **GraphReader cache cap (§5.2).**
   *Gate:* byte-identical; `/usr/bin/time -v` peak RSS recorded before/after
   at concurrency 4.
   *Reviewer checks:* cap applied only in the helper; per-worker arithmetic;
   no mutation of the shared config used elsewhere.
3. **Edge-interval dump emission.** Helper writes `edges-<route_key>.tsv`
   alongside (not instead of) today's coverage output.
   *Gate:* legacy artifacts byte-identical; dump byte-identical across thread
   counts; a checker script re-derives `coverage-<route_key>.geojson` from the
   dump alone (reimplementing §1.3 for a single service degenerates to today's
   `coverage_lines()`) and byte-diffs it against the helper's own output — a
   full semantic round-trip proof. All dump comparisons assume one shared
   graph build: uint64 edge ids are stable only within a single
   `valhalla_build_tiles` run, so cross-rebuild dump diffs are meaningless —
   compare post-step-0 geometry groupings or `network.geojson` across rebuilds
   instead.
   *Reviewer checks:* dump precision round-trips; nesting invariant enforced
   at dump time; ascending numeric uint64 sort (not decimal-string order); the
   checker performs the §1.3 step-0 geometry-string pre-merge before band
   logic; the checker is independent code, not a call into the same functions.
4. **Merge tool → `network.geojson`** (new artifact alongside old ones).
   *Gate:* determinism (two runs, diff); semantic equivalence **in fraction
   space, before interpolation/rounding** — geometry-space comparison against
   legacy outputs is undecidable here: cross-service boundary cuts split
   unified pieces at fractions no single-service output contains (64,025 of
   243,282 unique Vilnius polylines appear in all 5 routes), and interpolated
   cut points are re-rounded to 1e-7, so no geometry-space normalization can
   restore set equality. Instead the merge tool emits (behind a
   `--debug-segments` flag) its **pre-slicing segmentation table**: the
   classified pieces `(geometry_key, s, e, attribute map)` as exact doubles,
   keyed by the canonical geometry **string** — uint64 representatives differ
   per route (§2.1/§6), so the string is the only cross-route join key. The
   gate checker is an **independent re-execution of §1.3 steps 0–3** from the
   dumps alone (its own step-0 geometry-string grouping, endpoint collection,
   1e-12 first-wins dedup, midpoint classification, coalescing — separate
   code, no shared functions), compared for **exact equality** against the
   debug table. Note this is deliberately NOT "compare the per-(r,b) union of
   pieces back to the dump's `I[r][b]`": the 1e-12 first-wins endpoint dedup
   can absorb an `I[r][b]` endpoint into a near-but-unequal foreign
   endpoint, legitimately shifting a union boundary by ≤ ~2e-12, so exact
   equality against the dumps can fail even when the tool is correct.
   Re-executing the same deterministic algorithm and demanding exact equality
   is decidable and covers classification, nesting, and coalescing.
   Slicing/rounding downstream of this point is covered by step 3's byte-diff
   round-trip and needs no second geometry gate. Note: the merge *tool's*
   slicing/emit stages (§1.3 steps 4–7) are new C++ verified by inspection
   plus the determinism gate — step 3's byte-diff round-trip exercised the
   independent checker's single-service slicing, not this code path.
   *Reviewer checks:* shared boundary points (no per-piece re-slicing);
   §1.3 step-0 geometry pre-merge across dumps (uint64 alignment alone is
   insufficient — R1/§2.1); attribute-min merge on residual canonical-string
   collision; empty-attribute pieces skipped; tolerance constants identical
   to legacy; the fraction-space checker is independent code; measured peak
   RSS on Vilnius recorded and extrapolated to lt-full against the 8 GB
   spill threshold (§2.1) — the tool is whole-network resident by design,
   so the check is a measurement, not a streaming-property proof.
5. **Tile it — strictly ADDITIVE.** generate.py builds `access.pmtiles` and
   adds the new metadata keys (`access_network`, `destination_tiles`) while
   **keeping** the old ones: `access_tiles` stays in metadata.json and all
   five `access-<route_key>.pmtiles` are still built and published. This is
   load-bearing, not belt-and-braces: the deployed `addAccessSources()` reads
   `metadata.access_tiles` unconditionally (index.html:811) and the data
   derivation can deploy independently of any front-end commit, so a
   metadata-only cutover here would break the live site. Old keys and
   archives are removed only at step 7, after step 6's front-end is deployed.
   *Gate:* build green; `pmtiles show`/tile dump confirms layer `network`,
   integer attributes, zoom range 6–14; spot-render a z13 tile; the deployed
   (pre-step-6) index.html loads against step-5 metadata with no errors.
   *Reviewer checks:* both old and new metadata keys present and correct;
   `source_columns` generated from `REQUIREMENT_KEYS` (no hand list);
   metadata advertises exactly what exists; `write_json` sort_keys
   determinism.
6. **Front-end rework (§3).** New source/layers/views/legend/URL state; delete
   old access-source usage, `addCoveragePair`, and the `count_bands`/
   `one`/`two_plus`/band-swatch vestiges. `destinationRecords` reads
   `metadata.destination_tiles`; the later current-tree UX follow-up keeps
   those verdict tiles but opens the dialog's loading state immediately and
   resolves human-facing details through `metadata.places.catalog_file`.
   *Gate:* scripted screenshots at fixed viewports for each view × a fixed
   selection set, desktop and mobile widths (collapsed and expanded panel);
   URL hash round-trip (`view` + `requirements` + `at`); inspect dialog
   regression against a pinned location; no console errors.
   *Reviewer checks:* every `["get", key]` is `["has"]`-guarded; the
   preference-vs-effective viewMode rules of §3.2 (coercion never overwrites
   the stored preference; selection-change round-trips; 0-requirement state
   hides all four access layers); disabled-mode logic (bands with ≥2
   selected); N ≤ 4 everywhere (score ramp, legend, chips); legend ↔ paint
   expressions derived from the same data (no drift); collapsed chip row
   present and tappable at 2.75rem; error paths (`failedDestinationSources`,
   `reportMapError`) still reachable.
7. **Delete legacy outputs.** Remove per-route access builds,
   `coverage_tile_config`, the `access_tiles` metadata key, the legacy
   coverage-geojson intermediates and their writer; update default.nix
   expectations (`accessServices` passthru consumers, install globs).
   *Gate:* Vilnius `generated/` listing matches an explicit expected manifest;
   built site serves with zero 404s (etag sidecars present for all published
   files); `network.geojson` confirmed absent from the published output — it
   is a `work/` intermediate with no compressDrvWeb sidecars (§2.2).
   *Reviewer checks:* nothing references dead filenames (grep the tree);
   metadata contains no orphan keys; no stray `network.geojson` or
   `places.geojson` in `$out`; `place-catalog.json` and its etag are present.
8. **Zoom-scaled simplification (§2.3).** Last, so visual baselines exist.
   *Gate:* screenshot A/B z6/z8/z10 vs step-7 output — pixel-identical or
   imperceptible (reviewer judges against the "visually lossless" bar);
   tile-size deltas reported as information only.
   *Reviewer checks:* tolerance actually bounded by the MVT quantization step
   (extent-4096 coordinate unit) at each zoom for
   lat 54–56°; raw z14 untouched; mechanism matches what the pinned tilemaker
   implements (R6 resolved with evidence).

Steps 1–2 land immediately (independent of the rest). Steps 3–4 and 5–6 are
pairwise dependent; 5+6 could run in a worktree parallel to 3+4 finishing, per
the parallel-worktree policy, but 6 cannot gate before 5's metadata is real.

---

## 8. Risks / open questions (ranked)

- **R1 (high) — merge-tool scale on full Lithuania.** Hospital/fuel dumps are
  ~1M edges, 4M points each, and the merge tool is **whole-network resident
  by design** (§2.1: cross-dump geometry-string grouping plus the output
  canonical-string/attribute-group maps live in RAM before the first write;
  estimated 1.5–4 GB RSS at lt-full).
  *Resolution:* bound by measurement, not by architecture: step 4's gate
  records peak RSS on Vilnius and extrapolates; lt-full is measured before
  step 7. If measured RSS exceeds the 8 GB threshold, implement the
  designated fallback (spill per attribute group to temp files, then
  concatenate in group order). Do not claim streaming behavior the design
  does not have.
- **R2 (high) — restyle latency on mobile.** Filter/paint rebuilds re-evaluate
  expressions over every loaded tile's features; with ~10⁵ pieces in view at
  low zoom this may jank on mid-range phones.
  *Resolution:* measure in step 6 (Performance panel + a real device) at z7
  and z13 with all 4 requirements in score mode. If janky: cheapest fix is
  raising the network layer's effective minzoom in the style for score mode…
  which conflicts with UX-first; preferred fix is precomputing nothing and
  instead debouncing rapid preset taps and keeping filters flat (no nested
  `coalesce`), which keeps evaluation cheap. Escalate only with data.
- **R3 (med) — band-boundary rendering artifacts.** Adjacent pieces meeting at
  interpolated boundaries with `line-cap: butt` may show pinholes at extreme
  overzoom, or double-darkening if caps are switched to round.
  *Resolution:* shared-boundary-point construction (§1.3 step 4) plus keeping
  butt caps; verify at z18 overzoom in step 6's screenshots. If pinholes
  appear, a 0.5px `line-gap`-free casing under band joins is the fallback.
- **R4 (med) — score view legibility on always-true drive requirements.**
  With hospital-60 selected, score ≥1 nearly everywhere → the ramp's low end
  dominates and the view can look like today's wash.
  *Resolution:* score 0 is not drawn and the ramp is sampled per-N so the
  interesting high-count end keeps contrast; legend communicates "N of N".
  Validate with the coffee+hospital+fuel selection specifically in step 6
  review.
- **R5 (med) — shortcut edges in expansion output.** If Valhalla's expansion
  ever emits hierarchy shortcuts, `min(edge_id, opposing_id)` no longer maps
  1:1 to a base-edge polyline and §5.1's byte-identical claim breaks.
  *Resolution:* assert in step 1 (`is_shortcut()`); if the assert ever fires,
  resolve shortcuts to constituent base edges via `tile->edgeinfo` recovery
  before keying. Do not ship the assert-less version.
- **R6 (med, resolved) — tilemaker zoom-scaled simplification semantics.**
  Verified against the pinned 3.1.0 source at step 8:
  `simplify_level * pow(simplify_ratio, (simplify_below-1) - zoom)` with
  ratio defaulting to 2.0 (src/tile_worker.cpp:438, src/shared_data.cpp:317);
  §2.3 documents the mechanism and gate evidence. The zoom-banded-layer
  fallback was not needed.
- **R7 (low) — corridor width for mixed-mode selections.** Walk (12 m) vs
  drive (18 m) buffers can't both be honest in one line.
  *Resolution:* narrower-mode rule (§3.1); revisit only if step 6 screenshots
  show drive-only selections looking anemic.
- **R8 (low) — attribute growth with future services.** Keys scale linearly
  with `ROUTE_SPECS`; 360 attribute-map combinations today, growing
  multiplicatively.
  *Resolution:* acceptable; combos only affect GeoJSON feature grouping, not
  tile size (tilemaker regroups per tile). Note in code where
  `REQUIREMENT_KEYS` is derived.
- **R9 (low) — deploy-cache skew.** A client holding a cached index.html
  across a deploy could fetch new metadata with old JS for one load.
  *Resolution:* unchanged from today (etag'd, same-derivation deploy;
  metadata.json and index.html invalidate together in practice). No action.
