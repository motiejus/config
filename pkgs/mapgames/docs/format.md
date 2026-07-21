# Mapgames output format

This is the current serving contract for `.#mapgames`. The derivation in
`default.nix`, the metadata emitted by `generate.py`, and the tile configs are
authoritative; this document is an inventory, not a second configuration.

The output is a static, same-origin web application. All geographic archives
are PMTiles v3. Geographic archives contain gzip-compressed Mapbox Vector
Tiles (MVT); the SHA-256-named catalog archive contains gzip-compressed JSON pages with tile
type Unknown. A PMTiles
file is not downloaded whole: `pmtiles.js` reads its header, directories, and
the visible tile byte ranges with HTTP Range requests.

## Top-level files

| File | Contents and role | Native zoom | Browser use |
|---|---|---:|---|
| `index.html` | Entire application UI, MapLibre style, and interaction code | — | Initial document |
| `metadata.json` | Runtime manifest: bbox, snapshot timestamp, archive names/layers, service presets, access groups, versions | — | Initial load, in parallel with MapLibre startup |
| `lithuania.pmtiles` | OSM basemap | z4–14 | Source is created at startup; current viewport tiles are read immediately; z15–18 overzoom z14 |
| `access.pmtiles` | One edge-attributed reachable network for every service/mode/threshold | z6–14 | Source is created at startup; visible viewport tiles are read from z6; z15–18 overzoom z14 |
| `details.pmtiles` | Curated labels and markers for ordinary map reading, including dedicated potable-water and high-zoom street-detail layers | z15–16 | Source is created at startup; tile payload begins at z15; z17–18 overzoom z16 |
| `inspector.pmtiles` | Configured coffee/hospital/supermarket/fuel matches plus road-direction geometry | z15–16 | Lazy at z15+; road lines are reserved for explicit highlighted-road snapping |
| `places.pmtiles` | Point markers for configured service destinations | z14 only | Source is created at startup; enabled-service tiles begin at z14 and overzoom above it |
| `catalog-<sha256>.pmtiles` | Content-addressed, range-addressed JSON pages for objects, compact locations, destination sets/relations, plus raw spatial hit pages | synthetic z18 and spatial z15 | Lazy direct range reads; never downloaded whole |

`metadata.json` is the stable way for the client to discover these names and
layers. Do not duplicate its per-build access group IDs elsewhere: `g` is only
meaningful with the `access.pmtiles` and metadata from the same output.

### Basemap layers

`lithuania.pmtiles` contains:

| MVT layer | Native zoom | Purpose |
|---|---:|---|
| `earth` | z4–14 | Lithuania coverage/background |
| `places` | z4–14 | settlement names |
| `roads` | z4–14 | road/path geometry and names |
| `boundaries` | z4–14 | administrative boundaries |
| `landcover` | z5–14 | broad natural cover |
| `water` | z6–14 | water geometry and names |
| `landuse` | z9–14 | detailed land use |
| `infrastructure` | z11–14 | selected named infrastructure |
| `buildings` | z13–14 | building footprints |

### Access and destination lookup

`access.pmtiles` exposes one MVT layer, `network`. Every line has a numeric
group ID `g`. `metadata.json.access_network.groups[g]` is the line's complete
attribute map; each present requirement key (for example `coffee_walk`) gives
the minimum reachable preset in minutes. An absent key means unreachable.
The build's native network emitter writes those maps to a compact validated
sidecar in the same loop as the GeoJSON features, so producing metadata does
not load the full network geometry into Python.
The browser changes colors and visibility with feature state, so changing a
service, threshold, or view does not fetch different access tiles.
At z14, multiple spatially partitioned features can intentionally carry the
same `g`, even within one tile. The vector source promotes `g` as the feature
ID; MapLibre applies the group's single feature-state record to every feature
position with that ID.

The geometry varies inside the same layer:

- z6–7: a deliberately lossy short-chain-filtered subset of the z10 grid;
- z8–13: the unfiltered z10-grid skeleton (encoder-simplified through z10);
- z14: raw routing-edge geometry;
- z15–18: renderer overzoom of z14.

