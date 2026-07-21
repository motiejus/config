#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { randomBytes } = require("node:crypto");
const { gzipSync } = require("node:zlib");
const { CatalogPages, fnv1a32 } = require(process.argv[2] || "./catalog-pages.js");

const manifest = {
  schema_version: 4,
  edge_build_id: "a".repeat(64),
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
    destination_set_members_per_lookup: 4,
    object_location_pages_per_lookup: 1
  },
  spatial: {
    edge_build_id: "a".repeat(64),
    zoom: 15,
    addressing: "XYZ direct tile coordinates in catalog.pmtiles",
    candidate_encoding: "sorted [edge_id,modeMask,deltaE7] arrays",
    neighbor_radius: 1,
    tiles: 2,
    page_size_gate: { raw: 524288, gzip: 65536 },
    fanout_gate: { candidates_per_lookup: 20000, postfilter_relation_pages_per_lookup: 64 },
    fanout_stats: {
      candidates_per_tile_max: 2, relation_pages_per_tile_max: 1,
      candidates_per_lookup_max: 4, relation_pages_per_lookup_raw_max: 2
    },
    page_stats: {}
  },
  collections: {
    objects: { base: 0, count: 4, page_size: 2, pages: 2 },
    place_id_index: { base: 2, count: 256, page_size: 1, pages: 256 },
    "destination_edge_set:coffee:walk:10": {
      base: 258, count: 2, page_size: 2, pages: 1,
      max_request_pages: 1, max_record_members: 2, max_request_members: 4
    },
    object_locations: {
      base: 259, count: 4, page_size: 512, pages: 1, max_request_pages: 1
    }
  }
};

const objects = [
  { index: 0, place_id: "node:10", service: "coffee", lon: 25.1, lat: 54.7 },
  { index: 1, place_id: "node:11", service: "coffee", lon: 25.2, lat: 54.7 },
  { index: 2, place_id: "node:12", service: "coffee", lon: 25.3, lat: 54.7 },
  { index: 3, place_id: "node:13", service: "coffee", lon: 25.4, lat: 54.7 }
];

const bytes = value => new TextEncoder().encode(JSON.stringify(value));

function fakeArchive(options = {}) {
  const calls = [];
  const state = { metadataCalls: 0 };
  let failures = options.failures || 0;
  let badRecordOnce = options.badRecordOnce || false;
  return {
    calls,
    state,
    getMetadata: async () => {
      state.metadataCalls += 1;
      return { ...(options.manifest || manifest), format: "pbf", minzoom: 10, name: "converter-added" };
    },
    getZxy: async (z, x, y) => {
      calls.push({ z, x, y });
      if (z === 15) {
        if (x === 16384 && y === 16384) return { data: bytes([
          [5, 3, [0, 0, 10, 0]], [7, 1, [0, 0, 0, 10]]
        ]) };
        if (x === 16385 && y === 16384) return { data: bytes([
          [7, 2, [0, 0, 0, 10]], [8, 1, [10, 0, 0, 10]]
        ]) };
        return undefined;
      }
      if (x === 0 && failures > 0) {
        failures -= 1;
        throw new Error("transient page failure");
      }
      let value;
      if (x === 0) {
        value = objects.slice(0, 2);
        if (badRecordOnce) {
          badRecordOnce = false;
          value = [{ ...value[0], index: 99 }, value[1]];
        }
      }
      else if (x === 1) value = objects.slice(2, 4);
      else if (x === 258) value = [[1, 2], [0, 2]];
      else if (x === 259) value = [
        [251000000, 547000000, 0, "One", "cafe"],
        [252000000, 547000000, 0, "Two", "cafe"],
        [253000000, 547000000, 0, "Three", "cafe"],
        [254000000, 547000000, 0, "Four", "cafe"]
      ];
      else if (x >= 300 && x < 365) value = [[x - 300]];
      else {
        const bucket = x - 2;
        value = {};
        ["node:12"].forEach(placeId => {
          if (bucket === (fnv1a32(placeId) & 255)) value[placeId] = 2;
        });
      }
      const encoded = bytes(value);
      return { data: options.gzip && x === 0 ? gzipSync(encoded) : encoded };
    }
  };
}

