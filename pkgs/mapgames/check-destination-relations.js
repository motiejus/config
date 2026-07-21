#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const {
  DestinationRelations,
  closestCanonicalPoint,
  decodeCoordinates,
  haversineMeters,
  selectedSet
} = require(process.argv[2] || "./destination-relations.js");
const { CatalogPages } = require(process.argv[3] || "./catalog-pages.js");

const buildId = "a".repeat(64);
const catalogFile = `catalog-${"b".repeat(64)}.pmtiles`;
const configuration = {
  schema_version: 3,
  edge_build_id: buildId,
  hit: {
    file: catalogFile,
    zoom: 15,
    addressing: "XYZ direct tile coordinates in catalog.pmtiles",
    candidate_encoding: "sorted [edge_id,modeMask,deltaE7] arrays",
    neighbor_radius: 1,
    mode_bits: { walk: 1, drive: 2 }
  },
  edge_collection: "destination_edges",
  edge_count: 8,
  requirements: [{
    key: "coffee|walk",
    service: "coffee",
    mode: "walk",
    mode_bit: 1,
    presets: [{
      minutes: 10,
      set_collection: "destination_edge_set:coffee:walk:10",
      set_count: 6
    }]
  }],
  coordinate_encoding: {
    scale: 10_000_000,
    order: "lon_lat",
    delta: "first_pair_absolute_then_signed_deltas"
  },
  fraction_semantics: "closed_source_intervals; exact breakpoint override; open interior runs"
};

const geometry = [0, 0, 10_000_000, 0, 10_000_000, 0];
const relation = [
  1,
  [[0, [[10, [[0, 0.5, 3], [0.5, 1, 4]], [[0, 1], [0.5, 2], [1, 5]]]]]]
];

const project = ([x, y]) => ({ x: x * 100, y: y * 100 });
const webMercatorProject = ([lng, lat], zoom = 0) => {
  const worldSize = 512 * 2 ** zoom;
  const latitude = lat * Math.PI / 180;
  return {
    x: (lng + 180) / 360 * worldSize,
    y: (1 - Math.asinh(Math.tan(latitude)) / Math.PI) / 2 * worldSize
  };
};
const webMercatorUnproject = ({ x, y }, zoom = 0) => {
  const worldSize = 512 * 2 ** zoom;
  return {
    lng: x / worldSize * 360 - 180,
    lat: Math.atan(Math.sinh(Math.PI * (1 - 2 * y / worldSize))) * 180 / Math.PI
  };
};
const selection = [{ key: "coffee|walk", service: "coffee", mode: "walk", minutes: 10 }];
const candidate = (edgeId = 7, modeMask = 1, encoded = geometry) =>
  ({ edgeId, modeMask, encoded });

function fakeCatalog(record = relation, manifestBuild = buildId, maxRequestPages = 64) {
  const calls = [];
  const manifest = () => {
    const edgeCollection = { count: 8 };
    if (maxRequestPages !== "missing") {
      edgeCollection.max_request_pages = maxRequestPages;
    }
    return {
      edge_build_id: manifestBuild,
      spatial: { fanout_gate: { postfilter_relation_pages_per_lookup: 64 } },
      collections: {
        destination_edges: edgeCollection,
        "destination_edge_set:coffee:walk:10": { count: 6 }
      }
    };
  };
  return {
    calls,
    manifest: async () => manifest(),
    getMany: async (collection, ids, validate) => {
      calls.push({ collection, ids: [...ids] });
      const result = new Map();
      [...new Set(ids)].forEach(id => {
        validate(record, id, manifest(), true);
        result.set(id, record);
      });
      return result;
    }
  };
}

