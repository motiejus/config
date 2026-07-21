#!/usr/bin/env python3
"""Static integration contract for the shared canonical-edge lookup path."""

import argparse
import json
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--resolver", type=Path, required=True)
    parser.add_argument("--catalog-client", type=Path, required=True)
    args = parser.parse_args()
    index = args.index.read_text(encoding="utf-8")
    resolver = args.resolver.read_text(encoding="utf-8")
    catalog = args.catalog_client.read_text(encoding="utf-8")

    assert 'src="assets/destination-relations.js"' in index
    assert "new DestinationRelations(catalogPages, metadata.destination_lookup)" in index
    assert 'throw new Error("metadata.destination_lookup is missing")' in index
    assert "metadata.destination_tiles" not in index
    assert "destinationRecords" not in index
    assert 'strategy !== "legacy"' not in index
    assert "ensureSharedDestinationLayer" not in index
    assert "destination-hit-shared" not in index
    assert "sharedDestinationHitArchive" not in index
    assert "destinationSourceIds" not in index
    assert "failedDestinationSources" not in index
    assert "map.queryRenderedFeatures(map.project(lngLat)" not in index

    shared = index[index.index("function inspectSharedDestinationLocation("):
                   index.index("function renderLocationResults(")]
    assert "catalogPages.getSpatialCandidates(lngLat, activeModeMask, {" in shared
    assert "destinationRelations.resolve(" in shared
    assert "catalogPages.resolveReferenceLocations(references, markerIndexes)" in shared
    assert "lookupSequence !== sharedDestinationLookupSequence" in shared
    assert 'corridorLineWidthAtZoom("walk", map.getZoom(), Infinity) / 2' in shared
    assert 'corridorLineWidthAtZoom("drive", map.getZoom(), Infinity) / 2' in shared

    inactive = shared[shared.index("if (!active.length)"):
                      shared.index("const lookup = metadata.destination_lookup")]
    assert "return renderLocationResults(" in inactive
    assert ").then(() => {" in inactive
    assert "sequence === inspectSequence && lookupSequence === sharedDestinationLookupSequence" in inactive
    assert "updateMapStatus();" in inactive, (
        "icons-only inspection leaves the temporary zoom/loading status in place"
    )

    # The completion status belongs only to the current inspection. Exercise
    # the same two-generation guard used by both routed and icons-only paths:
    # a current render clears the temporary status, while either stale token
    # leaves the newer inspection's status untouched.
    lifecycle = json.loads(subprocess.run(
        ["node", "-e", r"""
(async () => {
  let inspectSequence = 7;
  let sharedDestinationLookupSequence = 11;
  let status = "Zooming in…";
  const renderLocationResults = () => Promise.resolve();
  const updateMapStatus = () => { status = "Icons only"; };
  const complete = (sequence, lookupSequence) =>
    renderLocationResults().then(() => {
      if (sequence === inspectSequence &&
          lookupSequence === sharedDestinationLookupSequence) updateMapStatus();
    });
  await complete(7, 11);
  const current = status;
  status = "Zooming in…";
  await complete(6, 11);
  const staleInspect = status;
  await complete(7, 10);
  process.stdout.write(JSON.stringify({ current, staleInspect, staleLookup: status }));
})();
"""], check=True, capture_output=True, text=True
    ).stdout)
    assert lifecycle == {
        "current": "Icons only",
        "staleInspect": "Zooming in…",
        "staleLookup": "Zooming in…",
    }, lifecycle

    # The spatial prefilter uses the uncapped geographic corridor, not the
    # narrower width cap used for painting at high zoom.
    width_source = index[index.index("function corridorLineWidthStops"):
                         index.index("function corridorLineWidth(")]
    width_check = f"""
const metadata = {{
  bbox: [20.618591, 53.892206, 26.83873, 56.45329],
  geometry: {{ corridor_buffer_meters: {{ walk: 12, drive: 18 }} }}
}};
const corridorWidthCapPx = 6;
{width_source}
const result = {{
  walk: corridorLineWidthAtZoom("walk", 15, Infinity) / 2,
  drive: corridorLineWidthAtZoom("drive", 15, Infinity) / 2,
  cappedWalk: corridorLineWidthAtZoom("walk", 15) / 2,
  cappedDrive: corridorLineWidthAtZoom("drive", 15) / 2
}};
process.stdout.write(JSON.stringify(result));
"""
    widths = json.loads(subprocess.run(
        ["node", "-e", width_check], check=True, capture_output=True, text=True
    ).stdout)
    assert abs(widths["walk"] - 8.7965459025) < 1e-9, widths
    assert abs(widths["drive"] - 13.1948188538) < 1e-9, widths
    assert widths["cappedWalk"] == 3 and widths["cappedDrive"] == 3, widths
    assert widths["drive"] > widths["walk"] > widths["cappedWalk"], widths
    assert "metadata.destination_lookup.hit.zoom" in index
    assert "resolveReferenceLocations" in catalog and "getObjectLocations" in catalog
    assert "getSpatialCandidates" in catalog
    assert "neighbor_radius !== 1" in catalog
    assert "spatial:${zoom}:${x}:${y}" in catalog
    assert "maxConcurrentReads" in catalog and "maxCachedSpatialPages" in catalog
    assert "fanout_gate" in catalog
    assert "pages.size > collection.max_request_pages" in catalog
    assert "reference_fanout" in catalog
    assert "max_request_members" in catalog and "max_record_members" in catalog
    assert "cancelReadBatch" in catalog and "readBatches" in catalog
    assert "Promise.all(pages.values())" not in catalog

    rendering = index[index.index("async function renderLocationResults("):
                      index.index("function commitArbitraryInspection(")]
    assert "ReviewUiState.rankLocations(" in rendering
    assert "lon: origin.lng" in rendering and "lat: origin.lat" in rendering
    assert "ReviewUiState.initialVisibleObjectIds" in rendering
    assert "catalogPages.getObjects(missingInitial)" in rendering
    assert "ReviewUiState.nextLocationBatch(locations, loaded, 12)" in rendering
    assert "catalogPages.getObjects(batchLocations.map" in rendering

    assert "fraction === point" in resolver, "breakpoints must use exact equality"
    assert "start < fraction && fraction < end" in resolver, "interiors must remain open"
    assert "haversineMeters" in resolver and "closestCanonicalPoint" in resolver
    assert "candidateMask & ~relation[0]" in resolver
    assert "record.length !== 2" in resolver
    assert "relation[1].map" in resolver
    assert "destination hit/relation geometry mismatch" not in resolver
    assert "setCollection.count" in resolver, "set IDs are not manifest-bounded"
    assert "edge_build_id" in resolver and "edge_build_id" in catalog
    assert "config.schema_version !== 3" in resolver
    assert "catalogFilePattern.test(hit.file)" in resolver
    assert "manifest.schema_version !== 4" in catalog
    assert "destination_edge_set:" in catalog, "new set collections are rejected by page client"

    print("shared destination UI contract passed")


if __name__ == "__main__":
    main()