Destination inspection reads the clicked z15 XYZ page directly from
the catalog archive named by `metadata.catalog.file`. It adds only the side/corner pages crossed by the largest
active screen-space corridor (at most a 2x2 block), instead of always reading
all eight neighbors. Metadata and spatial pages have separate bounded LRUs and
share a four-request Range queue. Each sparse raw-JSON page is a sorted array
of `[edge_id,modeMask,deltaE7]` candidates. The compact canonical geometry is
checked against the click corridor in screen space before any relation-page
Range request; the fetched relation must repeat the exact geometry or the
client fails closed. Manifest gates bound the raw candidate count and the
post-filter relation-page fanout before a pathological lookup reaches the
network. The matching
`destination_edges` synthetic collection contains canonical E7 geometry and
per-preset fraction runs/breakpoints; those records reference
`destination_edge_set:*` collections of sorted global object indexes. The
catalog spatial contract and relation contract carry the same `edge_build_id`,
and clients fail closed when the identifiers differ.

### Paged object catalog

`metadata.catalog` and the PMTiles archive JSON metadata contain the same
schema (the former additionally has `file`). Pages use synthetic XYZ
coordinates `z=18, x=collection.base+page, y=0`. Object records are in the
`objects` collection, 64 per page, and retain global `index`, `place_id`,
`service`, coordinates, and human-facing fields. Destination-set collections use 32 sets
per page and destination-edge relations use 64 edges per page; the relation
pages stay below the 64
KiB compressed page gate. `object_locations`, 512 per page, is indexed by the same global
object ID and carries `[lonE7,latE7,serviceOrdinal,displayLabel,kind]`; this
supports country-wide ranking/counting and immediate collapsed result rows
without waiting for rich object pages. Service
ordinals are declared in the manifest.

`place_id_index` has exactly 256 pages, one hash bucket per page. Its page is a
JSON object from `place_id` to global index. Bucket selection is FNV-1a 32-bit
over the UTF-8 bytes, masked with 255. Thus restoring `#place` needs at most one
index page and one object page. All page JSON is canonical (sorted object keys,
compact separators, UTF-8, final newline) and gzip-compressed deterministically.

### Everyday detail

`details.pmtiles` contains:

| MVT layer | Native zoom | Contents |
|---|---:|---|
| `building_details` | z15–16 | building names, house names/numbers, ranks |
| `poi_details` | z15–16 | named everyday POIs and all playgrounds, classified and tiered |
| `transit_details` | z15–16 | canonical public-transport stops/stations, primary and per-mode flags, distinct `mode_count`, refs and tiers |
| `water_details` | z15–16 | verified potable-water points, with persistent marker from z15 and H₂O badge from z16 |
| `micro_details` | z16 | other curated walking-scale utilities such as toilets, AEDs, shelters and information; shape-first pictograms appear at z18 |
| `street_details` | z16 | bench points revealed from z17 and individual-tree points revealed at z18; these are the sole owners of those icons |

`display_tier` is a presentation decision, not necessarily a native tile
zoom. A z17 or z18 feature is encoded in a real z16 tile and revealed only at
that display zoom. The inspector is separately narrow interaction data, not a
general OSM tag browser.

### OSM inspector

`inspector.pmtiles` contains `inspect_points`, `inspect_lines`, and
`inspect_areas` at z15–16. Points and areas match exactly the four search
families in `generate.py`, selected by their configured source tags. Unlike the
routable place layer, the inspector keeps lifecycle-inactive matches (a
`disused`/`abandoned`/`closed`/`removed`/`proposed` café is still inspectable):
`status` carries the real lifecycle word, and the client appends it to the card
title. The routable place set (`prepare_places`) drops those same objects, so a
closed destination is marked on the map but never routed. Lines retain only
an explicit allowlist of usable linear road/path values; `area=yes`,
highway-tagged facilities, lifecycle values, and unknown highway values are
excluded (a road that is not a live edge can never back a routable access
edge). Lines carry identity, access, surface, and signed-direction fields for
explicit highlighted-road snapping. Ordinary inspection never turns those lines
into cards.

