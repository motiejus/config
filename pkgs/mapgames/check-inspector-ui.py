#!/usr/bin/env python3

import argparse
from pathlib import Path


def require(source: str, fragment: str, message: str) -> None:
    assert fragment in source, message


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    args = parser.parse_args()
    source = args.index.read_text(encoding="utf-8")

    # The inspector is a click-only data source. Merely registering a PMTiles
    # source opens the archive, so source and hidden hit layers must not exist
    # until an explicit native-zoom lookup.
    require(source, 'url: `pmtiles://${new URL(inspector.file, location.href).href}`',
            "inspector PMTiles source is missing")
    assert source.count('id: "inspector-hit-') == 4, "expected four geometry-specific hit layers"
    inspector_layers = source[source.index("function ensureInspectorLayers"):
                              source.index("function addPlaceLayers")]
    assert inspector_layers.count('layout: { visibility: "none" }') == 1
    assert "inspector-visible" not in source and "inspector-route-style" not in source
    startup_start = source.index("Promise.all([")
    startup = source[startup_start:source.index("renderSummaryText();", startup_start)]
    assert "ensureInspectorLayers" not in startup, "startup opens the inspector PMTiles archive"
    lookup = source[source.index("function lookupInspector"):
                    source.index("function inspectVisibleLocation")]
    require(lookup, "if (!forceZoom) return;", "broad-zoom click does not stop before source creation")
    require(lookup, "if (!ensureInspectorLayers())", "native-zoom lookup does not lazily create source")
    assert lookup.index("if (!forceZoom) return;") < lookup.index("ensureInspectorLayers()"), (
        "broad-zoom lookup creates inspector source before its early return"
    )
    require(source, "inspectorSourceNeedsReset = true;", "failed inspector sources are not retryable")
    require(source, "if (inspectorSourceNeedsReset) discardInspectorLayers();",
            "the next explicit lookup does not replace a failed inspector source")
    require(source, "failedLookupSequence === activeInspectorLookupSequence",
            "a stale source error can reset the active lookup")
    assert "inspectorSourceUnavailable" not in source, "one transient failure permanently disables inspection"
    require(source, "if (map.getLayer(layerId)) {",
            "pre-initialization invalidation tries to mutate absent inspector layers")
    require(source, 'inspectorSourceId = `inspector-${++inspectorSourceSerial}`;',
            "retries do not isolate stale MapLibre source callbacks")
    require(source, "if (event.sourceId !== inspectorSourceId) return;",
            "a callback from a discarded inspector source can fail its replacement")
    require(source,
            "pmtilesProtocol.tiles.delete(new URL(metadata.inspector.file, location.href).href);",
            "failed inspector PMTiles reader is retained in the protocol cache")
    cache_eviction = source[source.index("function discardInspectorLayers"):
                            source.index("function ensureInspectorLayers")]
    assert cache_eviction.count("pmtilesProtocol.tiles.delete(") == 1
    assert "clear(" not in cache_eviction, "retry flushes unrelated PMTiles archives"
    assert cache_eviction.index("inspectorSourceId = undefined;") < cache_eviction.index("map.removeSource("), (
        "source removal can synchronously report an old error as the active generation"
    )

    # Areas require exact containment while point/line targets use separate,
    # coarse-pointer-aware boxes.
    require(source,
            'map.queryRenderedFeatures(point, { layers: ["inspector-hit-areas"] })',
            "area lookup must use the exact clicked point")
    require(source, "const pointPadding = coarsePointerMedia.matches ? 20 : 12;",
            "point hit padding contract changed")
    require(source, "const linePadding = coarsePointerMedia.matches ? 14 : 8;",
            "line hit padding contract changed")
    require(source, "pointSegmentDistance(", "line distance refinement is missing")
    require(source, "merged.set(identity", "buffered tile copies are not deduplicated")
    require(source, 'if (String(event.sourceId || "").startsWith("inspector-"))',
            "inspector failures are not isolated from accessibility data errors")
    require(source, "inspectorTileLookupSequences.get(event.tile)",
            "inspector tile errors are not associated with their originating lookup")
    require(source, "lookupSequence !== activeInspectorLookupSequence) return;",
            "stale inspector idle/error callbacks can mutate the active inspection")
    require(source, 'map.on("sourcedataloading", event => {',
            "inspector tile requests are not tagged with a lookup generation")

    # Identity is an explicit, type-qualified OSM key. `#place` remains the
    # origin for service markers while `osm=` is merely an optional selection.
    require(source, "const osmSharePattern = /^[nwr][1-9][0-9]*$/;",
            "strict OSM share identity validation is missing")
    require(source, ": `place=${encodeURIComponent(inspectionPlaceId)}`",
            "legacy place hashes are no longer preserved")
    require(source, "${langParam()}${osmParam()}", "osm selection is missing from inspect hashes")
    require(source, "centerSharedInspection(inspectionOrigin, sequence, !!sharedOsm)",
            "explicit OSM restores do not request inspector zoom")

    # Cards must stay DOM-safe and external data cannot choose a URL protocol.
    assert "innerHTML" not in source and "insertAdjacentHTML" not in source
    require(source, '["http:", "https:"].includes(url.protocol)',
            "website protocol allowlist is missing")
    require(source, "link.rel = \"noopener noreferrer\"", "external links are not isolated")
    require(source, 'button.setAttribute("aria-pressed"', "overlap selector state is missing")
    require(source, "min-height: 2.75rem", "44px-equivalent touch target is missing")
    require(source, 'zoomToInspect: "Zoom in to inspect nearby map objects."',
            "below-zoom inspector guidance is missing")
    require(source,
            'button.addEventListener("click", () => {\n            if (inspectionOrigin) lookupInspector(inspectionOrigin, inspectSequence, true);',
            "below-zoom inspector action does not explicitly request a zoomed lookup")
    below_zoom = lookup
    assert 'if (!forceZoom) return;' in below_zoom, (
        "ordinary broad-zoom clicks must not automatically fetch inspector tiles"
    )

    # Language changes render the retained object model; only a fresh click or
    # explicit restore calls the tile lookup.
    require(source, 'if (document.getElementById("location-dialog").open) renderClickedPlaces();',
            "open inspector is not rerendered on language changes")
    apply_language = source[source.index("function applyLanguage"):
                            source.index("function setLanguage")]
    assert "lookupInspector(" not in apply_language, "language toggle refetches inspector tiles"

    # Accessibility answers lead; rich OSM context follows in a separately
    # announced async region. The dialog title and inspector section must not
    # repeat the same “About this location” heading.
    assert source.index('id="location-results"') < source.index('id="clicked-place"'), (
        "rich OSM inspector appears before accessibility results"
    )
    require(source, 'id="clicked-place" aria-live="polite" aria-busy="false"',
            "inspector async region semantics are missing")
    require(source, 'root.setAttribute("aria-busy", String(inspectionOsmLoading));',
            "inspector loading state is not exposed")
    require(source, 'title.textContent = t("mapObjectsTitle");',
            "inspector repeats the dialog heading")

    # Every normalized category and state produced by inspector.lua has a
    # friendly label, in both languages. Unexpected categories fall back to
    # “OSM object” rather than leaking a schema token into the UI.
    categories = [
        "tourism", "amenity", "historic", "natural", "leisure", "landuse",
        "transport", "crossing", "protected", "water", "barrier", "emergency", "man_made", "place",
        "healthcare", "transit", "retail", "business", "building", "address", "route",
    ]
    category_tables = source[source.index("const osmCategoryLabels"):
                             source.index("const osmNormalizedValueLabels")]
    for category in categories:
        assert category_tables.count(f'{category}:') == 2, f"missing bilingual category: {category}"
    normalized_values = [
        "active", "abandoned", "closed", "construction", "removed", "disused", "proposed",
        "allowed", "permissive", "prohibited", "restricted", "conditional", "unknown",
        "yes", "no", "true", "false",
    ]
    normalized_tables = source[source.index("const osmNormalizedValueLabels"):
                               source.index("const normalizedOsmKeys")]
    for value in normalized_values:
        assert normalized_tables.count(f'{value}:') == 2, f"missing bilingual normalized value: {value}"
    require(source, 'const category = osmCategoryLabels[lang][value] || t("osmObject");',
            "unknown categories expose raw schema values")
    require(source, '(osmKindLabels[lang][properties.kind] || readableOsmValue(properties.kind))',
            "named inspector objects hide their specific OSM kind")
    for kind in ("crossing", "level_crossing", "protected_area", "riverbank"):
        assert source.count(f'{kind}:') >= 2, f"missing bilingual inspector kind: {kind}"
    require(source, 'const railwayCrossing = ["crossing", "level_crossing"].includes(properties.railway);',
            "railway crossings are not distinguished from timetable-bearing transit")
    require(source, 'if (properties.category === "crossing") return false;',
            "normalized lifecycle crossings still receive the timetable caveat")
    require(source, '(!!properties.railway && !railwayCrossing)',
            "railway crossings still receive the timetable caveat")

    print("inspector UI contract passed")


if __name__ == "__main__":
    main()
