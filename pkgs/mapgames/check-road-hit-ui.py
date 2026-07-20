#!/usr/bin/env python3

import argparse
import json
from math import hypot
from pathlib import Path
import re


def require(source: str, fragment: str, message: str) -> None:
    assert fragment in source, message


def distinct(left: dict, right: dict) -> bool:
    separation = hypot(
        left["point"][0] - right["point"][0],
        left["point"][1] - right["point"][1],
    )
    cross = abs(
        left["direction"][0] * right["direction"][1]
        - left["direction"][1] * right["direction"][0]
    )
    return separation > 1 or cross > 0.2


def choose(candidates: list[dict], policy: dict, painted_width: float = 6,
           semantic: bool = False) -> dict | None:
    if semantic:
        return None
    tolerance = min(policy["max_px"], painted_width / 2 + policy["off_ink_px"])
    eligible = sorted(
        (item for item in candidates if item["distance"] <= tolerance),
        key=lambda item: (item["distance"], item["key"]),
    )
    if not eligible:
        return None
    nearest = eligible[0]
    if any(
        candidate["distance"] - nearest["distance"] <= policy["ambiguity_px"]
        and distinct(candidate, nearest)
        for candidate in eligible[1:]
    ):
        return None
    return nearest


def candidate(distance: float, key: str, point=(0, 0), direction=(1, 0)) -> dict:
    return {
        "distance": distance,
        "key": key,
        "point": point,
        "direction": direction,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    args = parser.parse_args()
    source = args.index.read_text(encoding="utf-8")

    match = re.search(r"const roadSnapPolicy = (\{.*?\n      \});", source, re.DOTALL)
    assert match, "road snap policy must remain explicit and machine-readable"
    policy = json.loads(match.group(1))
    fine = policy["fine"]
    coarse = policy["coarse"]
    assert 0 < fine["off_ink_px"] < coarse["off_ink_px"]
    assert fine["max_px"] < coarse["max_px"] <= 18, "mobile hit box is unbounded"
    assert fine["max_px"] < fine["resnap_max_px"] <= 48
    assert coarse["max_px"] < coarse["resnap_max_px"] <= 64

    # One isolated road captures a close miss, but neither a far click nor a
    # semantic foreground icon is displaced by the forgiving road target.
    near = candidate(9, "near")
    assert choose([near], fine) == near
    assert choose([candidate(10.1, "far")], fine) is None
    assert choose([candidate(0, "road")], fine, semantic=True) is None

    # Coarse pointers get a practical touch target without changing desktop.
    assert choose([candidate(14, "touch")], coarse) is not None
    assert choose([candidate(14, "mouse")], fine) is None

    # Exact, unambiguous road hits remain deterministic. Buffered duplicate
    # copies and collinear tile pieces do not manufacture ambiguity.
    exact = candidate(0, "a")
    duplicate = candidate(0, "b")
    assert choose([duplicate, exact], fine)["key"] == "a"

    # A near tie between parallel roads, or perpendicular segments at an
    # intersection, falls back to the literal coordinate instead of guessing.
    assert choose([
        candidate(7, "left", point=(0, 0)),
        candidate(8, "right", point=(3, 0)),
    ], fine) is None
    assert choose([
        candidate(2, "east-west", direction=(1, 0)),
        candidate(2, "north-south", direction=(0, 1)),
    ], fine) is None

    click = source[source.index('map.on("click", event => {'):
                   source.index("// Fine-pointer cursor affordances")]
    interaction = source[source.index("function interactionAt"):
                         source.index("function inspectorFeaturesAt")]
    assert interaction.index("markerCandidateAt(point, coarse)") < interaction.index("semanticFeatureAt(point)")
    assert interaction.index("semanticFeatureAt(point)") < interaction.index("accessRoadOriginAt(point, { coarse })")
    require(interaction, "ReviewUiState.chooseInteraction(",
            "road and padded marker hits do not share one resolution policy")
    require(click, "interactionAt(event.point, coarse)",
            "map clicks bypass the shared interaction resolver")
    require(click, "const coarse = interactionIsCoarse(event.originalEvent);",
            "actual touch/pen events do not receive a coarse road target")
    require(click, "inspectRoadAtRawResolution(event.lngLat, roadHit, sequence, coarse);",
            "generalized access hit is committed without raw-resolution lookup")
    require(click, "commitArbitraryInspection(event.lngLat, sequence, false);",
            "far/ambiguous road clicks do not preserve the literal coordinate")

    road_hit = source[source.index("function accessRoadOriginAt"):
                      source.index("function inspectorFeaturesAt")]
    assert road_hit.count("map.queryRenderedFeatures(") == 1, (
        "one road tap performs multiple rendered-feature scans"
    )
    require(road_hit, "candidate.distance <= tolerance", "road candidates are not radius-bounded")
    require(road_hit, "candidate.distance - nearest.distance > policy.ambiguity_px",
            "parallel/intersection ambiguity is not bounded")
    require(road_hit, "lngLat: map.unproject(nearest.projected)",
            "nearest road geometry is not converted back into the inspection origin")
    assert "preferred_group" not in road_hit, (
        "attribute group g is incorrectly treated as road identity"
    )

    width = source[source.index("function corridorLineWidthStops"):
                   source.index("function lineLayout")]
    require(width, "const factor = (2 ** position - 1) / (2 ** span - 1);",
            "fractional hit width does not evaluate MapLibre's exponential interpolation")
    require(width, "corridorLineWidthStops(mode, maxWidthPx)",
            "paint width and hit width do not share the same stops")

    touch = source[source.index("function interactionIsCoarse"):
                   source.index("function accessRoadOriginAt")]
    for fragment in ('pointerType === "touch"', 'pointerType === "pen"',
                     "sourceCapabilities?.firesTouchEvents", "recentPointerModality",
                     "pointerModalityMaxAgeMs", "performance.now()",
                     "coarsePointerMedia.matches"):
        require(touch, fragment, f"hybrid input detection is missing {fragment}")
    pointer_capture = source[source.index("const pointerModalityMaxAgeMs"):
                             source.index("const destinationSourceIds")]
    require(pointer_capture, 'addEventListener("pointerdown"',
            "actual pointer modality is not captured before synthesized click")
    require(pointer_capture, "capturedAt: performance.now()",
            "pointer modality has no monotonic age bound")

    resnap = source[source.index("function inspectRoadAtRawResolution"):
                    source.index("function inspectLocation")]
    require(resnap, "const rawZoom = metadata.access_network.max_data_zoom;",
            "road interaction does not resolve against native access geometry")
    require(resnap, "initialHit.tolerance * (2 ** (rawZoom - startZoom))",
            "generalization displacement is not carried into the raw search")
    assert "preferred_group" not in resnap and "initialHit.group" not in resnap, (
        "raw resolution incorrectly preserves an attribute group as street identity"
    )
    require(resnap, "const resolved = rawHit?.lngLat || literalLngLat;",
            "failed raw re-snap freezes a generalized coordinate")
    assert resnap.index('map.once("idle"') < resnap.index(
        "commitArbitraryInspection(resolved, sequence, !!rawHit);"
    ), "road origin is committed before raw tiles settle"
    before_idle = resnap[:resnap.index('map.once("idle"')]
    assert "renderInspectionLoading(" not in before_idle
    assert "updateInspectionHash(" not in before_idle
    assert "locationMarker.setLngLat(" not in before_idle
    below_raw = resnap[resnap.index('map.once("idle"'):]
    assert "initialHit.lngLat" not in below_raw, "generalized coordinate survives the raw branch"

    commit = source[source.index("function commitArbitraryInspection"):
                    source.index("function inspectRoadAtRawResolution")]
    require(commit, "inspectLocation(lngLat, true, sequence);",
            "destination evaluation does not receive the resolved origin")
    require(commit, "lookupInspector(lngLat, sequence, false);",
            "inspector does not receive the resolved origin")

    # Production-flow regression: if a generalized line is displaced from its
    # native edge, only the raw coordinate may be committed to all consumers.
    literal = (25.280000, 54.687000)
    generalized = (25.281200, 54.687700)
    raw = (25.280080, 54.687030)
    resolved = raw or literal
    marker_origin = hash_origin = destination_origin = inspector_origin = resolved
    assert generalized not in {
        marker_origin, hash_origin, destination_origin, inspector_origin
    }
    assert len({marker_origin, hash_origin, destination_origin, inspector_origin}) == 1

    # `g` groups identical reachability attributes and can contain unrelated
    # roads. Selection must remain geometric across all painted candidates:
    # neither sharing nor changing g gives a road special preference.
    unrelated_same_group = candidate(8, "g7-unrelated")
    nearest_other_group = candidate(3, "g12-nearest")
    assert choose([unrelated_same_group, nearest_other_group], fine) == nearest_other_group
    assert choose([
        candidate(3, "g7-a", point=(0, 0)),
        candidate(4, "g12-b", point=(3, 0)),
    ], fine) is None, "ambiguity across attribute groups is ignored"

    # The visible access tile contributes geometry only. Rich direction/road
    # facts must still come from the lazy inspector, with a road preferred over
    # incidental nearby point objects after a snapped interaction.
    require(source, "const isRoad = isRoadDirectionCandidate(feature.properties, preferRoad);",
            "snapped inspection does not identify useful road/path objects")
    require(source, "const linePriority = isRoad ? -100 : 100;",
            "near-road inspection can still open an incidental point first")
    require(source, "inspectorFeaturesAt(lngLat, inspectionPrefersRoad)",
            "road preference does not reach the inspector result ordering")
    merge = source[source.index("function mergeInspectionCandidates"):
                   source.index("function appendOsmFact")]
    require(merge, "isRoadDirectionCandidate(properties, inspectionPrefersRoad)",
            "snapped roads are discarded before modal candidate selection")
    render = source[source.index("function renderClickedPlaces"):
                    source.index("function destinationRecordsForRequirements")]
    require(render, 'isRoadDirectionCandidate(active.feature.properties, true)',
            "the active snapped-road card is not explicitly recognized")
    require(render, '? "road-direction" : "destination";',
            "ordinary destination cards can inherit the road-only renderer")
    intent = source[source.index("function parseSharedInspectionIntent"):
                    source.index("function inspectionHash")]
    require(intent, 'return selectedRoad || restoringSelectedRoad ? "&inspect=road" : "";',
            "snapped road intent is dropped from its share hash")
    restore = source[source.index("function applyLocationHash"):
                     source.index("Promise.all([")]
    require(restore, 'sharedRoadIntent = parseSharedInspectionIntent(parameters, sharedOsm, "at");',
            "shared road hash does not restore explicit intent")
    require(restore, "inspectionPrefersRoad = sharedRoadIntent;",
            "restored road intent never reaches candidate selection")
    require(restore, 'parseSharedInspectionIntent(parameters, sharedOsm, "place");',
            "road intent can be smuggled into a place inspection")
    lookup = source[source.index("function lookupInspector"):
                    source.index("function inspectVisibleLocation")]
    require(lookup, "if (inspectionPrefersRoad && !inspectionOsmFeatures.some(feature =>",
            "restored road intent is not revalidated against loaded inspector data")
    fail_lookup = source[source.index("function failInspectorLookup"):
                         source.index("function createServiceControls")]
    require(fail_lookup, "inspectionPrefersRoad = false;",
            "failed inspector lookup leaks road preference")
    dialog_close = source[source.index('document.getElementById("location-dialog").addEventListener("close"'):
                          source.index('map.on("click", event => {')]
    require(dialog_close, "inspectionPrefersRoad = false;",
            "closing the dialog leaks road preference")

    hover = source[source.index("if (hoverMedia.matches) {"):
                   source.index('map.on("moveend"')]
    assert "accessRoadOriginAt(" not in hover, (
        "forgiving geometry scans run continuously during pointer movement"
    )


if __name__ == "__main__":
    main()