async function main() {
  assert.equal(fnv1a32("hello"), 0x4f9f2cab, "FNV-1a implementation drifted");
  const legacyManifest = structuredClone(manifest);
  legacyManifest.schema_version = 3;
  let archive = fakeArchive({ manifest: legacyManifest });
  let client = new CatalogPages("catalog.pmtiles", legacyManifest, { archive });
  await assert.rejects(client.getObjects([0]), /invalid catalog manifest header/,
    "catalog schema v3 must not be accepted through a compatibility path");

  // One record loads its one page, not the second object page or any index/set page.
  archive = fakeArchive({ gzip: true });
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  assert.equal(archive.state.metadataCalls, 0, "constructor eagerly opened optional catalog");
  assert.deepEqual(archive.calls, []);
  assert.equal((await client.getObjects([0])).get(0).place_id, "node:10");
  assert.deepEqual(archive.calls.map(call => call.x), [0]);

  // Both sides of the advertised size gate are enforced at the decode choke
  // point: compressed bytes before inflation, raw bytes after it.
  let oversized = gzipSync(randomBytes(70_000));
  assert.ok(oversized.length > manifest.spatial.page_size_gate.gzip);
  archive = fakeArchive();
  archive.getZxy = async () => ({ data: oversized });
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await assert.rejects(client.getObjects([0]), /compressed size gate/);

  oversized = gzipSync(bytes(["x".repeat(600_000)]));
  assert.ok(oversized.length < manifest.spatial.page_size_gate.gzip);
  archive = fakeArchive();
  archive.getZxy = async () => ({ data: oversized });
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await assert.rejects(client.getObjects([0]), /raw size gate/);

  // Concurrent/duplicate IDs on one page share the same in-flight page promise.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await Promise.all([client.getObjects([0, 0]), client.getObjects([1])]);
  assert.deepEqual(archive.calls.map(call => call.x), [0]);

  // A PMTiles reader memoizes its header promise. A rejected header must
  // replace the reader itself; retrying getMetadata() on the poisoned reader
  // would fail forever even after the network recovers.
  const healthyArchive = fakeArchive();
  let factoryCalls = 0;
  client = new CatalogPages("catalog.pmtiles", manifest, {
    archiveFactory: () => {
      factoryCalls += 1;
      if (factoryCalls === 1) {
        return {
          getMetadata: async () => { throw new Error("poisoned header"); },
          getZxy: async () => { throw new Error("poisoned reader was reused"); }
        };
      }
      return healthyArchive;
    }
  });
  await assert.rejects(client.getObjects([0]), /poisoned header/);
  assert.equal((await client.getObjects([0])).get(0).place_id, "node:10");
  assert.equal(factoryCalls, 2);
  assert.deepEqual(healthyArchive.calls.map(call => call.x), [0]);

  // Reference stages are ordered so a set/location failure cannot leave
  // later rich-object work running; compact locations remain complete input.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  const resolved = await client.resolveReferenceLocations([
    { collection: "destination_edge_set:coffee:walk:10", id: 0 }
  ], [0]);
  assert.deepEqual(archive.calls.map(call => call.x), [258, 259, 0]);
  assert.deepEqual(resolved.sets.get("destination_edge_set:coffee:walk:10:0"), [1, 2]);
  assert.deepEqual([...resolved.locations.keys()], [0, 1, 2]);
  assert.deepEqual(resolved.locations.get(1), {
    index: 1, lon: 25.2, lat: 54.7, service: "coffee", name: "Two", kind: "cafe"
  });
  assert.deepEqual([...resolved.objects.keys()], [0]);

  // A click safely inside a spatial tile reads only that tile.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  const span = 2 ** 15;
  const lngForTile = value => value / span * 360 - 180;
  const latForTile = value => Math.atan(Math.sinh(Math.PI * (1 - 2 * value / span))) * 180 / Math.PI;
  assert.deepEqual(await client.getSpatialCandidates(
    { lng: lngForTile(16384.5), lat: latForTile(16384.5) }, 1,
    { pixels: 4, zoom: 14 }
  ), [
    { edgeId: 5, modeMask: 1, encoded: [0, 0, 10, 0] },
    { edgeId: 7, modeMask: 1, encoded: [0, 0, 0, 10] }
  ]);
  assert.deepEqual(archive.calls.filter(call => call.z === 15), [
    { z: 15, x: 16384, y: 16384 }
  ]);

  // The published postfilter bound must cover the producer's measured raw
  // relation-page maximum; otherwise even an unfiltered valid lookup can be
  // rejected. Invalid metadata fails before a page read begins.
  const underdeclaredFanout = structuredClone(manifest);
  underdeclaredFanout.spatial.fanout_gate.postfilter_relation_pages_per_lookup = 1;
  archive = fakeArchive({ manifest: underdeclaredFanout });
  client = new CatalogPages("catalog.pmtiles", underdeclaredFanout, { archive });
  await assert.rejects(client.getObjects([0]), /collections are missing/);
  assert.deepEqual(archive.calls, []);

  const excessiveFanoutPermission = structuredClone(manifest);
  excessiveFanoutPermission.spatial.fanout_gate.postfilter_relation_pages_per_lookup = 513;
  archive = fakeArchive({ manifest: excessiveFanoutPermission });
  client = new CatalogPages("catalog.pmtiles", excessiveFanoutPermission, { archive });
  await assert.rejects(client.getObjects([0]), /collections are missing/);
  assert.deepEqual(archive.calls, []);

  // Near the right boundary, only the center and right tiles are needed. The
  // shared edge's mode masks are ORed and inactive drive-only hits filtered.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  assert.deepEqual(await client.getSpatialCandidates(
    { lng: lngForTile(16384.999), lat: latForTile(16384.5) }, 1,
    { pixels: 4, zoom: 14 }
  ), [
    { edgeId: 5, modeMask: 1, encoded: [0, 0, 10, 0] },
    { edgeId: 7, modeMask: 1, encoded: [0, 0, 0, 10] },
    { edgeId: 8, modeMask: 1, encoded: [10, 0, 0, 10] }
  ]);
  assert.deepEqual(archive.calls.filter(call => call.z === 15), [
    { z: 15, x: 16384, y: 16384 }, { z: 15, x: 16385, y: 16384 }
  ]);

  // The producer's fanout statistics cover at most a 2x2 lookup. A corridor
  // wider than half a tile could touch both opposing neighbors (3x3), so it
  // must be rejected instead of silently omitting one side.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await assert.rejects(client.getSpatialCandidates(
    { lng: lngForTile(16384.5), lat: latForTile(16384.5) }, 1,
    { pixels: 0.6 * 512, zoom: 15 }
  ), /exceeds spatial neighbor coverage/);
  assert.deepEqual(archive.calls.filter(call => call.z === 15), []);

  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await client.getSpatialCandidates(
    { lng: 25.2, lat: 54.7 }, 1, { pixels: 4, zoom: 14 }
  );
  const expectedX = Math.floor((25.2 + 180) / 360 * span);
  const expectedY = Math.floor((1 - Math.asinh(Math.tan(54.7 * Math.PI / 180)) / Math.PI) / 2 * span);
  assert.ok(archive.calls.some(call => call.z === 15 && call.x === expectedX && call.y === expectedY),
    "spatial lookup must use XYZ, not flipped TMS y");

  // Range reads share a bounded queue. A corner lookup needs four tiles, but
  // never starts more requests than the configured mobile-friendly bound.
  const base = fakeArchive();
  let activeReads = 0;
  let peakReads = 0;
  archive = {
    ...base,
    getZxy: async (...args) => {
      activeReads += 1;
      peakReads = Math.max(peakReads, activeReads);
      await new Promise(resolve => setTimeout(resolve, 5));
      try { return await base.getZxy(...args); }
      finally { activeReads -= 1; }
    }
  };
  client = new CatalogPages("catalog.pmtiles", manifest, {
    archive, maxConcurrentReads: 2
  });
  await client.getSpatialCandidates(
    { lng: lngForTile(16384.999), lat: latForTile(16384.999) }, 3,
    { pixels: 4, zoom: 14 }
  );
  assert.equal(base.calls.filter(call => call.z === 15).length, 4);
  assert.equal(peakReads, 2);

  // A superseding interaction rejects work that has not started, so a large
  // stale result cannot monopolize the bounded queue.
  base.calls.length = 0;
  let releaseFirst;
  const firstRead = new Promise(resolve => { releaseFirst = resolve; });
  let readNumber = 0;
  archive = {
    ...base,
    getZxy: async (...args) => {
      readNumber += 1;
      base.calls.push({ z: args[0], x: args[1], y: args[2] });
      if (readNumber === 1) await firstRead;
      return fakeArchive().getZxy(...args);
    }
  };
  client = new CatalogPages("catalog.pmtiles", manifest, {
    archive, maxConcurrentReads: 1
  });
  const staleRead = client.getObjects([0, 2]);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(base.calls.length, 1);
  client.cancelQueuedReads();
  releaseFirst();
  await assert.rejects(staleRead, /superseded/);
  assert.equal(base.calls.length, 1);

  // A page failure stops the batch before later pages start. Logical workers
  // detach immediately even though an already-active physical read may drain.
  const failingBatchManifest = structuredClone(manifest);
  failingBatchManifest.collections.batch_records = {
    base: 300, count: 6, page_size: 1, pages: 6, max_request_pages: 6
  };
  const batchCalls = [];
  let failFirst;
  let releaseSecond;
  const firstFailure = new Promise((_resolve, reject) => { failFirst = reject; });
  const secondRead = new Promise(resolve => { releaseSecond = resolve; });
  archive = {
    getMetadata: async () => failingBatchManifest,
    getZxy: async (_z, x) => {
      batchCalls.push(x);
      if (x === 300) await firstFailure;
      if (x === 301) await secondRead;
      return { data: bytes([[x - 300]]) };
    }
  };
  client = new CatalogPages("catalog.pmtiles", failingBatchManifest, {
    archive, maxConcurrentReads: 2
  });
  let batchSettled = false;
  const failedBatch = client.getMany("batch_records", [0, 1, 2, 3, 4, 5])
    .finally(() => { batchSettled = true; });
  const failedBatchRejected = assert.rejects(failedBatch, /first batch page failed/);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(batchCalls, [300, 301]);
  failFirst(new Error("first batch page failed"));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(batchSettled, true, "batch remained coupled to an active physical read");
  assert.deepEqual(batchCalls, [300, 301], "a later page started after the first failure");
  await failedBatchRejected;
  releaseSecond();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(batchCalls, [300, 301]);

  // With the global queue saturated by an unrelated read, a loader failure
  // must cancel its owning batch before releasing the slot. The queued second
  // page never starts, and rejection does not wait for that nonexistent read.
  const saturatedCalls = [];
  let releaseUnrelated;
  let failSaturatedPage;
  const unrelatedHold = new Promise(resolve => { releaseUnrelated = resolve; });
  const saturatedFailure = new Promise((_resolve, reject) => {
    failSaturatedPage = () => reject(new Error("saturated page failed"));
  });
  archive = {
    getMetadata: async () => failingBatchManifest,
    getZxy: async (_z, x) => {
      saturatedCalls.push(x);
      if (x === 0) {
        await unrelatedHold;
        return { data: bytes(objects.slice(0, 2)) };
      }
      if (x === 300) await saturatedFailure;
      if (x === 301) throw new Error("cancelled second page started");
      return { data: bytes([[x - 300]]) };
    }
  };
  client = new CatalogPages("catalog.pmtiles", failingBatchManifest, {
    archive, maxConcurrentReads: 2
  });
  const unrelatedRead = client.getObjects([0]);
  await new Promise(resolve => setImmediate(resolve));
  const saturatedBatch = client.getMany("batch_records", [0, 1]);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(saturatedCalls, [0, 300]);
  failSaturatedPage();
  await assert.rejects(saturatedBatch, /saturated page failed/);
  assert.deepEqual(saturatedCalls, [0, 300]);
  releaseUnrelated();
  await unrelatedRead;

  // Successful transport/decode is not enough: page-shape validation remains
  // inside the scheduler slot, so malformed data cancels the batch before the
  // queued sibling can start.
  const malformedCalls = [];
  let releaseMalformedHold;
  const malformedHold = new Promise(resolve => { releaseMalformedHold = resolve; });
  archive = {
    getMetadata: async () => failingBatchManifest,
    getZxy: async (_z, x) => {
      malformedCalls.push(x);
      if (x === 0) {
        await malformedHold;
        return { data: bytes(objects.slice(0, 2)) };
      }
      if (x === 300) return { data: bytes({ malformed: true }) };
      if (x === 301) throw new Error("malformed batch sibling started");
      return { data: bytes([[x - 300]]) };
    }
  };
  client = new CatalogPages("catalog.pmtiles", failingBatchManifest, {
    archive, maxConcurrentReads: 2
  });
  const malformedHeldRead = client.getObjects([0]);
  await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(
    client.getMany("batch_records", [0, 1]),
    /batch_records page 0 is not an array/
  );
  assert.deepEqual(malformedCalls, [0, 300]);
  releaseMalformedHold();
  await malformedHeldRead;

  // If another request consumes a queued in-flight page, cancellation of the
  // original owner removes only that owner. The shared physical read remains
  // queued, starts when capacity opens, and satisfies the unrelated consumer.
  const sharedCalls = [];
  let releaseSharedHold;
  let failSharedOwner;
  let releaseSharedPage;
  const sharedHold = new Promise(resolve => { releaseSharedHold = resolve; });
  const sharedOwnerFailure = new Promise((_resolve, reject) => {
    failSharedOwner = () => reject(new Error("shared owner failed"));
  });
  const sharedPage = new Promise(resolve => { releaseSharedPage = resolve; });
  archive = {
    getMetadata: async () => failingBatchManifest,
    getZxy: async (_z, x) => {
      sharedCalls.push(x);
      if (x === 0) {
        await sharedHold;
        return { data: bytes(objects.slice(0, 2)) };
      }
      if (x === 300) await sharedOwnerFailure;
      if (x === 301) await sharedPage;
      return { data: bytes([[x - 300]]) };
    }
  };
  client = new CatalogPages("catalog.pmtiles", failingBatchManifest, {
    archive, maxConcurrentReads: 2
  });
  const heldSharedRead = client.getObjects([0]);
  await new Promise(resolve => setImmediate(resolve));
  const sharedOwner = client.getMany("batch_records", [0, 1]);
  await new Promise(resolve => setImmediate(resolve));
  const sharedConsumer = client.getMany("batch_records", [1]);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(sharedCalls, [0, 300]);
  const ownerRejected = assert.rejects(sharedOwner, /shared owner failed/);
  failSharedOwner();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(sharedCalls, [0, 300, 301]);
  await ownerRejected;
  releaseSharedPage();
  assert.equal((await sharedConsumer).get(1)[0], 1);
  releaseSharedHold();
  await heldSharedRead;
  assert.deepEqual(sharedCalls, [0, 300, 301]);

  // Aggregate set-page fanout is preflighted before any set page is queued.
  const oneCandidateManifest = structuredClone(manifest);
  oneCandidateManifest.spatial.fanout_stats.candidates_per_tile_max = 1;
  oneCandidateManifest.spatial.fanout_stats.candidates_per_lookup_max = 1;
  oneCandidateManifest.collections["destination_edge_set:coffee:walk:10"] = {
    base: 258, count: 6, page_size: 2, pages: 3,
    max_request_pages: 1, max_record_members: 2, max_request_members: 2
  };
  oneCandidateManifest.collections.object_locations.base = 261;
  oneCandidateManifest.reference_fanout.destination_set_pages_per_lookup = 1;
  oneCandidateManifest.reference_fanout.destination_set_members_per_lookup = 2;
  archive = fakeArchive({ manifest: oneCandidateManifest });
  client = new CatalogPages("catalog.pmtiles", oneCandidateManifest, { archive });
  await assert.rejects(client.resolveReferenceLocations([
    { collection: "destination_edge_set:coffee:walk:10", id: 0 },
    { collection: "destination_edge_set:coffee:walk:10", id: 2 }
  ]), /exceeds 1 pages/);
  assert.deepEqual(archive.calls, []);

  // A set whose decoded membership exceeds the producer's record bound fails
  // before object-location or rich-object work can start.
  const boundedMemberManifest = structuredClone(manifest);
  boundedMemberManifest.collections["destination_edge_set:coffee:walk:10"].max_record_members = 1;
  boundedMemberManifest.collections["destination_edge_set:coffee:walk:10"].max_request_members = 2;
  boundedMemberManifest.reference_fanout.destination_set_members_per_lookup = 2;
  archive = fakeArchive({ manifest: boundedMemberManifest });
  client = new CatalogPages("catalog.pmtiles", boundedMemberManifest, { archive });
  await assert.rejects(client.resolveReferenceLocations([
    { collection: "destination_edge_set:coffee:walk:10", id: 0 }
  ], [0]), /invalid destination set/);
  assert.deepEqual(archive.calls.map(call => call.x), [258]);

  // Compact locations must publish their complete artifact page fanout so
  // extra marker IDs cannot make a valid set+marker lookup exceed metadata.
  // An underdeclared location gate fails manifest validation before any read.
  const locationBoundManifest = structuredClone(manifest);
  locationBoundManifest.collections.objects = {
    base: 0, count: 1025, page_size: 64, pages: 17
  };
  locationBoundManifest.collections.place_id_index.base = 17;
  locationBoundManifest.collections["destination_edge_set:coffee:walk:10"] = {
    base: 273, count: 1, page_size: 1, pages: 1,
    max_request_pages: 1, max_record_members: 1, max_request_members: 1
  };
  locationBoundManifest.collections.object_locations = {
    base: 274, count: 1025, page_size: 512, pages: 3, max_request_pages: 1
  };
  locationBoundManifest.spatial.fanout_stats.candidates_per_tile_max = 1;
  locationBoundManifest.spatial.fanout_stats.candidates_per_lookup_max = 1;
  locationBoundManifest.reference_fanout = {
    destination_set_pages_per_lookup: 1,
    destination_set_members_per_lookup: 1,
    object_location_pages_per_lookup: 1
  };
  archive = fakeArchive({ manifest: locationBoundManifest });
  client = new CatalogPages("catalog.pmtiles", locationBoundManifest, { archive });
  await assert.rejects(
    client.resolveReferenceLocations([], [0, 512]),
    /collections are missing/
  );
  assert.deepEqual(archive.calls, []);

  // The producer-derived page/member/location maxima are permissions, not
  // small static caps: a valid request exactly at every advertised bound works.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  const atBound = await client.resolveReferenceLocations([
    { collection: "destination_edge_set:coffee:walk:10", id: 0 },
    { collection: "destination_edge_set:coffee:walk:10", id: 1 }
  ]);
  assert.equal(atBound.sets.size, 2);
  assert.deepEqual([...atBound.locations.keys()].sort((left, right) => left - right), [0, 1, 2]);
  assert.deepEqual(archive.calls.map(call => call.x), [258, 259]);

  // Spatial churn has its own LRU and cannot evict a hot metadata page.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, {
    archive, maxCachedPages: 1, maxCachedSpatialPages: 1
  });
  await client.getObjects([0]);
  await client.getSpatialCandidates(
    { lng: lngForTile(16384.999), lat: latForTile(16384.5) }, 1,
    { pixels: 4, zoom: 14 }
  );
  await client.getObjects([0]);
  assert.equal(archive.calls.filter(call => call.z === 10 && call.x === 0).length, 1);

  // The producer may publish a measured raw bound above the old static 64
  // pages. A request within that declared artifact bound remains valid.
  const measuredRelations = structuredClone(manifest);
  measuredRelations.collections.renamed_edges = {
    base: 300, count: 65, page_size: 1, pages: 65, max_request_pages: 65
  };
  archive = fakeArchive({ manifest: measuredRelations });
  client = new CatalogPages("catalog.pmtiles", measuredRelations, { archive });
  assert.equal((await client.getMany(
    "renamed_edges", Array.from({ length: 65 }, (_value, index) => index)
  )).size, 65);
  assert.equal(archive.calls.length, 65);

  // Exceeding the declared bound is still rejected before any page is queued.
  const excessiveRelations = structuredClone(measuredRelations);
  excessiveRelations.collections.renamed_edges.max_request_pages = 64;
  archive = fakeArchive({ manifest: excessiveRelations });
  client = new CatalogPages("catalog.pmtiles", excessiveRelations, { archive });
  await assert.rejects(
    client.getMany("renamed_edges", Array.from({ length: 65 }, (_value, index) => index)),
    /exceeds 64 pages/
  );
  assert.deepEqual(archive.calls, []);

  // In-flight reads dedupe independently of a one-page LRU; successful pages
  // evict by recency and are fetched again, while concurrent callers share.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive, maxCachedPages: 1 });
  await Promise.all([client.getObjects([0]), client.getObjects([1])]);
  assert.deepEqual(archive.calls.map(call => call.x), [0]);
  await client.getObjects([2]);
  await client.getObjects([0]);
  assert.deepEqual(archive.calls.map(call => call.x), [0, 1, 0]);

  const overlapping = structuredClone(manifest);
  overlapping.collections.object_locations.base = 1;
  client = new CatalogPages("catalog.pmtiles", overlapping, { archive: fakeArchive() });
  await assert.rejects(client.getObjects([0]), /overlapping catalog collections/);

  // A rejected page is evicted, so the next explicit interaction retries it.
  archive = fakeArchive({ failures: 1 });
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await assert.rejects(client.getObjects([0]), /transient page failure/);
  assert.equal((await client.getObjects([0])).get(0).index, 0);
  assert.deepEqual(archive.calls.map(call => call.x), [0, 0]);

  // A decoded page with broken record identity is likewise evicted.
  archive = fakeArchive({ badRecordOnce: true });
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  await assert.rejects(client.getObjects([0]), /invalid object record 0/);
  assert.equal((await client.getObjects([0])).get(0).index, 0);
  assert.deepEqual(archive.calls.map(call => call.x), [0, 0]);

  // Stable #place lookup reads one hash bucket and then only its object page.
  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  assert.equal((await client.findObjectByPlaceId("node:12")).index, 2);
  assert.deepEqual(archive.calls.map(call => call.x), [2 + (fnv1a32("node:12") & 255), 1]);

  archive = fakeArchive();
  client = new CatalogPages("catalog.pmtiles", manifest, { archive });
  assert.deepEqual(
    (await client.getDestinationSets("destination_edge_set:coffee:walk:10", [1])).get(1),
    [0, 2]
  );
  assert.deepEqual(archive.calls.map(call => call.x), [258]);

  console.log("catalog page client runtime checks passed");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
