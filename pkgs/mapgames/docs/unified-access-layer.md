# Unified access network: current implementation

This is a short implementation note for the reachable-network pipeline.
For the published files, zooms, layers, and browser request lifecycle, see
[`format.md`](format.md). Historical proposals and benchmark diaries were
removed because they described superseded service bands, rendering paths, and
future phases as if they were current.

## Data model

The published `access.pmtiles` has one MVT source layer, `network`. Each
feature contains:

- `g`: a build-local attribute-map group ID;
- zero or more requirement keys: `coffee_walk`, `hospital_drive`,
  `supermarket_walk`, `supermarket_drive`, and `fuel_drive`.

A requirement value is the minimum successful routing preset in minutes.
Absence means unreachable. `metadata.json.access_network.groups[g]` contains
the authoritative complete map for a group. Group IDs are deterministic
inside one build, but are not persistent IDs across OSM snapshots.

Geometry is represented as client-stroked centerlines. Walk and drive use
12 m and 18 m corridor buffers respectively. The visible style caps width at
high zoom; invisible destination hit corridors retain their geographic width.

## Pipeline

For every service/mode route, `generate.py`:

1. filters and canonicalizes destination points from the OSM snapshot;
2. builds the Valhalla graph once;
3. reverse-expands each destination to the route's maximum configured time
   and records the intervals for every configured preset;
4. writes deterministic edge-interval dumps;
5. invokes `valhalla-expand --merge-network` to partition edges wherever an
   attribute map changes and emit `network.geojson` with its `g` values;
6. derives low-zoom skeletons with `coarsen.py`;
7. tiles the low-zoom and raw representations into the same `network` MVT
   layer in `access.pmtiles`.

The build fails if any configured destination cannot be routed. The published
place catalog and every destination lookup archive derive from the same
canonical ordered destination set.

## Segmentation invariants

The merge operates on directed graph-edge intervals. For each edge it forms
the sorted union of every route/preset boundary, emits each non-empty interval
once, and assigns the complete requirement map valid on that interval. Equal
attribute maps share a group. Exact endpoint and direction handling is covered
independently by `check-edge-dump.py` and `check-network-segments.py`.

The important invariants are:

- no routable interval is lost or emitted twice;
- an absent requirement and an unreachable requirement are the same state;
- a larger preset cannot be recorded as the minimum when a smaller preset
  already reaches the interval;
- feature `g` and the metadata group array are produced from the same ordered
  `network.geojson`, not by separate numbering passes;
- output ordering and floating-point formatting are deterministic.

## Browser rendering

The browser keeps two access line layers loaded. A service/view change maps
each metadata attribute group to color and opacity and updates feature state.
It does not change a source filter, retessellate geometry, or fetch alternate
tiles. The supported views are:

- `bands`: one selected requirement, with distinct threshold bands;
- `intersect`: one color for places satisfying every selected requirement;
- `score`: discrete count of satisfied selected requirements.

Color never carries the whole meaning: the panel and legend state the active
view, service, mode, and thresholds, and threshold bands use deliberately
separated lightness/hue steps.

## Current verification points

- `check-edge-dump.py`: can independently check route expansion intervals.
- `check-network-segments.py`: can independently re-segment and validate the
  unified output.
- `check-lowzoom-coarsen.py`: can check group preservation and deterministic
  low-zoom geometry.
- `generate.py` asserts that input feature `g` values match metadata array
  order and that destination catalog indexes match the canonical place order.

These independent network checkers are explicit development tools; the
ordinary `default.nix` build does not invoke them automatically.

Implementation constants and service bands live in `generate.py`; this note
intentionally does not duplicate them beyond naming the current schema.
