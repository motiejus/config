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
3. reverse-expands destinations in deterministic bounded origin batches (the
   configured `expansionBatchSize` is an explicit derivation input),
   classifies each batch into open runs and exact closed breakpoints, and
   appends the compact sets and functions to a versioned binary handoff;
4. overlays the disjoint batch functions in the native Valhalla helper and
   writes the unpublished normalized SQLite work database, including
   build-local edge/set IDs, delta geometries, and the z15 spatial candidate
   index. For a fixed batch layout these IDs are deterministic; they are scoped
   by `edge_build_id` and deployed atomically with their consumers. Raw
   destination memberships are never materialized or parsed by Python;
5. writes build-local edge/set IDs directly into two primary-key-ordered run
   and exact-breakpoint streams. Member vectors and delta geometries remain
   compact integer BLOBs; a route-scoped full-member cache interns sets on
   first occurrence, with explicit entry and encoded-byte resource gates, so
   SQLite needs no second copy or hash index. The network merge reads runs
   directly (zero-length breakpoint overrides cannot draw a line), while the
   catalog merges both streams. No second country-wide relation table or
   global relation sort is produced. The merge partitions edges wherever an
   attribute map changes and emits `network.geojson` with its `g` values. Raw
   geometry is partitioned by deterministic z10 Web Mercator bbox-centre
   buckets so Tilemaker never clips a country-wide MultiLineString for each
   z14 tile; adjacent chunks of one attribute group repeat the same `g`. In the
   same ordered native serialization loop it emits a tiny
   `network-groups.json` work sidecar containing the exact property maps,
   declared count, and matching `g` values; generator metadata consumes this
   sidecar instead of parsing the country-wide network geometry. Both files
   are flushed and closed as unique same-directory temporaries, then published
   as a rollback-protected pair so an open, write, or second-rename failure
   preserves the previous pair;
6. derives low-zoom skeletons with `coarsen.py`;
7. tiles the low-zoom and raw representations into the same `network` MVT
   layer in `access.pmtiles`.

The build fails if any configured destination cannot be routed. The published
paged object catalog, raw z15 spatial candidates, compact object locations,
relations, and every destination membership collection stream from the same
canonical DB. Each unique sorted membership array is stored once in its
service/mode/minutes collection in the content-addressed catalog PMTiles archive.

SQLite row IDs, page allocation, and the work-database bytes are deliberately
not a reproducibility contract. The content-addressed `edge_build_id`, catalog
manifest, network GeoJSON, and PMTiles pages are. `catalog.py` proves that
build ID and all object-member bounds while streaming the exact published set
and relation pages, rather than rescanning the work database first.

Spatial hit pages repeat only each candidate's compact delta-E7 canonical
geometry. The browser uses it to reject the country-network edges that merely
share a z15 tile with the click, then fetches rich relation pages only for
edges actually inside the active painted corridor. Exact geometry equality
between the hit and relation records prevents the prefilter from masking a
stale or mismatched catalog.

## Segmentation invariants

The merge operates on directed graph-edge intervals. For each edge it forms
the sorted union of every route/preset boundary, emits each non-empty interval
once, and assigns the complete requirement map valid on that interval. Equal
attribute maps share a group. The normalized-DB fixture covers exact endpoints,
geometry deduplication, route-order independence, and deterministic network
emission in one end-to-end contract.

The important invariants are:

- no routable interval is lost or emitted twice;
- an absent requirement and an unreachable requirement are the same state;
- a larger preset cannot be recorded as the minimum when a smaller preset
  already reaches the interval;
- feature `g` and the metadata group array are produced in the same ordered
  native serialization loop. The compact sidecar has one entry per group even
  when multiple spatial chunks repeat that `g`; its declared count and every
  sidecar `g` are validated before publication, so there is no separate
  numbering pass or Python parse of `network.geojson`;
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

- `check-destination-lookup.py`: validates classified batch overlay, exact
  breakpoints, normalized DB invariants, deterministic spatial chunking,
  chunked/reassembled low-zoom byte identity, and catalog determinism.
- `check-lowzoom-coarsen.py`: can check group preservation and deterministic
  low-zoom geometry.
- `generate.py` validates the sidecar group table; `coarsen.py` asserts ordered
  contiguous raw-feature runs by `g`; `catalog.py` validates global object
  indexes and every sorted, unique, in-range destination membership set.

Implementation constants and service bands live in `generate.py`; this note
intentionally does not duplicate them beyond naming the current schema.
