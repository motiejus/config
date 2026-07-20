#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const {
  chooseInteraction,
  collocatedMarkerChoices,
  withIconsOnlyPreset
} = require(process.argv[2] || "./review-ui-state.js");
const index = process.argv[3] ? readFileSync(process.argv[3], "utf8") : "";

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
]), exactMarker);
assert.equal(chooseInteraction([
  { kind: "marker", distance: 5, exact: false },
  { kind: "map", distance: 2, exact: true }
]).kind, "map");
assert.deepEqual(
  collocatedMarkerChoices(exactMarker, [exactMarker])
    .map(choice => choice.feature.properties.place_id),
  ["coffee", "hospital"]
);

const routed = [{ mode: "walk", minutes: 10 }, { mode: "drive", minutes: 20 }];
const displayed = withIconsOnlyPreset(routed);
assert.deepEqual(displayed[0], { mode: "walk", minutes: 0, icons_only: true });
assert.deepEqual(displayed.slice(1), routed);
assert.equal(routed.length, 2);

if (index) {
  assert.match(index, /src="assets\/review-ui-state\.js"/);
  assert.match(index, /function activeRequirements\(\)[\s\S]*minutes > 0/);
  assert.match(index, /servicePresets\(service\)\.forEach\(preset =>/);
  assert.match(index, /minzoom: Math\.max\(placeDisplayMinZoom/);
  assert.match(index, /setLayerVisibility\(\[`places-\$\{service\.id\}`\], false\)/);
  // Centre inspection resolves through the shared resolver and can snap to a
  // road, exactly like a map click — not exact-marker-or-literal only.
  assert.match(index, /function inspectMapCenter\(\)[\s\S]*inspectRoadAtRawResolution\(center,/);
  assert.match(index, /@media \(any-pointer: coarse\)/);
  assert.match(index, /return catalogPromise/);
}

console.log("review UI state runtime checks passed");