A snapped-road share uses `#at=…&osm=w…&inspect=road`. The final parameter is
accepted only for a way-qualified OSM identity on an `at` inspection and is
revalidated against the inspector tile before direction facts are shown.

A normal click below z15 does not create this source or download any part of
the archive. The modal can offer a separate action that moves to z15; only
then does the browser read the inspector header/directory and nearby tile
ranges. At z15+ an explicit map click loads nearby inspector tiles directly.

## Browser request lifecycle

The distinction between **source setup** and **tile payload** matters:

1. The document loads MapLibre CSS/JS, `pmtiles.js`, and the basemap style
   helper. It fetches `metadata.json` while the initial map style starts.
2. The basemap is part of that initial style. After metadata arrives, the app
   registers access, detail, and places sources. PMTiles may therefore make small header/directory Range
   requests for these files. This is not a full-archive download.
3. Only sources with a visible layer at the current zoom request tile payload:
   basemap, access from z6, enabled place markers from z14, and details from
   z15. The catalog is not a MapLibre source and stays unopened until lookup.
4. A click queries the compact z15 spatial catalog pages and filters their
   candidates against the click corridor. If they identify destinations, the
   referenced relation, destination-set, and object pages are fetched by range
   and cached; unrelated object metadata is not transferred or parsed.
5. The inspector source itself is not registered until explicit z15+
   inspection. Closing a modal does not imply the browser forgets already
   cached ranges.

MapLibre requests glyph PBF ranges only for characters it needs and loads the
light sprite atlas used by the active style. The many shipped font-range files
are therefore a deploy inventory, not an initial download.

## Static assets, compression, and ETags

`assets/` contains:

- pinned MapLibre CSS, main JS, and CSP worker;
- pinned `pmtiles.js` and the Protomaps basemap style helper;
- Noto Sans Regular/Medium/Italic glyph PBF ranges;
- the light sprite JSON/PNG atlases at 1× and 2×.

The output also contains the upstream license files. Every served payload has
a sibling `.etag` containing its content-derived ETag. Compressible files have
precompressed `.br`, `.gz`, and `.zst` siblings (and ETags for those siblings).
These sidecars are for the web server; application code never requests them by
name.

PMTiles files deliberately have no precompressed sidecars. Their internal MVT
tiles are already gzip-compressed, and HTTP byte ranges must address the
identity PMTiles bytes. Serving a whole-file `Content-Encoding` for PMTiles
breaks range offsets.

The production Caddy configuration serves precompressed static files and
content-derived ETags. Mutable deployment pointers use `Cache-Control:
no-cache` (conditional revalidation); the SHA-256-named catalog uses a
one-year immutable policy. Any alternative server must support byte
ranges correctly (`206` and `Content-Range`) and must not rewrite or
whole-file-compress PMTiles. Cross-origin hosting additionally requires CORS
permission for the application origin, exposure of range-related headers, and
an application `connect-src` CSP that permits the archive origin. The current
production CSP is deliberately same-origin-only.

## Inspecting a concrete build

Sizes and tile counts are observations, not schema; record them in build
reports rather than freezing them here. For a completed output, use `du -h`
for deploy sizes, `pmtiles show FILE.pmtiles` for bounds/zoom/tile counts, and
`pmtiles show --metadata FILE.pmtiles` for the encoded vector-layer fields.
Archive names, layers, native zooms, and the metadata relationships above are
the serving format.

## Derivation boundaries

`default.nix` builds three layers of output:

1. `data`: generated JSON and PMTiles plus ETags;
2. `www`: data, `index.html`, pinned browser assets, fonts, sprites, and
   licenses;
3. final output: `compressDrvWeb www`, wrapped once more to ensure every
   identity or precompressed file has an ETag.

GeoJSON, PBF extracts, Valhalla tiles, the normalized relation database, and
the raw/coarse network GeoJSON files live only in the build directory. They are
build intermediates, not part of the serving format.
