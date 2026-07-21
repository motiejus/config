(function (root) {
  "use strict";

  // Every candidate.distance must be expressed in the same unit — screen
  // pixels from the interaction point — because the tie-break below compares
  // them directly across kinds (marker/road/map). A candidate measured in any
  // other unit would silently mis-rank.
  function chooseInteraction(candidates) {
    const priorities = { map: 0, marker: 1, road: 2 };
    return candidates.filter(candidate =>
      candidate && Number.isFinite(candidate.distance) && candidate.distance >= 0
    ).sort((left, right) => {
      const leftExactMarker = left.kind === "marker" && left.exact;
      const rightExactMarker = right.kind === "marker" && right.exact;
      if (leftExactMarker !== rightExactMarker) return leftExactMarker ? -1 : 1;
      return left.distance - right.distance ||
        (priorities[left.kind] ?? 99) - (priorities[right.kind] ?? 99);
    })[0];
  }

  function collocatedMarkerChoices(selectedInteraction, candidates) {
    if (!selectedInteraction?.exact || selectedInteraction.kind !== "marker") return [];
    const [selectedLon, selectedLat] = selectedInteraction.feature.geometry.coordinates;
    return candidates.flatMap(candidate => {
      if (!candidate?.exact || candidate.kind !== "marker") return [];
      return (candidate.features ?? [candidate.feature]).filter(feature => {
        const [lon, lat] = feature.geometry.coordinates;
        return lon === selectedLon && lat === selectedLat;
      }).map(feature => ({ kind: "marker", feature }));
    });
  }
  function rankLocations(locations, distance) {
    return locations.map(location => ({ location, distance: distance(location) }))
      .sort((left, right) => left.distance - right.distance ||
        left.location.index - right.location.index)
      .map(candidate => candidate.location);
  }

  function initialVisibleObjectIds(groups, limit = 3) {
    const ids = new Set();
    groups.forEach(locations =>
      locations.slice(0, limit).forEach(location => ids.add(location.index))
    );
    return [...ids];
  }

  function nextLocationBatch(locations, loaded, limit = 12) {
    return locations.slice(loaded, loaded + limit);
  }

  function withIconsOnlyPreset(presets) {
    // Presets are a build-enforced contract: generate.py fails the data
    // generation step unless every service carries a non-empty array of
    // positive-integer-minute routes. So this trusts its input and just
    // synthesizes the client-only icons-only "0" on top, taking the mode from
    // the first routed preset.
    return [{ mode: presets[0].mode, minutes: 0, icons_only: true }, ...presets];
  }

  const api = {
    chooseInteraction,
    collocatedMarkerChoices,
    rankLocations,
    initialVisibleObjectIds,
    nextLocationBatch,
    withIconsOnlyPreset
  };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.ReviewUiState = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