async function main() {
  assert.throws(
    () => new DestinationRelations(fakeCatalog(), { ...configuration, schema_version: 2 }),
    /invalid shared destination lookup metadata/,
    "destination relation schema v2 must not be accepted through a compatibility path"
  );
  assert.deepEqual(decodeCoordinates(geometry, 10_000_000), [[0, 0], [1, 0], [2, 0]]);
  const midpoint = closestCanonicalPoint({ lng: 1, lat: 0 }, [[0, 0], [1, 0], [2, 0]], project);
  assert.equal(midpoint.fraction, 0.5, "canonical vertex must reproduce exact breakpoint");
  const highLatitudeLine = [[0, 60], [20, 80], [40, 60]];
  const offLine = closestCanonicalPoint(
    { lng: 27, lat: 72 }, highLatitudeLine, webMercatorProject
  );
  const firstLength = haversineMeters(highLatitudeLine[0], highLatitudeLine[1]);
  const secondLength = haversineMeters(highLatitudeLine[1], highLatitudeLine[2]);
  const secondLeft = webMercatorProject(highLatitudeLine[1]);
  const secondRight = webMercatorProject(highLatitudeLine[2]);
  const offLineTarget = webMercatorProject([27, 72]);
  const secondDx = secondRight.x - secondLeft.x;
  const secondDy = secondRight.y - secondLeft.y;
  const secondRenderedT = ((offLineTarget.x - secondLeft.x) * secondDx +
    (offLineTarget.y - secondLeft.y) * secondDy) / (secondDx ** 2 + secondDy ** 2);
  assert.ok(secondRenderedT > 0 && secondRenderedT < 1);
  assert.ok(offLine.fraction > firstLength / (firstLength + secondLength),
    "projected distance must select the second rendered segment");
  assert.ok(offLine.projected.x > webMercatorProject(highLatitudeLine[1]).x,
    "off-line snap must retain the projected closest point on the selected segment");
  assert.equal(selectedSet(relation[1][0][1][0], 0.5), 2, "breakpoint override must win");
  assert.equal(selectedSet(relation[1][0][1][0], 0.25), 3);
  assert.equal(selectedSet(relation[1][0][1][0], 0.5000000001), 4,
    "non-exact value must use the open interior run");
  const diagonalCrossTrack = closestCanonicalPoint(
    { lng: 0.97, lat: 1.03 }, [[0, 0], [2, 2]], project
  );
  assert.equal(diagonalCrossTrack.fraction, 0.5,
    "perpendicular click offset must not perturb a diagonal's along-edge fraction");
  assert.ok(diagonalCrossTrack.distance < 6,
    "diagonal regression must remain inside the production click corridor");

  // At Lithuania's latitude, projecting an off-line click back onto the
  // segment in raw lon/lat moves it well past the midpoint. The rendered
  // Web-Mercator chord still has an unambiguous midpoint. Offsetting a click
  // six screen pixels perpendicular to it must not change the recovered
  // producer-native along-segment position.
  const lithuaniaEdge = [[25, 55], [25.001, 55.001]];
  const lithuaniaZoom = 15;
  const lithuaniaProject = coordinate => webMercatorProject(coordinate, lithuaniaZoom);
  const lithuaniaLeft = lithuaniaProject(lithuaniaEdge[0]);
  const lithuaniaRight = lithuaniaProject(lithuaniaEdge[1]);
  const lithuaniaDx = lithuaniaRight.x - lithuaniaLeft.x;
  const lithuaniaDy = lithuaniaRight.y - lithuaniaLeft.y;
  const lithuaniaLength = Math.hypot(lithuaniaDx, lithuaniaDy);
  const renderedMidpoint = {
    x: (lithuaniaLeft.x + lithuaniaRight.x) / 2,
    y: (lithuaniaLeft.y + lithuaniaRight.y) / 2
  };
  const crossTrackClick = webMercatorUnproject({
    x: renderedMidpoint.x - lithuaniaDy / lithuaniaLength * 6,
    y: renderedMidpoint.y + lithuaniaDx / lithuaniaLength * 6
  }, lithuaniaZoom);
  const renderedMidpointClick = webMercatorUnproject(renderedMidpoint, lithuaniaZoom);
  const renderedMidpointSnap = closestCanonicalPoint(
    renderedMidpointClick, lithuaniaEdge, lithuaniaProject
  );
  const highLatitudeCrossTrack = closestCanonicalPoint(
    crossTrackClick, lithuaniaEdge, lithuaniaProject
  );
  assert.ok(Math.abs(
    highLatitudeCrossTrack.fraction - renderedMidpointSnap.fraction
  ) < 1e-10, "cross-track offset must not perturb the producer-native position");
  assert.ok(Math.abs(highLatitudeCrossTrack.distance - 6) < 1e-8,
    "high-latitude regression must exercise the six-pixel click corridor");

  // A longer segment makes the native-linear Web-Mercator curve visibly
  // depart from its rendered endpoint chord. The click is nevertheless the
  // producer's exact native midpoint and must recover exact breakpoint 0.5.
  const longLithuaniaEdge = [[25, 55], [25.15, 55.15]];
  let longProjectionCalls = 0;
  const longLithuaniaProject = coordinate => {
    longProjectionCalls += 1;
    return webMercatorProject(coordinate, lithuaniaZoom);
  };
  const longNativeMidpoint = { lng: 25.075, lat: 55.075 };
  const longMidpointSnap = closestCanonicalPoint(
    longNativeMidpoint, longLithuaniaEdge, longLithuaniaProject
  );
  assert.equal(longMidpointSnap.fraction, 0.5,
    "long projected curves must recover the producer's exact native midpoint");
  assert.ok(Math.abs(longMidpointSnap.distance - 2.843228541) < 1e-6,
    "long-segment regression must exercise material curve/chord separation");
  assert.ok(longProjectionCalls <= 27,
    "native fraction inversion must have a fixed projection-call bound");
  const longLeft = webMercatorProject(longLithuaniaEdge[0], lithuaniaZoom);
  const longRight = webMercatorProject(longLithuaniaEdge[1], lithuaniaZoom);
  const longDx = longRight.x - longLeft.x;
  const longDy = longRight.y - longLeft.y;
  const longLength = Math.hypot(longDx, longDy);
  const longNativeMidpointProjected = webMercatorProject(
    [longNativeMidpoint.lng, longNativeMidpoint.lat], lithuaniaZoom
  );
  const onePixelAlongClick = webMercatorUnproject({
    x: longNativeMidpointProjected.x + longDx / longLength,
    y: longNativeMidpointProjected.y + longDy / longLength
  }, lithuaniaZoom);
  const onePixelAlongSnap = closestCanonicalPoint(
    onePixelAlongClick, longLithuaniaEdge,
    coordinate => webMercatorProject(coordinate, lithuaniaZoom)
  );
  assert.ok(Math.abs(onePixelAlongSnap.fraction - 0.5000710785) < 1e-10,
    "one-pixel along-edge fixture must straddle the midpoint breakpoint");
  assert.ok(Math.abs(Math.hypot(
    onePixelAlongSnap.projected.x - longNativeMidpointProjected.x,
    onePixelAlongSnap.projected.y - longNativeMidpointProjected.y
  ) - 3.013958947) < 1e-6,
    "fixture must expose curve/chord distance larger than the two-pixel halo");
  longProjectionCalls = 0;
  const longArbitraryFraction = 0.37;
  const longArbitrarySnap = closestCanonicalPoint({
    lng: longLithuaniaEdge[0][0] +
      (longLithuaniaEdge[1][0] - longLithuaniaEdge[0][0]) * longArbitraryFraction,
    lat: longLithuaniaEdge[0][1] +
      (longLithuaniaEdge[1][1] - longLithuaniaEdge[0][1]) * longArbitraryFraction
  }, longLithuaniaEdge, longLithuaniaProject);
  assert.ok(Math.abs(longArbitrarySnap.fraction - longArbitraryFraction) < 3e-8,
    "bounded inversion must agree with arbitrary producer-native fractions");
  assert.ok(longProjectionCalls <= 27,
    "non-dyadic inversion must retain the fixed projection-call bound");
  const weightedLongEdge = [[25, 55], [25.15, 55.15], [25.3, 55]];
  const weightedWithin = 0.37;
  const weightedSnap = closestCanonicalPoint({
    lng: weightedLongEdge[1][0] +
      (weightedLongEdge[2][0] - weightedLongEdge[1][0]) * weightedWithin,
    lat: weightedLongEdge[1][1] +
      (weightedLongEdge[2][1] - weightedLongEdge[1][1]) * weightedWithin
  }, weightedLongEdge, coordinate => webMercatorProject(coordinate, lithuaniaZoom));
  const weightedFirstLength = haversineMeters(weightedLongEdge[0], weightedLongEdge[1]);
  const weightedSecondLength = haversineMeters(weightedLongEdge[1], weightedLongEdge[2]);
  const expectedWeightedFraction = (weightedFirstLength +
    weightedWithin * weightedSecondLength) /
    (weightedFirstLength + weightedSecondLength);
  assert.ok(Math.abs(weightedSnap.fraction - expectedWeightedFraction) < 3e-8,
    "long multi-segment fractions must retain producer haversine weighting");

  let catalog = fakeCatalog();
  let resolver = new DestinationRelations(catalog, configuration);
  const lithuaniaGeometry = [250_000_000, 550_000_000, 10_000, 10_000];
  let references = await resolver.resolve(
    [candidate(7, 1, lithuaniaGeometry)], crossTrackClick, selection,
    lithuaniaProject, { walk: 6.01, drive: 6.01 }
  );
  assert.equal(references[0]?.id, 2,
    "six-pixel high-latitude cross-track click must resolve the midpoint breakpoint set");
  catalog.calls.length = 0;
  const longLithuaniaGeometry = [250_000_000, 550_000_000, 1_500_000, 1_500_000];
  references = await resolver.resolve(
    [candidate(7, 1, longLithuaniaGeometry)], longNativeMidpoint, selection,
    coordinate => webMercatorProject(coordinate, lithuaniaZoom),
    { walk: 6, drive: 6 }
  );
  assert.equal(references[0]?.id, 2,
    "long-segment native midpoint must resolve the exact breakpoint set");
  catalog.calls.length = 0;
  references = await resolver.resolve(
    [candidate(7, 1, longLithuaniaGeometry)], onePixelAlongClick, selection,
    coordinate => webMercatorProject(coordinate, lithuaniaZoom),
    { walk: 6, drive: 6 }
  );
  assert.equal(references[0]?.id, 2,
    "one-pixel along long chord must remain inside the breakpoint halo");
  catalog.calls.length = 0;
  references = await resolver.resolve(
    [candidate(), candidate()],
    { lng: 1, lat: 0 }, selection, project, { walk: 6, drive: 6 }
  );
  assert.deepEqual(references, [{
    collection: "destination_edge_set:coffee:walk:10",
    id: 2,
    service: "coffee",
    mode: "walk",
    minutes: 10
  }]);
  assert.deepEqual(catalog.calls, [{ collection: "destination_edges", ids: [7] }],
    "duplicate buffered hit features must share one edge relation read");
  catalog.calls.length = 0;

  for (const [lngLat, expectedSet, description] of [
    [{ lng: 0.97, lat: 0 }, 3, "clear point before a breakpoint must use its open run"],
    [{ lng: 1.03, lat: 0 }, 4, "clear point after a breakpoint must use its open run"],
    [{ lng: 1.015, lat: 0.005 }, 2,
      "a quantized point within two screen pixels must use the breakpoint override"],
    [{ lng: 1.025, lat: 0.005 }, 4,
      "a point outside the breakpoint halo must remain in its open run"]
  ]) {
    references = await resolver.resolve(
      [candidate()], lngLat, selection, project, { walk: 6, drive: 6 }
    );
    assert.equal(references[0]?.id, expectedSet, description);
  }
  catalog.calls.length = 0;

  for (const invalidPageGate of ["missing", 65]) {
    const invalidCatalog = fakeCatalog(relation, buildId, invalidPageGate);
    const invalidResolver = new DestinationRelations(invalidCatalog, configuration);
    await assert.rejects(
      invalidResolver.resolve(
        [candidate()], { lng: 1, lat: 0 }, selection, project, { walk: 6, drive: 6 }
      ),
      /collection fanout mismatch/
    );
    assert.deepEqual(invalidCatalog.calls, [], "invalid fanout must fail before page reads");
  }

  // A real CatalogPages read validates every record in a fetched relation
  // page, including structurally valid unrequested neighbors.
  const pageManifest = {
    schema_version: 4,
    edge_build_id: buildId,
    page_zoom: 10,
    page_addressing: "XYZ z=10, x=collection.base+page, y=0",
    hash: { name: "fnv1a32-utf8", buckets: 256 },
    object_locations: {
      collection: "object_locations",
      encoding: "[lonE7,latE7,serviceOrdinal,displayLabel,kind]",
      service_ordinals: ["coffee"]
    },
    reference_fanout: {
      destination_set_pages_per_lookup: 1,
      destination_set_members_per_lookup: 1,
      object_location_pages_per_lookup: 1
    },
    spatial: {
      edge_build_id: buildId,
      zoom: 15,
      addressing: "XYZ direct tile coordinates in catalog.pmtiles",
      candidate_encoding: "sorted [edge_id,modeMask,deltaE7] arrays",
      neighbor_radius: 1,
      tiles: 1,
      page_size_gate: { raw: 524288, gzip: 65536 },
      fanout_gate: { candidates_per_lookup: 20000, postfilter_relation_pages_per_lookup: 1 },
      fanout_stats: {
        candidates_per_tile_max: 1,
        relation_pages_per_tile_max: 1,
        candidates_per_lookup_max: 1,
        relation_pages_per_lookup_raw_max: 1
      },
      page_stats: {}
    },
    collections: {
      objects: { base: 0, count: 1, page_size: 1, pages: 1 },
      place_id_index: { base: 1, count: 256, page_size: 1, pages: 256 },
      object_locations: {
        base: 257, count: 1, page_size: 512, pages: 1, max_request_pages: 1
      },
      destination_edges: {
        base: 258, count: 2, page_size: 2, pages: 1, max_request_pages: 1
      },
      "destination_edge_set:coffee:walk:10": {
        base: 259, count: 6, page_size: 6, pages: 1,
        max_request_pages: 1, max_record_members: 1, max_request_members: 1
      }
    }
  };
  const neighbor = [1, []];
  const encoder = new TextEncoder();
  const realCatalog = new CatalogPages("catalog.pmtiles", pageManifest, {
    archive: {
      getMetadata: async () => pageManifest,
      getZxy: async (_z, x) => {
        if (x === pageManifest.collections.destination_edges.base) {
          return { data: encoder.encode(JSON.stringify([relation, neighbor])) };
        }
        throw new Error(`unexpected catalog page ${x}`);
      }
    }
  });
  resolver = new DestinationRelations(realCatalog, { ...configuration, edge_count: 2 });
  references = await resolver.resolve(
    [candidate(0)], { lng: 1, lat: 0 }, selection, project, { walk: 6, drive: 6 }
  );
  assert.equal(references[0].id, 2);
  const structurallyBadNeighbor = [1, [[0]]];
  const badPageCatalog = new CatalogPages("catalog.pmtiles", pageManifest, {
    archive: {
      getMetadata: async () => pageManifest,
      getZxy: async (_z, x) => {
        if (x === pageManifest.collections.destination_edges.base) {
          return { data: encoder.encode(JSON.stringify([relation, structurallyBadNeighbor])) };
        }
        throw new Error(`unexpected catalog page ${x}`);
      }
    }
  });
  resolver = new DestinationRelations(badPageCatalog, { ...configuration, edge_count: 2 });
  await assert.rejects(
    resolver.resolve(
      [candidate(0)], { lng: 1, lat: 0 }, selection, project, { walk: 6, drive: 6 }
    ),
    /invalid route/,
    "unrequested records sharing the fetched page must still be structurally validated"
  );

  references = await resolver.resolve(
    [candidate()],
    { lng: 0.25, lat: 0.2 }, selection, project, { walk: 10, drive: 10 }
  );
  assert.deepEqual(references, [], "canonical geometry outside the hit corridor must be rejected");
  assert.deepEqual(catalog.calls, [], "far spatial candidates must not fetch relation pages");

  const farCandidates = Array.from({ length: 1000 }, (_value, edgeId) =>
    candidate(edgeId, 1, [10_000_000, 10_000_000, 10_000_000, 0])
  );
  references = await resolver.resolve(
    farCandidates, { lng: 0, lat: 0 }, selection, project, { walk: 6, drive: 6 }
  );
  assert.deepEqual(references, []);
  assert.deepEqual(catalog.calls, [], "large far candidate sets must remain network-free");

  catalog = fakeCatalog(relation, "b".repeat(64));
  resolver = new DestinationRelations(catalog, configuration);
  await assert.rejects(
    resolver.resolve([candidate(0)], { lng: 0, lat: 0 }, selection, project,
      { walk: 6, drive: 6 }),
    /build mismatch/
  );

  catalog = fakeCatalog([1, geometry, relation[1]]);
  resolver = new DestinationRelations(catalog, configuration);
  await assert.rejects(
    resolver.resolve([candidate(0)], { lng: 0, lat: 0 }, selection, project,
      { walk: 6, drive: 6 }),
    /invalid destination edge relation/,
    "legacy three-field relation records must fail closed"
  );

  catalog = fakeCatalog();
  resolver = new DestinationRelations(catalog, configuration);
  await assert.rejects(
    resolver.resolve([candidate(7, 3)], { lng: 1, lat: 0 }, selection, project,
      { walk: 6, drive: 6 }),
    /mode mismatch/,
    "a stale hit mode mask must fail closed instead of suppressing a route"
  );

  const badSet = structuredClone(relation);
  badSet[1][0][1][0][2][1][1] = 6;
  catalog = fakeCatalog(badSet);
  resolver = new DestinationRelations(catalog, configuration);
  await assert.rejects(
    resolver.resolve([candidate()], { lng: 1, lat: 0 }, selection, project,
      { walk: 6, drive: 6 }),
    /breakpoint/,
    "set IDs must be bounded by their manifest collection"
  );

  console.log("shared destination relation runtime checks passed");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
