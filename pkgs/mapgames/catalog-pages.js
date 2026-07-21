(function (root) {
  "use strict";

  const textDecoder = new TextDecoder("utf-8", { fatal: true });

  function isInteger(value, minimum = 0) {
    return Number.isSafeInteger(value) && value >= minimum;
  }

  function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (value && typeof value === "object") {
      return `{${Object.keys(value).sort().map(key =>
        `${JSON.stringify(key)}:${canonical(value[key])}`
      ).join(",")}}`;
    }
    return JSON.stringify(value);
  }

  function fnv1a32(value) {
    const bytes = new TextEncoder().encode(value);
    let hash = 0x811c9dc5;
    bytes.forEach(byte => {
      hash ^= byte;
      hash = Math.imul(hash, 0x01000193) >>> 0;
    });
    return hash >>> 0;
  }

  function contractFields(value) {
    return {
      schema_version: value?.schema_version,
      page_zoom: value?.page_zoom,
      page_addressing: value?.page_addressing,
      hash: value?.hash,
      collections: value?.collections,
      edge_build_id: value?.edge_build_id,
      object_locations: value?.object_locations,
      spatial: value?.spatial
    };
  }

  async function jsonFromBytes(bytes, gate) {
    let data = bytes;
    if (!(data instanceof Uint8Array)) data = new Uint8Array(data);
    // PMTiles normally applies its declared tile decompression before
    // returning getZxy(). Keep gzip support here too so the page contract is
    // explicit and remains usable with simple archive/test adapters.
    if (data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b) {
      if (data.length > gate.gzip) {
        throw new Error(`catalog page exceeds compressed size gate (${data.length} > ${gate.gzip})`);
      }
      if (typeof DecompressionStream !== "function") {
        throw new Error("catalog page is gzip-compressed but DecompressionStream is unavailable");
      }
      const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream("gzip"));
      data = new Uint8Array(await new Response(stream).arrayBuffer());
    }
    if (data.length > gate.raw) {
      throw new Error(`catalog page exceeds raw size gate (${data.length} > ${gate.raw})`);
    }
    return JSON.parse(textDecoder.decode(data));
  }

  class CatalogPages {
    constructor(url, declaredManifest, options = {}) {
      if (!declaredManifest || typeof declaredManifest !== "object") {
        throw new Error("catalog manifest is missing");
      }
      this.url = url;
      this.declared = declaredManifest;
      if (options.archiveFactory !== undefined && typeof options.archiveFactory !== "function") {
        throw new Error("catalog archiveFactory must be a function");
      }
      this.archiveFactory = options.archiveFactory || (options.archive
        ? () => options.archive
        : () => new root.pmtiles.PMTiles(url));
      this.archive = this.archiveFactory();
      this.maxCachedPages = options.maxCachedPages === undefined ? 24 : options.maxCachedPages;
      this.maxCachedSpatialPages = options.maxCachedSpatialPages === undefined
        ? 8 : options.maxCachedSpatialPages;
      this.maxConcurrentReads = options.maxConcurrentReads === undefined
        ? 4 : options.maxConcurrentReads;
      if (!isInteger(this.maxCachedPages) || !isInteger(this.maxCachedSpatialPages) ||
          !isInteger(this.maxConcurrentReads, 1) || this.maxConcurrentReads > 8) {
        throw new Error("invalid catalog read/cache bound");
      }
      this.inFlightPages = new Map();
      this.pageCache = new Map();
      this.inFlightSpatialPages = new Map();
      this.spatialPageCache = new Map();
      this.readQueue = [];
      this.activeReads = 0;
      this.archiveGeneration = 0;
      this.manifestPromise = undefined;
    }

    async manifest() {
      if (!this.manifestPromise) {
        const archive = this.archive;
        const manifestPromise = archive.getMetadata()
          .then(archiveManifest => {
            this.validateManifest(this.declared);
            // pmtiles convert adds ordinary TileJSON keys (format, bounds,
            // minzoom, etc.). They are not part of this application contract.
            if (canonical(contractFields(archiveManifest)) !==
                canonical(contractFields(this.declared))) {
              throw new Error("catalog archive metadata does not match metadata.json");
            }
            return this.declared;
          })
          .catch(error => {
            if (this.manifestPromise === manifestPromise) {
              this.manifestPromise = undefined;
              this.inFlightPages.clear();
              this.pageCache.clear();
              this.inFlightSpatialPages.clear();
              this.spatialPageCache.clear();
              this.archiveGeneration += 1;
              const stale = this.readQueue.splice(0);
              stale.forEach(job => job.reject(new Error("catalog reader was replaced")));
              // A PMTiles instance memoizes its header promise. Recreate the
              // reader so an explicit retry can recover from a poisoned or
              // transiently rejected header instead of replaying it forever.
              if (this.archive === archive) this.archive = this.archiveFactory();
            }
            throw error;
          });
        this.manifestPromise = manifestPromise;
      }
      return this.manifestPromise;
    }

    validateManifest(manifest) {
      if (manifest.schema_version !== 3 || !isInteger(manifest.page_zoom) ||
          manifest.page_addressing !== `XYZ z=${manifest.page_zoom}, x=collection.base+page, y=0` ||
          manifest.hash?.name !== "fnv1a32-utf8" || manifest.hash?.buckets !== 256 ||
          !manifest.collections || typeof manifest.collections !== "object") {
        throw new Error("invalid catalog manifest header");
      }
      if (!/^[0-9a-f]{64}$/.test(manifest.edge_build_id)) {
        throw new Error("invalid catalog edge_build_id");
      }
      const ranges = [];
      Object.entries(manifest.collections).forEach(([name, collection]) => {
        if (!name.length || !collection || !isInteger(collection.base) ||
            !isInteger(collection.count) || !isInteger(collection.page_size, 1) ||
            !isInteger(collection.pages) ||
            (collection.max_request_pages !== undefined &&
              !isInteger(collection.max_request_pages, 1)) ||
            collection.pages !== Math.ceil(collection.count / collection.page_size) ||
            collection.base + collection.pages > 2 ** manifest.page_zoom) {
          throw new Error(`invalid catalog collection ${name}`);
        }
        if (collection.pages) ranges.push({ start: collection.base, end: collection.base + collection.pages, name });
      });
      ranges.sort((left, right) => left.start - right.start || left.end - right.end);
      for (let index = 1; index < ranges.length; index += 1) {
        if (ranges[index].start < ranges[index - 1].end) {
          throw new Error(`overlapping catalog collections ${ranges[index - 1].name}/${ranges[index].name}`);
        }
      }
      const objects = manifest.collections.objects;
      const placeIndex = manifest.collections.place_id_index;
      const locations = manifest.collections.object_locations;
      if (!objects || !placeIndex || placeIndex.count !== 256 ||
          placeIndex.page_size !== 1 || placeIndex.pages !== 256 ||
          !locations || locations.count !== objects.count || locations.page_size !== 512 ||
          manifest.object_locations?.collection !== "object_locations" ||
          manifest.object_locations?.encoding !==
            "[lonE7,latE7,serviceOrdinal,displayLabel,kind]" ||
          !Array.isArray(manifest.object_locations?.service_ordinals) ||
          manifest.object_locations.service_ordinals.some((service, index, services) =>
            typeof service !== "string" || !service.length ||
            (index && service <= services[index - 1])) ||
          !manifest.spatial || manifest.spatial.edge_build_id !== manifest.edge_build_id ||
          manifest.spatial.zoom !== 15 ||
          manifest.spatial.addressing !== "XYZ direct tile coordinates in catalog.pmtiles" ||
          manifest.spatial.candidate_encoding !== "sorted [edge_id,modeMask,deltaE7] arrays" ||
          manifest.spatial.neighbor_radius !== 1 || !isInteger(manifest.spatial.tiles, 1) ||
          manifest.spatial.page_size_gate?.raw !== 524_288 ||
          manifest.spatial.page_size_gate?.gzip !== 65_536 ||
          !isInteger(manifest.spatial.fanout_gate?.candidates_per_lookup, 1) ||
          manifest.spatial.fanout_gate.candidates_per_lookup > 20_000 ||
          !isInteger(manifest.spatial.fanout_gate?.postfilter_relation_pages_per_lookup, 1) ||
          manifest.spatial.fanout_gate.postfilter_relation_pages_per_lookup >
            512 ||
          !isInteger(manifest.spatial.fanout_stats?.candidates_per_tile_max, 1) ||
          manifest.spatial.fanout_stats.candidates_per_tile_max >
            manifest.spatial.fanout_gate.candidates_per_lookup ||
          !isInteger(manifest.spatial.fanout_stats?.relation_pages_per_tile_max, 1) ||
          !isInteger(manifest.spatial.fanout_stats?.relation_pages_per_lookup_raw_max, 1) ||
          manifest.spatial.fanout_stats.relation_pages_per_lookup_raw_max <
            manifest.spatial.fanout_stats.relation_pages_per_tile_max ||
          manifest.spatial.fanout_stats.relation_pages_per_lookup_raw_max >
            manifest.spatial.fanout_gate.postfilter_relation_pages_per_lookup ||
          !isInteger(manifest.spatial.fanout_stats?.candidates_per_lookup_max, 1) ||
          manifest.spatial.fanout_stats.candidates_per_lookup_max <
            manifest.spatial.fanout_stats.candidates_per_tile_max ||
          manifest.spatial.fanout_stats.candidates_per_lookup_max >
            manifest.spatial.fanout_gate.candidates_per_lookup ||
          !manifest.spatial.page_stats || typeof manifest.spatial.page_stats !== "object" ||
          Array.isArray(manifest.spatial.page_stats)) {
        throw new Error("catalog object/place/location/spatial collections are missing");
      }
    }

    async getPage(collectionName, page) {
      const manifest = await this.manifest();
      const collection = manifest.collections[collectionName];
      if (!collection) throw new Error(`unknown catalog collection ${collectionName}`);
      if (!isInteger(page) || page >= collection.pages) {
        throw new Error(`invalid ${collectionName} page ${page}`);
      }
      const cacheKey = `${collectionName}:${page}`;
      return this.cachedRead("page", cacheKey, async () => {
        const tile = await this.archive.getZxy(manifest.page_zoom, collection.base + page, 0);
        if (!tile?.data) throw new Error(`missing ${collectionName} page ${page}`);
        return jsonFromBytes(tile.data, manifest.spatial.page_size_gate);
      });
    }

    queueRead(loader) {
      const generation = this.archiveGeneration;
      const promise = new Promise((resolve, reject) => {
        this.readQueue.push({ generation, loader, resolve, reject });
      });
      this.drainReads();
      return promise;
    }

    cancelQueuedReads() {
      const stale = this.readQueue.splice(0);
      stale.forEach(job => job.reject(new Error("catalog read was superseded")));
    }

    drainReads() {
      while (this.activeReads < this.maxConcurrentReads && this.readQueue.length) {
        const job = this.readQueue.shift();
        if (job.generation !== this.archiveGeneration) {
          job.reject(new Error("stale catalog read"));
          continue;
        }
        this.activeReads += 1;
        Promise.resolve().then(job.loader).then(value => {
          if (job.generation !== this.archiveGeneration) {
            job.reject(new Error("stale catalog read"));
            return;
          }
          job.resolve(value);
        }, error => job.reject(error)).finally(() => {
          this.activeReads -= 1;
          this.drainReads();
        });
      }
    }

    async cachedRead(kind, cacheKey, loader) {
      const spatial = kind === "spatial";
      const cache = spatial ? this.spatialPageCache : this.pageCache;
      const inFlight = spatial ? this.inFlightSpatialPages : this.inFlightPages;
      const maximum = spatial ? this.maxCachedSpatialPages : this.maxCachedPages;
      if (cache.has(cacheKey)) {
        const value = cache.get(cacheKey);
        cache.delete(cacheKey);
        cache.set(cacheKey, value);
        return value;
      }
      if (!inFlight.has(cacheKey)) {
        const promise = this.queueRead(loader)
          .then(value => {
            inFlight.delete(cacheKey);
            if (maximum) {
              cache.set(cacheKey, value);
              while (cache.size > maximum) {
                cache.delete(cache.keys().next().value);
              }
            }
            return value;
          })
          .catch(error => {
            inFlight.delete(cacheKey);
            cache.delete(cacheKey);
            throw error;
          });
        inFlight.set(cacheKey, promise);
      }
      return inFlight.get(cacheKey);
    }

    async getMany(collectionName, ids, validateRecord) {
      const manifest = await this.manifest();
      const collection = manifest.collections[collectionName];
      if (!collection) throw new Error(`unknown catalog collection ${collectionName}`);
      const unique = [...new Set(ids)];
      const wanted = new Set(unique);
      unique.forEach(id => {
        if (!isInteger(id) || id >= collection.count) {
          throw new Error(`invalid ${collectionName} record ${id}`);
        }
      });
      const pages = new Map();
      unique.forEach(id => {
        const page = Math.floor(id / collection.page_size);
        if (!pages.has(page)) pages.set(page, undefined);
      });
      if (collection.max_request_pages !== undefined &&
          pages.size > collection.max_request_pages) {
        throw new Error(
          `${collectionName} lookup exceeds ${collection.max_request_pages} pages`
        );
      }
      pages.forEach((_promise, page) => pages.set(page, this.getPage(collectionName, page)));
      await Promise.all(pages.values());
      const result = new Map();
      for (const [page, promise] of pages) {
        try {
          const records = await promise;
          if (!Array.isArray(records)) throw new Error(`${collectionName} page ${page} is not an array`);
          const expected = Math.min(collection.page_size, collection.count - page * collection.page_size);
          if (records.length !== expected) {
            throw new Error(`${collectionName} page ${page} has ${records.length} records, expected ${expected}`);
          }
          records.forEach((record, offset) => {
            const id = page * collection.page_size + offset;
            // A page is the integrity boundary: structurally validate every
            // decoded record, including neighbors fetched only because they
            // share the requested record's page. Validators may use the last
            // argument for request-specific cross-checks (for example spatial
            // hit geometry), which must not be applied to those neighbors.
            if (validateRecord) validateRecord(record, id, manifest, wanted.has(id));
            if (wanted.has(id)) result.set(id, record);
          });
        } catch (error) {
          this.pageCache.delete(`${collectionName}:${page}`);
          this.inFlightPages.delete(`${collectionName}:${page}`);
          throw error;
        }
      }
      return result;
    }

    getObjects(ids) {
      return this.getMany("objects", ids, (record, id) => {
        if (!record || typeof record !== "object" || Array.isArray(record) ||
            record.index !== id || typeof record.place_id !== "string" || !record.place_id.length ||
            typeof record.service !== "string" ||
            !Number.isFinite(record.lon) || !Number.isFinite(record.lat)) {
          throw new Error(`invalid object record ${id}`);
        }
      });
    }

    getObjectLocations(ids) {
      return this.getMany("object_locations", ids, (record, id, manifest) => {
        const config = manifest.object_locations;
        if (config?.collection !== "object_locations" ||
            config.encoding !== "[lonE7,latE7,serviceOrdinal,displayLabel,kind]" ||
            !Array.isArray(config.service_ordinals) ||
            config.service_ordinals.some((service, index) =>
              typeof service !== "string" || !service.length ||
              (index && service <= config.service_ordinals[index - 1])) ||
            !Array.isArray(record) || record.length !== 5 ||
            !Number.isSafeInteger(record[0]) || !Number.isSafeInteger(record[1]) ||
            record[0] < -1_800_000_000 || record[0] > 1_800_000_000 ||
            record[1] < -900_000_000 || record[1] > 900_000_000 ||
            !isInteger(record[2]) || record[2] >= config.service_ordinals.length ||
            typeof record[3] !== "string" || typeof record[4] !== "string") {
          throw new Error(`invalid object location ${id}`);
        }
      }).then(records => {
        const services = this.declared.object_locations.service_ordinals;
        return new Map([...records].map(([id, record]) => [id, {
          index: id,
          lon: record[0] / 10_000_000,
          lat: record[1] / 10_000_000,
          service: services[record[2]],
          name: record[3],
          kind: record[4]
        }]));
      });
    }

    async getSpatialCandidates(lngLat, activeModeMask, corridor) {
      const manifest = await this.manifest();
      const spatial = manifest.spatial;
      if (!spatial || spatial.edge_build_id !== manifest.edge_build_id || spatial.zoom !== 15 ||
          spatial.addressing !== "XYZ direct tile coordinates in catalog.pmtiles" ||
          spatial.candidate_encoding !== "sorted [edge_id,modeMask,deltaE7] arrays" ||
          spatial.neighbor_radius !== 1 || !isInteger(spatial.tiles, 1) ||
          !isInteger(activeModeMask, 1) || activeModeMask > 3 ||
          !Number.isFinite(corridor?.pixels) || corridor.pixels < 0 ||
          !Number.isFinite(corridor?.zoom) || corridor.zoom < 0 || corridor.zoom > 24 ||
          !Number.isFinite(lngLat?.lng) || !Number.isFinite(lngLat?.lat) ||
          lngLat.lng < -180 || lngLat.lng > 180 || lngLat.lat < -85.051129 || lngLat.lat > 85.051129) {
        throw new Error("invalid catalog spatial lookup");
      }
      const zoom = spatial.zoom;
      const span = 2 ** zoom;
      const tileX = (lngLat.lng + 180) / 360 * span;
      const centerX = Math.floor(tileX) % span;
      const radians = lngLat.lat * Math.PI / 180;
      const tileY = (1 - Math.asinh(Math.tan(radians)) / Math.PI) / 2 * span;
      const centerY = Math.max(0, Math.min(span - 1, Math.floor(tileY)));
      // MapLibre's world is 512 px wide at z0. Convert the largest active
      // half-corridor from screen pixels to a spatial tile fraction, then touch
      // only boundaries that the corridor can actually cross. At most a 2x2
      // block (four tiles) is needed, instead of an unconditional 3x3 read.
      const margin = corridor.pixels / 512 * 2 ** (zoom - corridor.zoom);
      if (!Number.isFinite(margin) || margin > Math.min(spatial.neighbor_radius, 0.5)) {
        throw new Error("destination corridor exceeds spatial neighbor coverage");
      }
      const fractionX = tileX - Math.floor(tileX);
      const fractionY = tileY - Math.floor(tileY);
      const dxs = [0];
      const dys = [0];
      if (fractionX <= margin) dxs.push(-1);
      else if (1 - fractionX <= margin) dxs.push(1);
      if (fractionY <= margin) dys.push(-1);
      else if (1 - fractionY <= margin) dys.push(1);
      const tiles = [];
      for (const dy of dys) {
        const y = centerY + dy;
        if (y < 0 || y >= span) continue;
        for (const dx of dxs) {
          const x = (centerX + dx + span) % span;
          tiles.push(this.cachedRead("spatial", `spatial:${zoom}:${x}:${y}`, async () => {
            const tile = await this.archive.getZxy(zoom, x, y);
            if (!tile?.data) return [];
            const records = await jsonFromBytes(tile.data, spatial.page_size_gate);
            if (!Array.isArray(records)) throw new Error(`invalid spatial page ${zoom}/${x}/${y}`);
            let priorEdge = -1;
            records.forEach(record => {
              if (!Array.isArray(record) || record.length !== 3 || !isInteger(record[0]) ||
                  record[0] <= priorEdge || !isInteger(record[1], 1) || record[1] > 3 ||
                  !Array.isArray(record[2]) || record[2].length < 4 || record[2].length % 2 ||
                  record[2].some(value => !Number.isSafeInteger(value))) {
                throw new Error(`invalid spatial candidate in ${zoom}/${x}/${y}`);
              }
              priorEdge = record[0];
            });
            return records;
          }));
        }
      }
      const byEdge = new Map();
      (await Promise.all(tiles)).forEach(records => records.forEach(([edgeId, modeMask, encoded]) => {
        const filtered = modeMask & activeModeMask;
        if (!filtered) return;
        const prior = byEdge.get(edgeId);
        if (prior && (prior.encoded.length !== encoded.length ||
            prior.encoded.some((value, index) => value !== encoded[index]))) {
          throw new Error(`spatial candidate geometry mismatch for edge ${edgeId}`);
        }
        byEdge.set(edgeId, {
          modeMask: (prior?.modeMask || 0) | filtered,
          encoded
        });
      }));
      if (byEdge.size > spatial.fanout_gate.candidates_per_lookup) {
        throw new Error(
          `destination hit lookup exceeds ${spatial.fanout_gate.candidates_per_lookup} candidates`
        );
      }
      return [...byEdge].map(([edgeId, value]) => ({ edgeId, ...value }));
    }

    getDestinationSets(collectionName, ids) {
      if (!collectionName.startsWith("destination_edge_set:")) {
        return Promise.reject(new Error(`invalid destination collection ${collectionName}`));
      }
      return this.getMany(collectionName, ids, (record, id, manifest) => {
        const objectCount = manifest.collections.objects.count;
        if (!Array.isArray(record) || record.some(index => !isInteger(index) || index >= objectCount) ||
            record.some((index, position) => position && index <= record[position - 1])) {
          throw new Error(`invalid destination set ${collectionName}:${id}`);
        }
      });
    }

    async resolveReferenceLocations(requests, extraObjectIds = []) {
      const extraIds = [...new Set(extraObjectIds)];
      // Marker cards are independent of destination-set resolution. Start
      // their rich page fetch immediately so a slow set/location chain does
      // not add a full extra network round trip to the visible card.
      const objectsPromise = this.getObjects(extraIds);
      // Sets may fail before this branch is awaited; attach a handler now to
      // avoid reporting the concurrently useful request as an unhandled
      // rejection. Awaiting the original promise below still propagates it.
      objectsPromise.catch(() => {});
      const grouped = new Map();
      requests.forEach(({ collection, id }) => {
        if (!grouped.has(collection)) grouped.set(collection, []);
        grouped.get(collection).push(id);
      });
      const setMaps = await Promise.all([...grouped].map(async ([collection, ids]) =>
        [collection, await this.getDestinationSets(collection, ids)]
      ));
      const sets = new Map();
      const objectIds = new Set(extraIds);
      setMaps.forEach(([collection, records]) => records.forEach((indexes, id) => {
        sets.set(`${collection}:${id}`, indexes);
        indexes.forEach(index => objectIds.add(index));
      }));
      // Location pages are the complete ranking/counting input. Rich object
      // pages are deliberately limited to explicitly requested marker IDs;
      // result-card hydration chooses its own small visible batches later.
      const locations = await this.getObjectLocations([...objectIds]);
      const objects = await objectsPromise;
      return { sets, locations, objects };
    }

    async findObjectByPlaceId(placeId) {
      if (typeof placeId !== "string" || !placeId.length) return undefined;
      const manifest = await this.manifest();
      const bucket = fnv1a32(placeId) & (manifest.hash.buckets - 1);
      const page = await this.getPage("place_id_index", bucket);
      try {
        if (!page || typeof page !== "object" || Array.isArray(page)) {
          throw new Error(`invalid place_id_index bucket ${bucket}`);
        }
        const objectCount = manifest.collections.objects.count;
        Object.entries(page).forEach(([key, index]) => {
          if ((fnv1a32(key) & 255) !== bucket || !isInteger(index) || index >= objectCount) {
            throw new Error(`invalid place_id_index entry in bucket ${bucket}`);
          }
        });
      } catch (error) {
        this.pageCache.delete(`place_id_index:${bucket}`);
        this.inFlightPages.delete(`place_id_index:${bucket}`);
        throw error;
      }
      const index = page[placeId];
      if (index === undefined) return undefined;
      const object = (await this.getObjects([index])).get(index);
      if (object?.place_id !== placeId) {
        throw new Error(`place index mismatch for ${placeId}`);
      }
      return object;
    }
  }

  root.CatalogPages = CatalogPages;
  if (typeof module === "object" && module.exports) {
    module.exports = { CatalogPages, fnv1a32 };
  }
})(globalThis);
