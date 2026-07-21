#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const {
  chooseInteraction,
  collocatedMarkerChoices,
  rankLocations,
  initialVisibleObjectIds,
  nextLocationBatch,
  withIconsOnlyPreset
} = require(process.argv[2] || "./review-ui-state.js");
const index = process.argv[3] ? readFileSync(process.argv[3], "utf8") : "";

if (index) {
  assert.match(index, /src="assets\/review-ui-state\.js"/);
  const quickView = index.slice(
    index.indexOf("function applyQuickView(view)"),
    index.indexOf("function haversineMeters")
  );
  assert.match(quickView, /if \(view === "all"\)/);
  assert.match(quickView, /metadata\.services\.forEach\(service => enable\(service\.id\)\)/);
  assert.match(quickView, /viewMode = "score"/);
  assert.match(index, /const viewModes = \["bands", "intersect", "score"\]/);
  assert.match(index, /if \(sharedMode !== null\) viewMode = sharedMode/);
  assert.match(index, /function inspectMapCenter\(\)/);
  assert.match(index, /map\.getCanvas\(\)\.addEventListener\("keydown"/);
  assert.match(index, /event\.key !== "Enter"/);
  assert.match(index, /moreStatus\.textContent = t\("loadingMore"\)/);
  assert.match(index, /appended\[0\]\?\.querySelector\("a, button, summary"\)\?\.focus\(\)/);
  const hashRestore = index.slice(
    index.indexOf("function applyLocationHash()"),
    index.indexOf("Promise.all([")
  );
  assert.match(hashRestore, /const markerChoiceDialog = document\.getElementById\("marker-choice-dialog"\)/);
  assert.match(hashRestore, /if \(markerChoiceDialog\.open\) markerChoiceDialog\.close\(\)/);
  assert.ok(hashRestore.indexOf("markerChoiceDialog.close()") <
    hashRestore.indexOf("new URLSearchParams"),
  "hash restore must dismiss stale marker choices before parsing the new state");
  const choiceClose = index.slice(
    index.indexOf('document.getElementById("marker-choice-dialog").addEventListener("close"'),
    index.indexOf('document.getElementById("location-dialog").addEventListener("close"')
  );
  assert.match(choiceClose, /activeMarkerChoices = \[\]/);
  assert.match(choiceClose, /marker-choice-list"\)\.replaceChildren\(\)/);

  assert.match(index, /function activeRequirements\(\)[\s\S]*selectedPreset\(service\)\.minutes > 0/);
  assert.match(index, /servicePresets\(service\)\.forEach\(preset =>/);
  assert.match(index, /minzoom: Math\.max\(placeDisplayMinZoom/);
  assert.match(index, /setLayerVisibility\(\[`places-\$\{service\.id\}`\], false\)/);
  assert.doesNotMatch(index, /minutes:\s*\(0,/,
    "zero-minute preset leaked into generated route specifications");

  const zeroLookup = index.slice(
    index.indexOf("function inspectSharedDestinationLocation"),
    index.indexOf("async function renderLocationResults")
  );
  assert.match(zeroLookup, /if \(!active\.length\)/);
  assert.match(zeroLookup, /renderLocationResults\([\s\S]*\.then\(\(\) => \{[\s\S]*updateMapStatus\(\)/,
    "icons-only inspection leaves the loading status behind");

  const viewSwitcher = index.slice(
    index.indexOf("function refreshViewSwitcher"),
    index.indexOf("function legendItem")
  );
  assert.match(viewSwitcher, /hidden = selectionCount < 2/);
  assert.match(viewSwitcher, /button\.disabled = selectionCount < 2 \|\| bandsLocked/);

  const legend = index.slice(
    index.indexOf("function renderLegend"),
    index.indexOf("function summaryChip")
  );
  assert.match(legend, /const iconServices = iconsOnlyServices\(\)/);
  assert.match(legend, /iconServices\.forEach\(service/);
  const status = index.slice(
    index.indexOf("function updateMapStatus"),
    index.indexOf("function refreshMap")
  );
  assert.match(status, /t\("statusMixed", selections\.length, iconServices\.length\)/);
  assert.match(status, /iconServices\.forEach\(service => summary\.append/);

  assert.match(index, /@media \(any-pointer: coarse\)/);
  assert.doesNotMatch(index, /@media \(pointer: coarse\)/);
  assert.match(index, /const edgePadding = coarse \? 22 : 2/);

  // Multiple spatial chunks (including chunks in one tile) intentionally
  // share a promoted group id. MapLibre 5.24's FeaturePositionMap stores all
  // positions for an id and program_configuration updates every returned
  // position; keep our side of that contract to one state write per g.
  const accessSetup = index.slice(
    index.indexOf("function addAccessNetwork()"),
    index.indexOf("function detailLocalizedField(property)")
  );
  assert.match(accessSetup, /promoteId:\s*\{ \[network\.layer\]: "g" \}/);
  const groupStates = index.slice(
    index.indexOf("function setAccessGroupStates(stateOf)"),
    index.indexOf("function setAccessLineWidth(width)")
  );
  assert.match(groupStates, /network\.groups\.forEach\(\(attributes, group\) =>/);
  assert.match(groupStates,
    /map\.setFeatureState\(\s*\{ source: "access", sourceLayer: network\.layer, id: group \}/);

  const keyboardInspect = index.slice(
    index.indexOf("function resetMapInspection"),
    index.indexOf("function inspectRoadAtRawResolution")
  );
  assert.match(index, /id="inspect-map-center"/);
  assert.match(keyboardInspect, /function inspectMapCenter\(\)/);
  assert.match(keyboardInspect, /inspectRoadAtRawResolution\(center,/);
  assert.match(index, /`\$\{STR\.lt\.mapAria\} · \$\{STR\.lt\.inspectCenter\}`/,
    "initial Lithuanian canvas label waits for a language change");

  const showMore = index.slice(
    index.indexOf("const more = document.createElement"),
    index.indexOf("const intersection = document.getElementById")
  );
  assert.match(showMore, /moreStatus\.textContent = t\("allPlacesShown", locations\.length\)/);
  assert.match(showMore, /appended\[0\]\?\.querySelector\("a, button, summary"\)\?\.focus\(\)/);
}

const markerFeature = (placeId, coordinates) => ({
  geometry: { coordinates },
  properties: { place_id: placeId, service: placeId }
});
const exactMarker = {
  kind: "marker", distance: 5, exact: true,
  feature: markerFeature("coffee", [25.2, 54.7]),
  features: [
    markerFeature("coffee", [25.2, 54.7]),
    markerFeature("hospital", [25.2, 54.7]),
    markerFeature("nearby", [25.20001, 54.7])
  ]
};
assert.equal(chooseInteraction([
  { kind: "map", distance: 0, exact: true }, exactMarker
]), exactMarker, "a painted marker must own the exact click");
assert.equal(chooseInteraction([
  { kind: "marker", distance: 5, exact: false },
  { kind: "map", distance: 2, exact: true }
]).kind, "map", "padded markers must still compete by distance");
assert.deepEqual(
  collocatedMarkerChoices(exactMarker, [exactMarker])
    .map(choice => choice.feature.properties.place_id),
  ["coffee", "hospital"]
);
assert.deepEqual(collocatedMarkerChoices({ ...exactMarker, exact: false }, [exactMarker]), []);

const routed = [{ mode: "walk", minutes: 10 }, { mode: "drive", minutes: 20 }];
const displayed = withIconsOnlyPreset(routed);
assert.deepEqual(displayed[0], { mode: "walk", minutes: 0, icons_only: true });
assert.deepEqual(displayed.slice(1), routed);
assert.equal(routed.length, 2);

const locationGroups = Array.from({ length: 5 }, (_unused, service) =>
  Array.from({ length: 20 }, (_item, offset) => ({
    index: service * 100 + offset,
    distance: 20 - offset
  }))
);
let rankedCount = 0;
const rankedGroups = locationGroups.map(locations => rankLocations(locations, location => {
  rankedCount += 1;
  return location.distance;
}));
assert.equal(rankedCount, 100, "ranking did not inspect every compact location");
assert.equal(initialVisibleObjectIds(rankedGroups, 3).length, 15,
  "initial rich hydration is not limited to three per service");
assert.deepEqual(nextLocationBatch(rankedGroups[0], 3, 12).map(location => location.index),
  rankedGroups[0].slice(3, 15).map(location => location.index));
assert.equal(nextLocationBatch(rankedGroups[0], 15, 12).length, 5,
  "show-more tail is not bounded to the remaining records");

console.log("review UI state runtime checks passed");
