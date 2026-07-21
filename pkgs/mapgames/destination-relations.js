(function (root) {
  "use strict";

  const buildIdPattern = /^[0-9a-f]{64}$/;
  const catalogFilePattern = /^catalog-[0-9a-f]{64}\.pmtiles$/;
  const breakpointSnapPixels = 2;

  function integer(value, minimum = 0) {
    return Number.isSafeInteger(value) && value >= minimum;
  }

  function equalArray(left, right) {
    return Array.isArray(left) && Array.isArray(right) &&
      left.length === right.length && left.every((value, index) => value === right[index]);
  }

  function haversineMeters(left, right) {
    const radians = degrees => degrees * Math.PI / 180;
    const deltaLat = radians(right[1] - left[1]);
    const deltaLon = radians(right[0] - left[0]);
    const value = Math.sin(deltaLat / 2) ** 2 +
      Math.cos(radians(left[1])) * Math.cos(radians(right[1])) *
      Math.sin(deltaLon / 2) ** 2;
    return 6_371_008.8 * 2 * Math.asin(Math.min(1, Math.sqrt(value)));
  }

  function decodeCoordinates(encoded, scale) {
    if (!Array.isArray(encoded) || encoded.length < 4 || encoded.length % 2 ||
        encoded.some(value => !Number.isSafeInteger(value))) {
      throw new Error("invalid destination edge coordinates");
    }
    const result = [];
    let lon = 0;
    let lat = 0;
    for (let offset = 0; offset < encoded.length; offset += 2) {
      if (offset === 0) {
        lon = encoded[offset];
        lat = encoded[offset + 1];
      } else {
        lon += encoded[offset];
        lat += encoded[offset + 1];
      }
      const point = [lon / scale, lat / scale];
      if (point[0] < -180 || point[0] > 180 || point[1] < -90 || point[1] > 90) {
        throw new Error("destination edge coordinate is outside WGS84");
      }
      result.push(point);
    }
    return result;
  }

  function closestCanonicalPoint(lngLat, coordinates, project) {
    const target = project([lngLat.lng, lngLat.lat]);
    const cumulativeLengths = [0];
    let total = 0;
    let best;
    for (let index = 1; index < coordinates.length; index += 1) {
      const left = project(coordinates[index - 1]);
      const right = project(coordinates[index]);
      const dx = right.x - left.x;
      const dy = right.y - left.y;
      const denominator = dx * dx + dy * dy;
      const t = denominator === 0 ? 0 : Math.max(0, Math.min(1,
        ((target.x - left.x) * dx + (target.y - left.y) * dy) / denominator
      ));
      const projected = { x: left.x + t * dx, y: left.y + t * dy };
      const distance = Math.hypot(target.x - projected.x, target.y - projected.y);
      const meters = haversineMeters(coordinates[index - 1], coordinates[index]);
      total += meters;
      cumulativeLengths.push(total);
      if (!best || distance < best.distance) {
        best = { distance, segment: index - 1, projected };
      }
    }
    if (!best || !(total > 0)) throw new Error("degenerate destination edge geometry");
    const nativeLeft = coordinates[best.segment];
    const nativeRight = coordinates[best.segment + 1];
    const nativeDx = nativeRight[0] - nativeLeft[0];
    const nativeDy = nativeRight[1] - nativeLeft[1];
    // The screen projection decides which segment is closest and supplies the
    // corridor distance. Fractions, however, are produced natively by linear
    // lon/lat interpolation within a haversine-measured segment. Recover that
    // parameter with a two-axis projection rather than reusing the generally
    // non-affine projected chord parameter. Using both axes is important: a
    // click's perpendicular offset from a diagonal must not move its
    // along-edge fraction to the wrong side of a breakpoint.
    const nativeDenominator = nativeDx * nativeDx + nativeDy * nativeDy;
    const nativeT = nativeDenominator === 0 ? 0 : Math.max(0, Math.min(1,
      ((lngLat.lng - nativeLeft[0]) * nativeDx +
        (lngLat.lat - nativeLeft[1]) * nativeDy) / nativeDenominator
    ));
    return {
      distance: best.distance,
      fraction: (cumulativeLengths[best.segment] +
        nativeT * (cumulativeLengths[best.segment + 1] -
          cumulativeLengths[best.segment])) / total,
      projected: best.projected,
      target,
      cumulativeLengths,
      total
    };
  }

  function coordinateAtFraction(coordinates, snap, fraction) {
    if (fraction <= 0) return coordinates[0];
    if (fraction >= 1) return coordinates[coordinates.length - 1];
    const distance = fraction * snap.total;
    let low = 1;
    let high = snap.cumulativeLengths.length - 1;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (snap.cumulativeLengths[middle] < distance) low = middle + 1;
      else high = middle;
    }
    const before = snap.cumulativeLengths[low - 1];
    const length = snap.cumulativeLengths[low] - before;
    const within = length > 0 ? (distance - before) / length : 0;
    const left = coordinates[low - 1];
    const right = coordinates[low];
    return [
      left[0] + (right[0] - left[0]) * within,
      left[1] + (right[1] - left[1]) * within
    ];
  }

  function nearbyBreakpoint(preset, snap, coordinates, project) {
    const breakpoints = preset[2];
    let low = 0;
    let high = breakpoints.length;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (breakpoints[middle][0] < snap.fraction) low = middle + 1;
      else high = middle;
    }
    let nearest;
    for (const index of [low - 1, low]) {
      if (index < 0 || index >= breakpoints.length) continue;
      const projected = project(coordinateAtFraction(
        coordinates, snap, breakpoints[index][0]
      ));
      const distance = Math.hypot(
        snap.target.x - projected.x, snap.target.y - projected.y
      );
      // MVT coordinate quantization can move a rendered boundary by roughly a
      // pixel. Only the two fraction-neighboring breakpoints are projected,
      // and a deliberately small tolerance preserves open-run selection away
      // from that quantization halo.
      if (distance <= breakpointSnapPixels && (!nearest || distance < nearest.distance)) {
        nearest = { distance, setId: breakpoints[index][1] };
      }
    }
    return nearest?.setId;
  }

  function selectedSet(preset, fraction) {
    const [_minutes, runs, breakpoints] = preset;
    const breakpoint = breakpoints.find(([point]) => fraction === point);
    if (breakpoint) return breakpoint[1];
    const run = runs.find(([start, end]) => start < fraction && fraction < end);
    return run?.[2];
  }

  class DestinationRelations {
    constructor(catalogPages, configuration) {
      this.catalog = catalogPages;
      this.configuration = configuration;
      this.requirementsByKey = new Map();
      this.validateConfiguration();
    }

    validateConfiguration() {
      const config = this.configuration;
      if (!config || config.schema_version !== 3 || !buildIdPattern.test(config.edge_build_id) ||
          typeof config.edge_collection !== "string" || !config.edge_collection.length ||
          !integer(config.edge_count, 1) ||
          config.coordinate_encoding?.scale !== 10_000_000 ||
          config.coordinate_encoding?.order !== "lon_lat" ||
          config.coordinate_encoding?.delta !== "first_pair_absolute_then_signed_deltas" ||
          config.fraction_semantics !==
            "closed_source_intervals; exact breakpoint override; open interior runs" ||
          !Array.isArray(config.requirements)) {
        throw new Error("invalid shared destination lookup metadata");
      }
      const hit = config.hit;
      if (!hit || !catalogFilePattern.test(hit.file) || hit.zoom !== 15 ||
          hit.addressing !== "XYZ direct tile coordinates in catalog.pmtiles" ||
          hit.candidate_encoding !== "sorted [edge_id,modeMask,deltaE7] arrays" ||
          hit.neighbor_radius !== 1 ||
          hit.mode_bits?.walk !== 1 || hit.mode_bits?.drive !== 2) {
        throw new Error("invalid shared destination hit metadata");
      }
      const serviceModes = new Set();
      config.requirements.forEach((requirement, ordinal) => {
        const serviceMode = `${requirement?.service}:${requirement?.mode}`;
        if (!requirement || typeof requirement.key !== "string" ||
            typeof requirement.service !== "string" ||
            !["walk", "drive"].includes(requirement.mode) ||
            requirement.mode_bit !== hit.mode_bits[requirement.mode] ||
            !Array.isArray(requirement.presets) || this.requirementsByKey.has(requirement.key) ||
            serviceModes.has(serviceMode)) {
          throw new Error(`invalid destination requirement ${ordinal}`);
        }
        serviceModes.add(serviceMode);
        const minutes = new Set();
        requirement.presets.forEach(preset => {
          if (!integer(preset.minutes, 1) || minutes.has(preset.minutes) ||
              typeof preset.set_collection !== "string" ||
              !preset.set_collection.startsWith("destination_edge_set:") ||
              !integer(preset.set_count, 1)) {
            throw new Error(`invalid destination preset in ${requirement.key}`);
          }
          minutes.add(preset.minutes);
        });
        this.requirementsByKey.set(requirement.key, { ...requirement, ordinal });
      });
    }

    validateCatalog(manifest) {
      if (manifest.edge_build_id !== this.configuration.edge_build_id) {
        throw new Error("destination lookup/catalog build mismatch");
      }
      const collection = manifest.collections?.[this.configuration.edge_collection];
      const relationPageGate =
        manifest.spatial?.fanout_gate?.postfilter_relation_pages_per_lookup;
      if (collection?.count !== this.configuration.edge_count) {
        throw new Error("destination edge collection count mismatch");
      }
      if (!integer(collection.max_request_pages, 1) ||
          collection.max_request_pages !== relationPageGate) {
        throw new Error("destination edge collection fanout mismatch");
      }
    }

    validateRelation(record, edgeId, manifest) {
      if (!Array.isArray(record) || record.length !== 2 ||
          !integer(record[0], 1) || record[0] > 3 || !Array.isArray(record[1])) {
        throw new Error(`invalid destination edge relation ${edgeId}`);
      }
      let priorRequirement = -1;
      record[1].forEach(route => {
        if (!Array.isArray(route) || route.length !== 2 ||
            !integer(route[0]) || route[0] <= priorRequirement ||
            route[0] >= this.configuration.requirements.length || !Array.isArray(route[1])) {
          throw new Error(`invalid route in destination edge ${edgeId}`);
        }
        priorRequirement = route[0];
        const requirement = this.configuration.requirements[route[0]];
        if (!(record[0] & requirement.mode_bit)) {
          throw new Error(`route mode mismatch in destination edge ${edgeId}`);
        }
        const seenMinutes = new Set();
        let priorPresetIndex = -1;
        route[1].forEach(preset => {
          const presetIndex = requirement.presets.findIndex(candidate => candidate.minutes === preset?.[0]);
          if (!Array.isArray(preset) || preset.length !== 3 || !integer(preset[0], 1) ||
              seenMinutes.has(preset[0]) || !Array.isArray(preset[1]) || !Array.isArray(preset[2]) ||
              presetIndex <= priorPresetIndex) {
            throw new Error(`invalid preset in destination edge ${edgeId}`);
          }
          priorPresetIndex = presetIndex;
          seenMinutes.add(preset[0]);
          const presetMetadata = requirement.presets[presetIndex];
          const setCollection = manifest.collections?.[presetMetadata.set_collection];
          if (!setCollection || setCollection.count !== presetMetadata.set_count) {
            throw new Error(`missing edge set collection in destination edge ${edgeId}`);
          }
          const validSetId = value => integer(value) && value < setCollection.count;
          let priorEnd = -Infinity;
          preset[1].forEach(run => {
            if (!Array.isArray(run) || run.length !== 3 ||
                !Number.isFinite(run[0]) || !Number.isFinite(run[1]) ||
                run[0] < 0 || run[0] >= run[1] || run[1] > 1 ||
                run[0] < priorEnd || !validSetId(run[2])) {
              throw new Error(`invalid interior run in destination edge ${edgeId}`);
            }
            priorEnd = run[1];
          });
          let priorPoint = -Infinity;
          preset[2].forEach(breakpoint => {
            if (!Array.isArray(breakpoint) || breakpoint.length !== 2 ||
                !Number.isFinite(breakpoint[0]) || breakpoint[0] < 0 || breakpoint[0] > 1 ||
                breakpoint[0] <= priorPoint || !validSetId(breakpoint[1])) {
              throw new Error(`invalid breakpoint in destination edge ${edgeId}`);
            }
            priorPoint = breakpoint[0];
          });
        });
      });
      this.validateCatalog(manifest);
    }

    async resolve(candidates, lngLat, activePresets, project, corridorPixels) {
      const manifest = await this.catalog.manifest();
      this.validateCatalog(manifest);
      const active = activePresets.map(selection => {
        const requirement = this.requirementsByKey.get(selection.key);
        const preset = requirement?.presets.find(candidate => candidate.minutes === selection.minutes);
        if (!requirement || !preset || requirement.mode !== selection.mode ||
            requirement.service !== selection.service) {
          throw new Error(`active destination preset is absent from metadata: ${selection.key}`);
        }
        return { requirement, preset };
      });
      const rawByEdge = new Map();
      candidates.forEach(candidate => {
        if (!integer(candidate.edgeId) || !integer(candidate.modeMask, 1) || candidate.modeMask > 3 ||
            !Array.isArray(candidate.encoded)) {
          throw new Error("invalid destination hit feature");
        }
        // Decode and validate before issuing any relation-page Range request.
        // Spatial pages carry compact geometry so the large raw tile candidate
        // set can be reduced to the visible corridor before relation-page reads.
        const coordinates = decodeCoordinates(
          candidate.encoded, this.configuration.coordinate_encoding.scale
        );
        const prior = rawByEdge.get(candidate.edgeId);
        if (prior && !equalArray(prior.encoded, candidate.encoded)) {
          throw new Error(`duplicate destination hit geometry mismatch for edge ${candidate.edgeId}`);
        }
        rawByEdge.set(candidate.edgeId, {
          modeMask: (prior?.modeMask || 0) | candidate.modeMask,
          encoded: candidate.encoded,
          coordinates
        });
      });
      const byEdge = new Map();
      rawByEdge.forEach((candidate, edgeId) => {
        const tolerances = active
          .filter(({ requirement }) => candidate.modeMask & requirement.mode_bit)
          .map(({ requirement }) => corridorPixels[requirement.mode]);
        if (!tolerances.length) return;
        const snap = closestCanonicalPoint(lngLat, candidate.coordinates, project);
        if (snap.distance <= Math.max(...tolerances)) {
          byEdge.set(edgeId, { ...candidate, snap });
        }
      });
      const relations = byEdge.size
        ? await this.catalog.getMany(
          this.configuration.edge_collection,
          [...byEdge.keys()],
          (record, edgeId, checkedManifest) => {
            this.validateRelation(record, edgeId, checkedManifest);
          }
        )
        : new Map();
      const references = new Map();
      relations.forEach((relation, edgeId) => {
        const candidate = byEdge.get(edgeId);
        const candidateMask = candidate.modeMask;
        if ((candidateMask & ~relation[0]) !== 0) {
          throw new Error(`destination hit/relation mode mismatch for edge ${edgeId}`);
        }
        const snap = candidate.snap;
        const routes = new Map(relation[1].map(route => [route[0], route[1]]));
        active.forEach(({ requirement, preset: presetMetadata }) => {
          if (!(candidateMask & requirement.mode_bit) || !(relation[0] & requirement.mode_bit) ||
              snap.distance > corridorPixels[requirement.mode]) return;
          const encodedPresets = routes.get(requirement.ordinal);
          const encodedPreset = encodedPresets?.find(preset => preset[0] === presetMetadata.minutes);
          if (!encodedPreset) return;
          const breakpointSetId = nearbyBreakpoint(
            encodedPreset, snap, candidate.coordinates, project
          );
          const setId = breakpointSetId === undefined
            ? selectedSet(encodedPreset, snap.fraction)
            : breakpointSetId;
          if (setId !== undefined) {
            references.set(`${presetMetadata.set_collection}:${setId}`, {
              collection: presetMetadata.set_collection,
              id: setId,
              service: requirement.service,
              mode: requirement.mode,
              minutes: presetMetadata.minutes
            });
          }
        });
      });
      return [...references.values()];
    }
  }

  root.DestinationRelations = DestinationRelations;
  if (typeof module === "object" && module.exports) {
    module.exports = {
      DestinationRelations,
      closestCanonicalPoint,
      decodeCoordinates,
      haversineMeters,
      selectedSet
    };
  }
})(globalThis);
