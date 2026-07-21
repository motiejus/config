#!/usr/bin/env python3
"""Static integration contract for the on-demand catalog page client."""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--client", type=Path, required=True)
    args = parser.parse_args()
    index = args.index.read_text(encoding="utf-8")
    client = args.client.read_text(encoding="utf-8")

    assert 'src="assets/catalog-pages.js"' in index
    assert "new CatalogPages(" in index
    assert "await catalogPages.manifest()" not in index, "catalog archive is fetched eagerly"
    assert "new root.pmtiles.PMTiles(url)" in client, "client is not using direct PMTiles reads"
    assert ".getMetadata()" in client and ".getZxy(" in client
    assert "inFlightPages" in client and "pageCache" in client
    assert "maxCachedPages" in client and "while (cache.size > maximum)" in client
    assert "maxCachedSpatialPages" in client and "maxConcurrentReads" in client
    assert "resolveReferenceLocations" in client and "getDestinationSets" in client
    assert "getObjectLocations" in client and "getSpatialCandidates" in client
    assert "findObjectByPlaceId" in client and "fnv1a32" in client
    assert "manifest.schema_version !== 4" in client
    assert "reference_fanout" in client and "max_request_members" in client
    assert "cancelReadBatch" in client and "Promise.all(pages.values())" not in client

    # No interaction may fall back to a whole-country JSON catalog.
    for obsolete in (
        "placeCatalogPromise",
        "loadPlaceCatalog",
        "catalog_file",
        "lookup_ids",
    ):
        assert obsolete not in index, f"obsolete monolithic catalog path remains: {obsolete}"

    assert "metadata.destination_tiles" not in index
    assert "feature.properties.set_id" not in index
    assert "destinationRelations.resolve(" in index
    assert "catalogPages.getSpatialCandidates(lngLat, activeModeMask, {" in index
    assert "catalogPages.resolveReferenceLocations(references, markerIndexes)" in index
    assert "catalogPages.getObjects([placeIndex])" in index, "marker selection is not paged"
    assert "catalogPages.findObjectByPlaceId(placeValue)" in index, "#place restore is not indexed"

    # The unrelated arbitrary-OSM inspector remains its independent lazy
    # vector source and must not be routed through the object catalog.
    inspector = index[index.index("function ensureInspectorLayers()"):
                      index.index("function addPlaceLayers()")]
    assert 'url: `pmtiles://${new URL(inspector.file, location.href).href}`' in inspector
    assert "catalogPages" not in inspector

    print("catalog UI integration contract passed")


if __name__ == "__main__":
    main()
