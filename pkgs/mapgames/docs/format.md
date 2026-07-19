# Mapgames output format

This is the current serving contract for `.#mapgames`. The derivation in
`default.nix`, the metadata emitted by `generate.py`, and the tile configs are
authoritative; this document is an inventory, not a second configuration.

The output is a static, same-origin web application. All geographic archives
are PMTiles v3 containing gzip-compressed Mapbox Vector Tiles (MVT). A PMTiles
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
| `inspector.pmtiles` | Broad OSM geometry and selected useful tags for the click modal | z15–16 | Source does not exist until an explicit inspection at z15+; z17–18 overzoom z16 |
| `places.pmtiles` | Point markers for configured service destinations | z14 only | Source is created at startup; enabled-service tiles begin at z14 and overzoom above it |
| `place-catalog.json` | Compact original coordinates and human-facing fields for service destinations | — | Lazy: fetched only when an inspection needs named destination records or a shared `#place` is restored |
| `destinations-<service>-<mode>.pmtiles` | Invisible hit corridors mapping a clicked reachable edge to destination catalog indexes | z12–14 | Sources are registered at startup but layers remain hidden; selected layers read tiles only while evaluating a click at z12+; z15–18 overzoom z14 |

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
| `pois` | z14 | the small basemap POI subset |

### Access and destination lookup

`access.pmtiles` exposes one MVT layer, `network`. Every line has a numeric
group ID `g`. `metadata.json.access_network.groups[g]` is the line's complete
attribute map; each present requirement key (for example `coffee_walk`) gives
the minimum reachable preset in minutes. An absent key means unreachable.
The browser changes colors and visibility with feature state, so changing a
service, threshold, or view does not fetch different access tiles.

The geometry varies inside the same layer:

- z6–7: a deliberately lossy short-chain-filtered subset of the z10 grid;
- z8–13: the unfiltered z10-grid skeleton (encoder-simplified through z10);
- z14: raw routing-edge geometry;
- z15–18: renderer overzoom of z14.

There is one destination archive per routed service/mode pair:

| Archive | MVT layers |
|---|---|
| `destinations-coffee-walk.pmtiles` | `destinations_5`, `_10`, `_20` |
| `destinations-hospital-drive.pmtiles` | `destinations_15`, `_30` |
| `destinations-supermarket-walk.pmtiles` | `destinations_10`, `_20` |
| `destinations-supermarket-drive.pmtiles` | `destinations_10` |
| `destinations-fuel-drive.pmtiles` | `destinations_10`, `_20` |

Each feature carries `lookup_ids`, a compact set of indexes into
`place-catalog.json`. These archives are for point inspection, not visible
coverage rendering.

### Everyday detail

`details.pmtiles` contains:

| MVT layer | Native zoom | Contents |
|---|---:|---|
| `building_details` | z15–16 | building names, house names/numbers, ranks |
| `poi_details` | z15–16 | named everyday POIs and all playgrounds, classified and tiered |
| `transit_details` | z15–16 | canonical public-transport stops/stations, primary and per-mode flags, distinct `mode_count`, refs and tiers |
| `water_details` | z15–16 | verified potable-water points, with persistent marker from z15 and H₂O badge from z16 |
| `micro_details` | z16 | other curated walking-scale utilities such as toilets, AEDs, shelters and information |
| `street_details` | z16 | bench points revealed from z17 and individual-tree points revealed at z18 |

`display_tier` is a presentation decision, not necessarily a native tile
zoom. A z17 or z18 feature is encoded in a real z16 tile and revealed only at
that display zoom. The client deliberately keeps this archive narrower than
the inspector: map ink is curated; the modal is liberal.

### OSM inspector

`inspector.pmtiles` contains `inspect_points`, `inspect_lines`,
`inspect_areas`, and `hiking_routes`, all at z15–16. It preserves exact OSM
object identity plus a sparse allowlist of practical, access, lifecycle,
outdoor, civic, business, tourism, and contact tags. It is intentionally the
largest high-zoom archive and intentionally lazy.

A normal click below z15 does not create this source or download any part of
the archive. The modal can offer a separate action that moves to z15; only
then does the browser read the inspector header/directory and nearby tile
ranges. At z15+ an explicit map click loads nearby inspector tiles directly.

## Browser request lifecycle

The distinction between **source setup** and **tile payload** matters:

1. The document loads MapLibre CSS/JS, `pmtiles.js`, and the basemap style
   helper. It fetches `metadata.json` while the initial map style starts.
2. The basemap is part of that initial style. After metadata arrives, the app
   registers access, detail, places, and all five destination sources. PMTiles
   may therefore make small header/directory Range requests for these files.
   This is not a full-archive download.
3. Only sources with a visible layer at the current zoom request tile payload:
   basemap, access from z6, enabled place markers from z14, and details from
   z15. Destination layers are normally `visibility: none`.
4. A click first evaluates the active destination layers at z12 or higher.
   Only the selected service/mode/preset layers become visible for one load,
   then they are hidden again. If they identify destinations,
   `place-catalog.json` is fetched once and cached as a browser promise.
5. The inspector has a stricter boundary: the source itself is not registered
   until explicit z15+ inspection. Closing a modal does not imply the browser
   forgets already cached ranges.

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

The production Caddy configuration serves precompressed static files,
content-derived ETags, `Cache-Control: no-cache` (conditional revalidation),
and same-origin PMTiles requests. Any alternative server must support byte
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

GeoJSON, PBF extracts, Valhalla tiles, edge dumps, and the raw/coarse network
GeoJSON files live only in the build directory. They are build intermediates,
not part of the serving format.
