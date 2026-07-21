#include <valhalla/baldr/graphreader.h>
#include <valhalla/config.h>
#include <valhalla/sif/costfactory.h>
#include <valhalla/tyr/actor.h>

#include <rapidjson/document.h>
#include <sqlite3.h>

#include <boost/property_tree/ptree.hpp>

#include "destination-relations.hh"
#include "destination-lookup-finalize.hh"

#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <sys/resource.h>
#include <unistd.h>

namespace {

struct Request {
  std::string id;
  std::string feature_id;
  std::string costing;
  uint32_t lookup_id;
  double lon;
  double lat;
  int minutes;
};

struct Bounds {
  double min_lon;
  double min_lat;
  double max_lon;
  double max_lat;
};

struct Point {
  double lon;
  double lat;
};

using Line = std::vector<Point>;
using Lines = std::map<std::string, Line>;

struct Interval {
  double start;
  double end;
};

struct CanonicalGeometry;

// Full-edge memberships dominate the hospital accumulator. Keep those in a
// dense, route-ordinal bitset for modest route sets and retain only
// contour-frontier intervals as individual records. One record carries its
// band because all bands for a canonical edge now live in one map node.
struct DestinationInterval {
  Interval interval;
  uint32_t request_index;
  uint32_t minute_index;
};

// Accumulation maps are keyed by the canonical edge id min(edge_id,
// opposing_edge_id). Canonical geometry is shared with the worker's edge
// cache rather than copied into every band map.
struct DestinationEdge {
  std::shared_ptr<const CanonicalGeometry> canonical;
  size_t full_index;
  std::vector<DestinationInterval> partials;
};

// Fixed-width membership rows are allocated in chunks. A single vector per
// edge would add an allocation (and allocator metadata) to nearly every road
// edge; one monolithic vector would temporarily double a large slab whenever
// it grows. Stable row ordinals into zero-filled chunks avoid both costs. For
// route sets above kDenseRequestLimit, sparse 12-byte full records avoid a
// global-width bitset regression (notably for thousands of coffee shops).
class DestinationEdges {
public:
  using Map = std::map<uint64_t, DestinationEdge>;
  using const_iterator = Map::const_iterator;

  DestinationEdges(size_t minute_count, size_t request_count)
      : request_count_(request_count),
        dense_(request_count <= kDenseRequestLimit),
        route_words_(dense_ ? (request_count + 63) / 64 : 0),
        words_per_edge_(minute_count * route_words_),
        edges_per_chunk_(
            dense_ ? std::max<size_t>(1, kChunkTargetBytes / (words_per_edge_ *
                                                              sizeof(uint64_t)))
                   : 1) {}

  DestinationEdges(const DestinationEdges &) = delete;
  DestinationEdges &operator=(const DestinationEdges &) = delete;
  DestinationEdges(DestinationEdges &&) = default;
  DestinationEdges &operator=(DestinationEdges &&) = default;

  std::pair<Map::iterator, bool>
  try_emplace(uint64_t canonical_id,
              std::shared_ptr<const CanonicalGeometry> canonical) {
    auto existing = edges_.find(canonical_id);
    if (existing != edges_.end()) {
      return {existing, false};
    }
    size_t full_index = UINT32_MAX;
    if (dense_) {
      full_index = membership_count_++;
      if (full_index % edges_per_chunk_ == 0) {
        chunks_.push_back(
            std::make_unique<uint64_t[]>(edges_per_chunk_ * words_per_edge_));
      }
    }
    return edges_.try_emplace(
        canonical_id, DestinationEdge{std::move(canonical), full_index, {}});
  }

  void add_full(DestinationEdge &edge, size_t minute_index,
                size_t request_index) {
    if (dense_) {
      membership(edge)[minute_index * route_words_ + request_index / 64] |=
          uint64_t{1} << (request_index % 64);
      return;
    }
    if (sparse_full_count_ >= UINT32_MAX) {
      throw std::runtime_error("too many sparse full-edge memberships");
    }
    if (sparse_full_count_ % kSparseFullChunkRecords == 0) {
      sparse_full_chunks_.push_back(
          std::make_unique<SparseFull[]>(kSparseFullChunkRecords));
    }
    const uint32_t index = static_cast<uint32_t>(sparse_full_count_++);
    sparse_full(index) = {static_cast<uint32_t>(request_index),
                          static_cast<uint32_t>(minute_index),
                          static_cast<uint32_t>(edge.full_index)};
    edge.full_index = index;
  }

  bool has_full(const DestinationEdge &edge, size_t minute_index) const {
    if (dense_) {
      const uint64_t *row = membership(edge) + minute_index * route_words_;
      return std::any_of(row, row + route_words_,
                         [](uint64_t word) { return word != 0; });
    }
    for (uint32_t index = static_cast<uint32_t>(edge.full_index);
         index != UINT32_MAX; index = sparse_full(index).next) {
      if (sparse_full(index).minute_index == minute_index) {
        return true;
      }
    }
    return false;
  }

  template <typename Function>
  void for_each_full(const DestinationEdge &edge, size_t minute_index,
                     Function &&function) const {
    if (dense_) {
      const uint64_t *row = membership(edge) + minute_index * route_words_;
      for (size_t word_index = 0; word_index < route_words_; ++word_index) {
        uint64_t word = row[word_index];
        while (word != 0) {
          const unsigned bit = std::countr_zero(word);
          const size_t request_index = word_index * 64 + bit;
          if (request_index < request_count_) {
            function(request_index);
          }
          word &= word - 1;
        }
      }
      return;
    }
    for (uint32_t index = static_cast<uint32_t>(edge.full_index);
         index != UINT32_MAX; index = sparse_full(index).next) {
      const SparseFull &full = sparse_full(index);
      if (full.minute_index == minute_index) {
        function(full.request_index);
      }
    }
  }

  const_iterator begin() const { return edges_.begin(); }
  const_iterator end() const { return edges_.end(); }
  bool empty() const { return edges_.empty(); }
  size_t size() const { return edges_.size(); }

private:
  struct SparseFull {
    uint32_t request_index;
    uint32_t minute_index;
    uint32_t next;
  };
  static_assert(sizeof(SparseFull) == 12);

  static constexpr size_t kDenseRequestLimit = 256;
  static constexpr size_t kChunkTargetBytes = 1 << 20;
  static constexpr size_t kSparseFullChunkRecords = 1 << 16;

  uint64_t *membership(const DestinationEdge &edge) {
    return chunks_[edge.full_index / edges_per_chunk_].get() +
           (edge.full_index % edges_per_chunk_) * words_per_edge_;
  }

  const uint64_t *membership(const DestinationEdge &edge) const {
    return chunks_[edge.full_index / edges_per_chunk_].get() +
           (edge.full_index % edges_per_chunk_) * words_per_edge_;
  }

  SparseFull &sparse_full(uint32_t index) {
    return sparse_full_chunks_[index / kSparseFullChunkRecords]
                              [index % kSparseFullChunkRecords];
  }

  const SparseFull &sparse_full(uint32_t index) const {
    return sparse_full_chunks_[index / kSparseFullChunkRecords]
                              [index % kSparseFullChunkRecords];
  }

  size_t request_count_;
  bool dense_;
  size_t route_words_;
  size_t words_per_edge_;
  size_t edges_per_chunk_;
  size_t membership_count_ = 0;
  Map edges_;
  std::vector<std::unique_ptr<uint64_t[]>> chunks_;
  size_t sparse_full_count_ = 0;
  std::vector<std::unique_ptr<SparseFull[]>> sparse_full_chunks_;
};

struct Edge {
  uint64_t id;
  uint64_t pred_id;
  double duration;
  double distance;
  Line line;
};

constexpr uint64_t kInvalidGraphId = 0x3fffffffffff;

std::string json_string(const std::string &value) {
  std::ostringstream out;
  out << '"';
  for (const unsigned char ch : value) {
    switch (ch) {
    case '"':
      out << "\\\"";
      break;
    case '\\':
      out << "\\\\";
      break;
    case '\b':
      out << "\\b";
      break;
    case '\f':
      out << "\\f";
      break;
    case '\n':
      out << "\\n";
      break;
    case '\r':
      out << "\\r";
      break;
    case '\t':
      out << "\\t";
      break;
    default:
      if (ch < 0x20) {
        out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(ch)
            << std::dec << std::setfill(' ');
      } else {
        out << ch;
      }
    }
  }
  out << '"';
  return out.str();
}

std::vector<std::string> split(const std::string &value, char delimiter) {
  std::vector<std::string> fields;
  std::string field;
  std::istringstream stream(value);
  while (std::getline(stream, field, delimiter)) {
    fields.push_back(field);
  }
  return fields;
}

std::vector<int> parse_minutes(const std::string &value) {
  std::vector<int> minutes;
  for (const auto &field : split(value, ',')) {
    const int minute = std::stoi(field);
    if (minute <= 0) {
      throw std::runtime_error("minutes must be positive");
    }
    minutes.push_back(minute);
  }
  if (minutes.empty() || !std::is_sorted(minutes.begin(), minutes.end()) ||
      std::adjacent_find(minutes.begin(), minutes.end()) != minutes.end()) {
    throw std::runtime_error(
        "minute thresholds must be non-empty, sorted, and unique");
  }
  return minutes;
}

Bounds parse_bounds(const std::string &value) {
  const auto fields = split(value, ',');
  if (fields.size() != 4) {
    throw std::runtime_error(
        "bounds must contain four comma-separated numbers");
  }
  Bounds bounds{
      std::stod(fields[0]),
      std::stod(fields[1]),
      std::stod(fields[2]),
      std::stod(fields[3]),
  };
  if (!(bounds.min_lon < bounds.max_lon && bounds.min_lat < bounds.max_lat)) {
    throw std::runtime_error("invalid bounds");
  }
  return bounds;
}

Request parse_request(const std::string &line, size_t line_number) {
  const auto fields = split(line, '\t');
  if (fields.size() != 6) {
    throw std::runtime_error("line " + std::to_string(line_number) +
                             ": expected 6 TSV fields");
  }
  if (fields[0].empty() ||
      fields[0].find_first_not_of("0123456789") != std::string::npos) {
    throw std::runtime_error("line " + std::to_string(line_number) +
                             ": request id must contain only digits");
  }
  rapidjson::Document properties;
  properties.Parse(fields[5].c_str());
  if (properties.HasParseError() || !properties.IsObject() ||
      !properties.HasMember("place_id") || !properties["place_id"].IsString() ||
      !properties.HasMember("lookup_id") || !properties["lookup_id"].IsUint()) {
    throw std::runtime_error(
        "line " + std::to_string(line_number) +
        ": properties must contain string place_id and uint lookup_id");
  }
  return {
      fields[0],
      properties["place_id"].GetString(),
      fields[1],
      properties["lookup_id"].GetUint(),
      std::stod(fields[2]),
      std::stod(fields[3]),
      std::stoi(fields[4]),
  };
}

std::vector<Request> read_requests(const std::filesystem::path &path) {
  std::ifstream file(path);
  if (!file) {
    throw std::runtime_error("could not open requests TSV: " + path.string());
  }
  std::vector<Request> requests;
  std::string line;
  size_t line_number = 0;
  while (std::getline(file, line)) {
    ++line_number;
    if (!line.empty()) {
      requests.push_back(parse_request(line, line_number));
    }
  }
  if (!file.eof()) {
    throw std::runtime_error("could not read requests TSV: " + path.string());
  }
  if (requests.empty()) {
    throw std::runtime_error("requests TSV is empty");
  }
  return requests;
}

std::string request_json(const Request &request) {
  std::ostringstream out;
  out << std::setprecision(17)
      << R"({"action":"isochrone","locations":[{"lon":)" << request.lon
      << R"(,"lat":)" << request.lat << R"(,"radius":100}],"costing":)"
      << json_string(request.costing) << R"(,"contours":[{"time":)"
      << request.minutes
      << R"(}],"dedupe":true,"format":"pbf","generalize":0,"expansion_properties":["edge_id","pred_edge_id","duration","distance"],)"
      << R"("reverse":true,"skip_opposites":false})";
  return out.str();
}

std::string validation_request_json(const Request &request) {
  // The validation isochrone exists only to propagate routing errors that the
  // expansion action swallows (e.g. Loki's "no edges near location"). Those
  // errors do not depend on the contour time, so a 1-minute contour surfaces
  // them without repeating the full-threshold routing work.
  std::ostringstream out;
  out << std::setprecision(17) << R"({"locations":[{"lon":)" << request.lon
      << R"(,"lat":)" << request.lat << R"(,"radius":100}],"costing":)"
      << json_string(request.costing)
      << R"(,"contours":[{"time":1}],"generalize":0,"polygons":false,"reverse":true,"show_locations":false})";
  return out.str();
}

bool same_point(const Point &left, const Point &right) {
  return std::abs(left.lon - right.lon) < 1e-12 &&
         std::abs(left.lat - right.lat) < 1e-12;
}

bool clip_test(double p, double q, double &start, double &end) {
  if (p == 0) {
    return q >= 0;
  }
  const double ratio = q / p;
  if (p < 0) {
    if (ratio > end) {
      return false;
    }
    start = std::max(start, ratio);
  } else {
    if (ratio < start) {
      return false;
    }
    end = std::min(end, ratio);
  }
  return true;
}

bool clip_segment(const Point &first, const Point &second, const Bounds &bounds,
                  Point &clipped_first, Point &clipped_second) {
  const double delta_lon = second.lon - first.lon;
  const double delta_lat = second.lat - first.lat;
  double start = 0;
  double end = 1;
  if (!clip_test(-delta_lon, first.lon - bounds.min_lon, start, end) ||
      !clip_test(delta_lon, bounds.max_lon - first.lon, start, end) ||
      !clip_test(-delta_lat, first.lat - bounds.min_lat, start, end) ||
      !clip_test(delta_lat, bounds.max_lat - first.lat, start, end)) {
    return false;
  }
  clipped_first = {
      first.lon + start * delta_lon,
      first.lat + start * delta_lat,
  };
  clipped_second = {
      first.lon + end * delta_lon,
      first.lat + end * delta_lat,
  };
  return !same_point(clipped_first, clipped_second);
}

std::vector<Line> clip_line(const Line &line, const Bounds &bounds) {
  std::vector<Line> result;
  Line current;
  for (size_t index = 1; index < line.size(); ++index) {
    Point first;
    Point second;
    if (!clip_segment(line[index - 1], line[index], bounds, first, second)) {
      if (current.size() >= 2) {
        result.push_back(std::move(current));
      }
      current.clear();
      continue;
    }
    if (current.empty()) {
      current = {first, second};
    } else if (same_point(current.back(), first)) {
      if (!same_point(current.back(), second)) {
        current.push_back(second);
      }
    } else {
      if (current.size() >= 2) {
        result.push_back(std::move(current));
      }
      current = {first, second};
    }
  }
  if (current.size() >= 2) {
    result.push_back(std::move(current));
  }
  return result;
}

double expansion_coordinate(int32_t coordinate) {
  // Valhalla returns expansion geometry as integer microdegrees. Carry it as
  // the correctly-rounded quotient; output and canonical keys re-round to
  // 1e-7, so this double only needs to be deterministic (it is -- IEEE
  // division), not a byte-exact replay of the old RapidJSON GeoJSON rounding.
  return coordinate / 1e6;
}

struct ExpansionEdgeRef {
  uint64_t id;
  uint32_t expansion_index;
};

using ExpansionEdgeIndex = std::vector<ExpansionEdgeRef>;

ExpansionEdgeIndex index_expansion_edges(const valhalla::Expansion &expansion) {
  const int edge_count = expansion.geometries_size();
  if (expansion.edge_id_size() != edge_count ||
      expansion.pred_edge_id_size() != edge_count ||
      expansion.durations_size() != edge_count ||
      expansion.distances_size() != edge_count) {
    throw std::runtime_error(
        "Valhalla returned inconsistent expansion protobuf arrays");
  }
  ExpansionEdgeIndex edges;
  edges.reserve(edge_count);
  for (int index = 0; index < edge_count; ++index) {
    const valhalla::Expansion::Geometry &geometry = expansion.geometries(index);
    if (geometry.coords_size() % 2 != 0) {
      throw std::runtime_error("invalid expansion protobuf geometry");
    }
    if (geometry.coords_size() >= 4) {
      edges.push_back({expansion.edge_id(index), static_cast<uint32_t>(index)});
    }
  }
  std::sort(edges.begin(), edges.end(),
            [](const ExpansionEdgeRef &left, const ExpansionEdgeRef &right) {
              return left.id < right.id;
            });
  if (std::adjacent_find(
          edges.begin(), edges.end(),
          [](const ExpansionEdgeRef &left, const ExpansionEdgeRef &right) {
            return left.id == right.id;
          }) != edges.end()) {
    throw std::runtime_error("duplicate edge_id in deduplicated expansion");
  }
  return edges;
}

Line expansion_line(const valhalla::Expansion::Geometry &geometry) {
  Line line;
  line.reserve(geometry.coords_size() / 2);
  for (int coordinate = 0; coordinate < geometry.coords_size();
       coordinate += 2) {
    line.push_back({expansion_coordinate(geometry.coords(coordinate)),
                    expansion_coordinate(geometry.coords(coordinate + 1))});
  }
  return line;
}

Edge expansion_edge(const valhalla::Expansion &expansion,
                    const ExpansionEdgeRef &reference) {
  const uint32_t index = reference.expansion_index;
  return {
      reference.id,
      expansion.pred_edge_id(index),
      static_cast<double>(expansion.durations(index)),
      static_cast<double>(expansion.distances(index)),
      expansion_line(expansion.geometries(index)),
  };
}

double predecessor_duration(const Edge &edge,
                            const valhalla::Expansion &expansion,
                            const ExpansionEdgeIndex &edges) {
  if (edge.pred_id == kInvalidGraphId) {
    return 0;
  }
  const auto predecessor =
      std::lower_bound(edges.begin(), edges.end(), edge.pred_id,
                       [](const ExpansionEdgeRef &candidate, uint64_t id) {
                         return candidate.id < id;
                       });
  if (predecessor == edges.end() || predecessor->id != edge.pred_id) {
    throw std::runtime_error("expansion edge " + std::to_string(edge.id) +
                             " has a missing predecessor " +
                             std::to_string(edge.pred_id));
  }
  return expansion.durations(predecessor->expansion_index);
}

double segment_length(const Point &first, const Point &second) {
  constexpr double earth_radius_meters = 6'371'008.8;
  constexpr double radians_per_degree = 3.14159265358979323846 / 180.0;
  const double first_lat = first.lat * radians_per_degree;
  const double second_lat = second.lat * radians_per_degree;
  const double delta_lat = (second.lat - first.lat) * radians_per_degree;
  const double delta_lon = (second.lon - first.lon) * radians_per_degree;
  const double sin_lat = std::sin(delta_lat / 2.0);
  const double sin_lon = std::sin(delta_lon / 2.0);
  const double haversine = sin_lat * sin_lat + std::cos(first_lat) *
                                                   std::cos(second_lat) *
                                                   sin_lon * sin_lon;
  return 2.0 * earth_radius_meters *
         std::asin(std::min(1.0, std::sqrt(haversine)));
}

double line_length(const Line &line) {
  double length = 0;
  for (size_t index = 1; index < line.size(); ++index) {
    length += segment_length(line[index - 1], line[index]);
  }
  return length;
}

struct LineMeasure {
  std::vector<double> cumulative;
  double total;
};

LineMeasure measure_line(const Line &line) {
  LineMeasure measure{{}, 0};
  measure.cumulative.reserve(line.size());
  measure.cumulative.push_back(0);
  for (size_t index = 1; index < line.size(); ++index) {
    measure.total += segment_length(line[index - 1], line[index]);
    measure.cumulative.push_back(measure.total);
  }
  return measure;
}

Point interpolate(const Point &first, const Point &second, double fraction) {
  return {
      first.lon + (second.lon - first.lon) * fraction,
      first.lat + (second.lat - first.lat) * fraction,
  };
}

Line slice_line(const Line &line, const LineMeasure &measure,
                double start_fraction, double end_fraction) {
  start_fraction = std::clamp(start_fraction, 0.0, 1.0);
  end_fraction = std::clamp(end_fraction, start_fraction, 1.0);
  if (measure.total <= 0.01 || end_fraction - start_fraction <= 1e-12) {
    return {};
  }
  const double start_distance = start_fraction * measure.total;
  const double end_distance = end_fraction * measure.total;
  Line result;
  for (size_t index = 1; index < line.size(); ++index) {
    const Point &first = line[index - 1];
    const Point &second = line[index];
    const double segment_start = measure.cumulative[index - 1];
    const double segment_end = measure.cumulative[index];
    const double length = segment_end - segment_start;
    if (length <= 0 || segment_end <= start_distance ||
        segment_start >= end_distance) {
      continue;
    }
    const double overlap_start = std::max(start_distance, segment_start);
    const double overlap_end = std::min(end_distance, segment_end);
    const Point clipped_first =
        interpolate(first, second, (overlap_start - segment_start) / length);
    const Point clipped_second =
        interpolate(first, second, (overlap_end - segment_start) / length);
    if (result.empty()) {
      result.push_back(clipped_first);
    } else if (!same_point(result.back(), clipped_first)) {
      result.push_back(clipped_first);
    }
    if (!same_point(result.back(), clipped_second)) {
      result.push_back(clipped_second);
    }
  }
  if (result.size() < 2) {
    return {};
  }
  return result;
}

Line slice_line(const Line &line, double start_fraction, double end_fraction) {
  return slice_line(line, measure_line(line), start_fraction, end_fraction);
}

std::optional<Interval> reachable_interval(const Edge &edge,
                                           double start_seconds,
                                           double max_seconds,
                                           double traversal_seconds) {
  const bool origin = edge.pred_id == kInvalidGraphId;
  if (edge.duration < start_seconds) {
    throw std::runtime_error(
        "expansion edge duration precedes its predecessor");
  }
  if (max_seconds <= start_seconds) {
    return std::nullopt;
  }

  double start_fraction = 0;
  double end_fraction = 1;
  if (origin) {
    const double full_length = line_length(edge.line);
    if (full_length <= 0.01 || edge.duration <= 0 || edge.distance <= 0) {
      return std::nullopt;
    }
    const double origin_fraction =
        std::clamp(edge.distance / full_length, 0.0, 1.0);
    const double time_fraction =
        std::clamp(max_seconds / (edge.duration + 1.0), 0.0, 1.0);
    // Reverse expansion emits the opposing edge, oriented away from the
    // destination. The reachable part therefore starts at the destination's
    // fixed position and grows outward as more traversal time is available.
    start_fraction = 1.0 - origin_fraction;
    end_fraction = start_fraction + origin_fraction * time_fraction;
  } else {
    if (!(traversal_seconds > 0)) {
      throw std::runtime_error("expansion edge has no traversal seconds");
    }
    // Expansion durations are integer-truncated cumulative seconds. Treat the
    // unknown fractional second conservatively, and pay the complete turn
    // transition before putting any of the new road edge into the contour.
    const double transition_seconds =
        std::max(0.0, edge.duration - start_seconds + 1.0 - traversal_seconds);
    const double traversal_start = start_seconds + transition_seconds;
    if (max_seconds <= traversal_start) {
      return std::nullopt;
    }
    end_fraction = (max_seconds - traversal_start) / traversal_seconds;
  }

  start_fraction = std::clamp(start_fraction, 0.0, 1.0);
  end_fraction = std::clamp(end_fraction, start_fraction, 1.0);
  if (end_fraction - start_fraction <= 1e-12) {
    return std::nullopt;
  }
  return Interval{start_fraction, end_fraction};
}

std::string point_key(const Point &point) {
  // Decimal key, byte-for-byte matching the finalizer's validate_geometry() so
  // both agree on canonical orientation (see destination-lookup-native.cc).
  return std::to_string(std::llround(point.lon * 10'000'000)) + "," +
         std::to_string(std::llround(point.lat * 10'000'000));
}

struct CanonicalLine {
  std::string key;
  Line line;
  bool reversed;
};

// The 1e-7 rounding and consecutive-duplicate dedup of canonical_line(),
// split out so the per-directed-edge cache can normalize an incoming line
// without rebuilding the canonical key strings. Returns {} when fewer than
// two distinct rounded points remain (degenerate edge).
Line rounded_line(const Line &line) {
  Line normalized;
  normalized.reserve(line.size());
  for (const auto &point : line) {
    const Point rounded{
        std::llround(point.lon * 10'000'000) / 10'000'000.0,
        std::llround(point.lat * 10'000'000) / 10'000'000.0,
    };
    if (normalized.empty() || !same_point(normalized.back(), rounded)) {
      normalized.push_back(rounded);
    }
  }
  if (normalized.size() < 2) {
    return {};
  }
  return normalized;
}

CanonicalLine canonical_from_normalized(Line normalized) {
  std::string forward;
  std::string reverse;
  for (const auto &point : normalized) {
    forward += point_key(point) + ";";
  }
  for (auto point = normalized.rbegin(); point != normalized.rend(); ++point) {
    reverse += point_key(*point) + ";";
  }
  if (reverse < forward) {
    return {std::move(reverse), Line(normalized.rbegin(), normalized.rend()),
            true};
  }
  return {std::move(forward), std::move(normalized), false};
}

CanonicalLine canonical_line(const Line &line) {
  Line normalized = rounded_line(line);
  if (normalized.empty()) {
    return {};
  }
  return canonical_from_normalized(std::move(normalized));
}

// String-canonical identity of one undirected edge pair, computed by
// canonical_line() once per pair per worker and shared by both directed
// edges' cache entries.
struct CanonicalGeometry {
  std::string key;
  Line line;
};

// Per-directed-edge cache (map key: directed edge id). `opposing` is filled
// on first touch of any edge, origin edges included (cheap, needed for the
// canonical map key). `reverse_secs` is lazily filled on the first non-origin
// use only — origin edges have no traversal seconds — with validation at fill
// time; the std::optional makes reading an unset value unrepresentable.
// `reversed` is a property of this directed edge, not of the pair: both
// directed edges of a pair arrive (requests use "skip_opposites":false) with
// opposite line orientations and therefore opposite fraction frames.
struct EdgeCacheEntry {
  uint64_t opposing = 0;
  uint64_t canonical_id = 0;
  bool reversed = false;
  std::shared_ptr<const CanonicalGeometry> canonical; // nullptr => degenerate
  std::optional<double> reverse_secs;
};

using EdgeCache = std::map<uint64_t, EdgeCacheEntry>;

bool lines_equal(const Line &left, const Line &right) {
  return left.size() == right.size() &&
         std::equal(left.begin(), left.end(), right.begin(), same_point);
}

// Derive whether `normalized` runs opposite to the pair's cached canonical
// geometry, and assert geometry consistency on this re-insert: the incoming
// line must equal, point for point, either the whole canonical line or its
// whole reverse. Endpoint comparison would suffice when the endpoints
// differ; the whole-line equality tests also decide closed loops and double
// as the equality assert. A true palindrome compares equal forward, so it
// gets reversed=false — the same direction-independent ambiguity today's
// canonical_line() has.
bool derive_reversed(const Line &normalized, const Line &canonical,
                     uint64_t edge_id) {
  if (lines_equal(normalized, canonical)) {
    return false;
  }
  const Line reversed(canonical.rbegin(), canonical.rend());
  if (lines_equal(normalized, reversed)) {
    return true;
  }
  throw std::runtime_error("expansion edge " + std::to_string(edge_id) +
                           " geometry disagrees with its opposing edge");
}

EdgeCacheEntry &edge_cache_entry(const Edge &edge,
                                 valhalla::baldr::GraphReader &reader,
                                 EdgeCache &cache) {
  if (const auto cached = cache.find(edge.id); cached != cache.end()) {
    return cached->second;
  }
  valhalla::baldr::graph_tile_ptr opposing_tile;
  const valhalla::baldr::GraphId opposing_id = reader.GetOpposingEdgeId(
      valhalla::baldr::GraphId(edge.id), opposing_tile);
  if (!opposing_id.is_valid() || opposing_tile == nullptr) {
    throw std::runtime_error("expansion edge " + std::to_string(edge.id) +
                             " has no opposing edge");
  }
  // A hierarchy shortcut's geometry spans several base edges, which would
  // break the 1:1 mapping between min(edge_id, opposing_id) and one
  // canonical polyline; shortcuts travel in pairs, so checking the opposing
  // directed edge (whose tile is already open) covers this edge too.
  if (opposing_tile->directededge(opposing_id)->is_shortcut()) {
    throw std::runtime_error("expansion edge " + std::to_string(edge.id) +
                             " opposes hierarchy shortcut edge " +
                             std::to_string(opposing_id.value));
  }
  EdgeCacheEntry entry;
  entry.opposing = opposing_id.value;
  entry.canonical_id = std::min<uint64_t>(edge.id, opposing_id.value);
  Line normalized = rounded_line(edge.line);
  if (const auto opposite = cache.find(entry.opposing);
      opposite != cache.end()) {
    entry.canonical = opposite->second.canonical;
    if (entry.canonical == nullptr) {
      if (!normalized.empty()) {
        throw std::runtime_error("expansion edge " + std::to_string(edge.id) +
                                 " geometry disagrees with its opposing edge");
      }
    } else {
      entry.reversed =
          derive_reversed(normalized, entry.canonical->line, edge.id);
    }
  } else if (!normalized.empty()) {
    CanonicalLine canonical = canonical_from_normalized(std::move(normalized));
    entry.reversed = canonical.reversed;
    entry.canonical = std::make_shared<const CanonicalGeometry>(
        CanonicalGeometry{std::move(canonical.key), std::move(canonical.line)});
  }
  return cache.emplace(edge.id, std::move(entry)).first->second;
}

double reverse_edge_traversal_seconds(const Edge &edge, EdgeCacheEntry &entry,
                                      valhalla::baldr::GraphReader &reader,
                                      const valhalla::sif::cost_ptr_t &costing) {
  if (entry.reverse_secs) {
    return *entry.reverse_secs;
  }
  const valhalla::baldr::GraphId opposing_id(entry.opposing);
  const valhalla::baldr::graph_tile_ptr opposing_tile =
      reader.GetGraphTile(opposing_id);
  if (opposing_tile == nullptr) {
    throw std::runtime_error("expansion edge " + std::to_string(edge.id) +
                             " has no opposing edge");
  }
  const auto *opposing_edge = opposing_tile->directededge(opposing_id);
  const double seconds =
      costing->EdgeCost(opposing_edge, opposing_id, opposing_tile).secs;
  if (!(seconds > 0) || !std::isfinite(seconds)) {
    throw std::runtime_error(
        "expansion edge " + std::to_string(edge.id) +
        " has invalid traversal seconds " + std::to_string(seconds) +
        " for opposing length " + std::to_string(opposing_edge->length()) +
        " and use " + std::to_string(static_cast<int>(opposing_edge->use())));
  }
  entry.reverse_secs = seconds;
  return seconds;
}

bool add_destination_interval(DestinationEdges &destination,
                              const EdgeCacheEntry &cache_entry,
                              Interval interval, size_t request_index,
                              size_t minute_index) {
  if (cache_entry.canonical == nullptr) {
    return false;
  }
  if (cache_entry.reversed) {
    interval = {1.0 - interval.end, 1.0 - interval.start};
  }
  auto [entry, inserted] =
      destination.try_emplace(cache_entry.canonical_id, cache_entry.canonical);
  static_cast<void>(inserted);
  if (interval.start == 0.0 && interval.end == 1.0) {
    destination.add_full(entry->second, minute_index, request_index);
  } else {
    entry->second.partials.push_back({interval,
                                      static_cast<uint32_t>(request_index),
                                      static_cast<uint32_t>(minute_index)});
  }
  return true;
}

bool interval_intersects_bounds(const Line &line, const Interval &interval,
                                const Bounds &bounds) {
  const Line reachable = slice_line(line, interval.start, interval.end);
  return !clip_line(reachable, bounds).empty();
}

std::vector<Interval> merge_intervals(std::vector<Interval> intervals) {
  std::sort(intervals.begin(), intervals.end(),
            [](const Interval &left, const Interval &right) {
              return left.start < right.start ||
                     (left.start == right.start && left.end < right.end);
            });
  std::vector<Interval> merged;
  for (const Interval interval : intervals) {
    if (interval.end - interval.start <= 1e-12) {
      continue;
    }
    if (merged.empty() || interval.start > merged.back().end + 1e-12) {
      merged.push_back(interval);
    } else {
      merged.back().end = std::max(merged.back().end, interval.end);
    }
  }
  return merged;
}

struct DestinationEdgeRef {
  const DestinationEdges *edges;
  const DestinationEdge *edge;
};

using DestinationEdgeGroup = std::vector<DestinationEdgeRef>;

// K-way merge the workers' numeric edge maps without constructing another
// country-wide map. The first reference in a group is from the lowest worker
// index, matching the old worker merge's geometry representative.
template <typename Function>
void for_each_destination_edge_group(
    const std::vector<DestinationEdges> &worker_destinations,
    Function &&function) {
  struct Cursor {
    const DestinationEdges *edges;
    DestinationEdges::const_iterator current;
    DestinationEdges::const_iterator end;
  };
  std::vector<Cursor> cursors;
  cursors.reserve(worker_destinations.size());
  for (const DestinationEdges &edges : worker_destinations) {
    if (!edges.empty()) {
      cursors.push_back({&edges, edges.begin(), edges.end()});
    }
  }

  DestinationEdgeGroup group;
  group.reserve(cursors.size());
  while (!cursors.empty()) {
    const uint64_t canonical_id =
        std::min_element(cursors.begin(), cursors.end(),
                         [](const Cursor &left, const Cursor &right) {
                           return left.current->first < right.current->first;
                         })
            ->current->first;
    group.clear();
    for (Cursor &cursor : cursors) {
      if (cursor.current != cursor.end &&
          cursor.current->first == canonical_id) {
        group.push_back({cursor.edges, &cursor.current->second});
        ++cursor.current;
      }
    }
    function(canonical_id, group);
    cursors.erase(std::remove_if(cursors.begin(), cursors.end(),
                                 [](const Cursor &cursor) {
                                   return cursor.current == cursor.end;
                                 }),
                  cursors.end());
  }
}

bool contains(const std::vector<Interval> &intervals, double position) {
  return std::any_of(
      intervals.begin(), intervals.end(), [&](const Interval &interval) {
        return interval.start <= position && position <= interval.end;
      });
}

void validate_destination_geometry(
    const std::vector<DestinationEdges> &worker_destinations) {
  for_each_destination_edge_group(
      worker_destinations,
      [](uint64_t canonical_id, const DestinationEdgeGroup &group) {
        const std::string &key = group.front().edge->canonical->key;
        for (const DestinationEdgeRef &reference : group) {
          if (reference.edge->canonical->key != key) {
            throw std::runtime_error(
                "canonical edge " + std::to_string(canonical_id) +
                " has inconsistent geometry across workers");
          }
        }
      });
}

struct RelationRun {
  double start;
  double end;
  uint32_t set_id;
};

struct RelationPoint {
  double point;
  uint32_t set_id;
};

struct RelationBand {
  uint32_t minute_index;
  std::vector<RelationRun> runs;
  std::vector<RelationPoint> points;
};

struct RelationEdge {
  uint64_t canonical_id;
  const CanonicalGeometry *geometry;
  std::vector<RelationBand> bands;
};

struct RelationBatch {
  // Map nodes keep member-vector addresses stable while relations retain only
  // compact local ids. First encounter is deterministic because canonical
  // edges, minute bands, endpoints, and lookup ids are all ordered.
  std::map<std::vector<uint32_t>, uint32_t> set_ids;
  std::vector<const std::vector<uint32_t> *> sets;
  std::vector<RelationEdge> edges;

  uint32_t intern(std::vector<uint32_t> members) {
    auto [entry, inserted] =
        set_ids.try_emplace(std::move(members), static_cast<uint32_t>(sets.size()));
    if (inserted) {
      sets.push_back(&entry->first);
    }
    return entry->second;
  }
};

struct MembershipEvents {
  std::set<uint32_t> starts;
  std::set<uint32_t> ends;
};

// Classify one bounded origin batch before it leaves the routing process.
// Lookup ids are disjoint between batches. The native finalizer overlays the
// compact batch functions by set union, instead of inserting and re-reading
// every raw destination membership (82 million rows for Lithuania).
RelationBand classify_memberships(
    uint32_t minute_index,
    std::map<uint32_t, std::vector<Interval>> memberships,
    RelationBatch &batch) {
  std::map<double, MembershipEvents> events;
  for (auto &[lookup_id, intervals] : memberships) {
    std::sort(intervals.begin(), intervals.end(),
              [](const Interval &left, const Interval &right) {
                return left.start < right.start ||
                       (left.start == right.start && left.end < right.end);
              });
    std::vector<Interval> merged;
    for (const Interval interval : intervals) {
      if (merged.empty() || interval.start > merged.back().end) {
        merged.push_back(interval);
      } else {
        merged.back().end = std::max(merged.back().end, interval.end);
      }
    }
    for (const Interval interval : merged) {
      events[interval.start].starts.insert(lookup_id);
      events[interval.end].ends.insert(lookup_id);
    }
  }

  RelationBand result{minute_index, {}, {}};
  std::set<uint32_t> active;
  std::optional<double> previous;
  for (const auto &[point, event] : events) {
    if (previous && *previous < point && !active.empty()) {
      std::vector<uint32_t> members(active.begin(), active.end());
      const uint32_t set_id = batch.intern(std::move(members));
      if (!result.runs.empty() && result.runs.back().end == *previous &&
          result.runs.back().set_id == set_id) {
        result.runs.back().end = point;
      } else {
        result.runs.push_back({*previous, point, set_id});
      }
    }
    std::set<uint32_t> at_point = active;
    at_point.insert(event.starts.begin(), event.starts.end());
    at_point.insert(event.ends.begin(), event.ends.end());
    if (!at_point.empty()) {
      result.points.push_back(
          {point, batch.intern({at_point.begin(), at_point.end()})});
    }
    active.insert(event.starts.begin(), event.starts.end());
    for (const uint32_t lookup_id : event.ends) {
      active.erase(lookup_id);
    }
    previous = point;
  }
  if (!active.empty()) {
    throw std::runtime_error("relation sweep ended with active memberships");
  }
  return result;
}

RelationBatch build_relation_batch(
    const std::vector<DestinationEdges> &worker_destinations,
    const std::vector<int> &minutes, const std::vector<Request> &requests) {
  RelationBatch result;
  for_each_destination_edge_group(
      worker_destinations,
      [&](uint64_t canonical_id, const DestinationEdgeGroup &group) {
        RelationEdge edge{canonical_id,
                          group.front().edge->canonical.get(), {}};
        for (size_t minute_index = 0; minute_index < minutes.size();
             ++minute_index) {
          std::map<uint32_t, std::vector<Interval>> memberships;
          for (const DestinationEdgeRef &reference : group) {
            reference.edges->for_each_full(
                *reference.edge, minute_index, [&](size_t request_index) {
                  memberships[requests[request_index].lookup_id].push_back(
                      {0.0, 1.0});
                });
            for (const DestinationInterval &partial : reference.edge->partials) {
              if (partial.minute_index == minute_index) {
                memberships[requests[partial.request_index].lookup_id]
                    .push_back(partial.interval);
              }
            }
          }
          if (!memberships.empty()) {
            edge.bands.push_back(classify_memberships(
                static_cast<uint32_t>(minute_index), std::move(memberships),
                result));
          }
        }
        if (!edge.bands.empty()) {
          result.edges.push_back(std::move(edge));
        }
      });
  return result;
}

void write_relation_header(std::ostream &output,
                           const std::vector<int> &minutes) {
  using namespace mapgames::relations;
  output.write(kMagic.data(), kMagic.size());
  write_le(output, kVersion);
  write_le(output, static_cast<uint32_t>(minutes.size()));
  for (const int minute : minutes) {
    write_le(output, static_cast<uint32_t>(minute));
  }
  require_output(output);
}

void write_relation_batch(std::ostream &output, const RelationBatch &batch) {
  using namespace mapgames::relations;
  write_le(output, kBatchMarker);
  write_le(output, static_cast<uint32_t>(batch.sets.size()));
  for (const std::vector<uint32_t> *members : batch.sets) {
    write_le(output, static_cast<uint32_t>(members->size()));
    for (const uint32_t member : *members) {
      write_le(output, member);
    }
  }
  write_le(output, static_cast<uint32_t>(batch.edges.size()));
  for (const RelationEdge &edge : batch.edges) {
    write_le(output, edge.canonical_id);
    write_le(output, static_cast<uint32_t>(edge.geometry->line.size()));
    for (const Point &point : edge.geometry->line) {
      write_le(output,
               static_cast<int32_t>(std::llround(point.lon * 10'000'000)));
      write_le(output,
               static_cast<int32_t>(std::llround(point.lat * 10'000'000)));
    }
    write_le(output, static_cast<uint32_t>(edge.bands.size()));
    for (const RelationBand &band : edge.bands) {
      write_le(output, band.minute_index);
      write_le(output, static_cast<uint32_t>(band.runs.size()));
      for (const RelationRun &run : band.runs) {
        write_double(output, run.start);
        write_double(output, run.end);
        write_le(output, run.set_id);
      }
      write_le(output, static_cast<uint32_t>(band.points.size()));
      for (const RelationPoint &point : band.points) {
        write_double(output, point.point);
        write_le(output, point.set_id);
      }
    }
  }
  require_output(output);
}

void write_line(std::ostream &output, const Line &line) {
  output << '[' << std::setprecision(15);
  for (size_t index = 0; index < line.size(); ++index) {
    if (index != 0) {
      output << ',';
    }
    output << '[' << line[index].lon << ',' << line[index].lat << ']';
  }
  output << ']';
}

void write_multiline(std::ostream &output, const Lines &lines) {
  output << "{\"type\":\"MultiLineString\",\"coordinates\":[";
  bool first = true;
  for (const auto &[key, line] : lines) {
    static_cast<void>(key);
    if (!first) {
      output << ',';
    }
    first = false;
    write_line(output, line);
  }
  output << "]}";
}

std::string bbox_json(const Bounds &bounds) {
  std::ostringstream output;
  output << std::setprecision(15) << '[' << bounds.min_lon << ','
         << bounds.min_lat << ',' << bounds.max_lon << ',' << bounds.max_lat
         << ']';
  return output.str();
}

// ---------------------------------------------------------------------------
// Merge the normalized relation database directly into one edge-attributed
// network.geojson. Classified intervals are coalesced as each ordered geometry
// completes; source groups are consumed while the output pieces are built.
struct MergeRequirement {
  std::string key;
  std::vector<int> minutes;
};

// Per canonical-geometry-string group: the per-requirement,
// per-band-minute concatenated (then merged) interval lists of every dump
// entry sharing this geometry.
struct MergeGroup {
  Line line;
  std::vector<std::map<int, std::vector<Interval>>> requirements;
};

bool path_present(const std::filesystem::path &path) {
  std::error_code error;
  const auto status = std::filesystem::symlink_status(path, error);
  if (error == std::errc::no_such_file_or_directory) return false;
  if (error) {
    throw std::runtime_error("could not inspect path " + path.string() +
                             ": " + error.message());
  }
  return status.type() != std::filesystem::file_type::not_found;
}

bool same_file_identity(const std::filesystem::path &left,
                        const std::filesystem::path &right) {
  const auto left_absolute = std::filesystem::absolute(left).lexically_normal();
  const auto right_absolute = std::filesystem::absolute(right).lexically_normal();
  if (left_absolute == right_absolute) return true;
  // weakly_canonical resolves every existing symlink in the target or parent
  // while still accepting a final output component that does not exist yet.
  if (std::filesystem::weakly_canonical(left_absolute) ==
      std::filesystem::weakly_canonical(right_absolute))
    return true;
  if (path_present(left_absolute) && path_present(right_absolute)) {
    std::error_code error;
    const bool equivalent =
        std::filesystem::equivalent(left_absolute, right_absolute, error);
    if (error) {
      throw std::runtime_error("could not compare path identity: " +
                               error.message());
    }
    if (equivalent) return true;
  }
  return false;
}

void require_distinct_paths(
    const std::vector<std::pair<std::string, std::filesystem::path>> &paths) {
  for (size_t left = 0; left < paths.size(); ++left) {
    for (size_t right = left + 1; right < paths.size(); ++right) {
      if (same_file_identity(paths[left].second, paths[right].second)) {
        throw std::runtime_error(paths[left].first + " and " +
                                 paths[right].first +
                                 " must identify different files");
      }
    }
  }
}

std::filesystem::path temporary_sibling(const std::filesystem::path &target,
                                        const std::string &purpose) {
  const std::filesystem::path absolute =
      std::filesystem::absolute(target).lexically_normal();
  std::string pattern =
      (absolute.parent_path() /
       (absolute.filename().string() + ".mapgames-" + purpose + "-XXXXXX"))
          .string();
  std::vector<char> writable(pattern.begin(), pattern.end());
  writable.push_back('\0');
  const int descriptor = mkstemp(writable.data());
  if (descriptor < 0) {
    throw std::runtime_error("could not create temporary sibling for " +
                             target.string());
  }
  if (close(descriptor) != 0) {
    const std::filesystem::path failed(writable.data());
    std::error_code ignored;
    std::filesystem::remove(failed, ignored);
    throw std::runtime_error("could not close temporary sibling for " +
                             target.string());
  }
  return writable.data();
}

void remove_owned_path(const std::filesystem::path &path) noexcept {
  if (path.empty()) return;
  std::error_code ignored;
  std::filesystem::remove(path, ignored);
}

void checked_close(std::ofstream &output, const std::filesystem::path &path) {
  output.flush();
  const bool flush_failed = !output;
  output.close();
  if (flush_failed) {
    throw std::runtime_error("could not flush output: " + path.string());
  }
  if (!output) {
    throw std::runtime_error("could not close output: " + path.string());
  }
}

void publish_output_pair(const std::filesystem::path &network_temporary,
                         const std::filesystem::path &network_target,
                         const std::filesystem::path &groups_temporary,
                         const std::filesystem::path &groups_target) {
  const bool had_network = path_present(network_target);
  const bool had_groups = path_present(groups_target);
  std::filesystem::path network_backup;
  std::filesystem::path groups_backup;
  bool network_backed_up = false;
  bool groups_backed_up = false;
  bool network_published = false;
  bool groups_published = false;
  const auto rollback = [&]() noexcept {
    std::error_code ignored;
    if (groups_published) std::filesystem::remove(groups_target, ignored);
    ignored.clear();
    if (network_published) std::filesystem::remove(network_target, ignored);
    ignored.clear();
    if (network_backed_up) {
      std::filesystem::rename(network_backup, network_target, ignored);
      if (!ignored) network_backed_up = false;
    }
    ignored.clear();
    if (groups_backed_up) {
      std::filesystem::rename(groups_backup, groups_target, ignored);
      if (!ignored) groups_backed_up = false;
    }
  };
  try {
    // Reserve same-directory backup names before touching either target. On
    // POSIX rename atomically replaces the empty reservation with the old
    // file; rollback can therefore restore regular files, symlinks, or devices
    // without copying their contents.
    if (had_network) {
      network_backup = temporary_sibling(network_target, "backup");
      std::filesystem::rename(network_target, network_backup);
      network_backed_up = true;
    }
    if (had_groups) {
      groups_backup = temporary_sibling(groups_target, "backup");
      std::filesystem::rename(groups_target, groups_backup);
      groups_backed_up = true;
    }
    std::filesystem::rename(network_temporary, network_target);
    network_published = true;
    std::filesystem::rename(groups_temporary, groups_target);
    groups_published = true;
  } catch (...) {
    const std::exception_ptr publish_failure = std::current_exception();
    rollback();
    // A failed restore deliberately leaves its uniquely named backup in the
    // target directory. Deleting it here would turn a recoverable filesystem
    // failure into data loss.
    if (!network_backed_up) remove_owned_path(network_backup);
    if (!groups_backed_up) remove_owned_path(groups_backup);
    if (network_backed_up || groups_backed_up) {
      std::string message = "output-pair rollback failed; retained backup";
      if (network_backed_up) message += " " + network_backup.string();
      if (groups_backed_up) message += " " + groups_backup.string();
      try {
        std::rethrow_exception(publish_failure);
      } catch (...) {
        std::throw_with_nested(std::runtime_error(message));
      }
    }
    std::rethrow_exception(publish_failure);
  }
  remove_owned_path(network_backup);
  remove_owned_path(groups_backup);
}

class MergeDatabase {
public:
  explicit MergeDatabase(const std::filesystem::path &path) {
    if (sqlite3_open_v2(path.c_str(), &database_, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK)
      throw std::runtime_error("could not open relation database: " +
                               std::string(sqlite3_errmsg(database_)));
  }
  ~MergeDatabase() { sqlite3_close(database_); }
  sqlite3 *get() const { return database_; }
private:
  sqlite3 *database_ = nullptr;
};

class MergeQuery {
public:
  MergeQuery(sqlite3 *database, const char *sql) : database_(database) {
    if (sqlite3_prepare_v2(database, sql, -1, &statement_, nullptr) != SQLITE_OK)
      throw std::runtime_error("could not prepare relation query: " +
                               std::string(sqlite3_errmsg(database)));
  }
  ~MergeQuery() { sqlite3_finalize(statement_); }
  bool next() {
    const int result = sqlite3_step(statement_);
    if (result == SQLITE_ROW) return true;
    if (result == SQLITE_DONE) return false;
    throw std::runtime_error("relation query failed: " +
                             std::string(sqlite3_errmsg(database_)));
  }
  int64_t integer(int column) const { return sqlite3_column_int64(statement_, column); }
  double number(int column) const { return sqlite3_column_double(statement_, column); }
  std::string text(int column) const {
    const unsigned char *value = sqlite3_column_text(statement_, column);
    if (value == nullptr) throw std::runtime_error("unexpected NULL relation text");
    return reinterpret_cast<const char *>(value);
  }
  const void *blob(int column) const { return sqlite3_column_blob(statement_, column); }
  int bytes(int column) const { return sqlite3_column_bytes(statement_, column); }
private:
  sqlite3 *database_;
  sqlite3_stmt *statement_ = nullptr;
};

Line delta_e7_line(const void *data, int bytes) {
  if (data == nullptr || bytes < 16 || bytes % 8 != 0)
    throw std::runtime_error("invalid delta E7 geometry in relation database");
  const auto *input = static_cast<const unsigned char *>(data);
  const auto read_i32 = [&](size_t offset) {
    const uint32_t value = static_cast<uint32_t>(input[offset]) |
        static_cast<uint32_t>(input[offset + 1]) << 8 |
        static_cast<uint32_t>(input[offset + 2]) << 16 |
        static_cast<uint32_t>(input[offset + 3]) << 24;
    return std::bit_cast<int32_t>(value);
  };
  Line line;
  line.reserve(bytes / 8);
  int64_t lon = read_i32(0), lat = read_i32(4);
  for (size_t offset = 0; offset < static_cast<size_t>(bytes); offset += 8) {
    if (offset != 0) {
      lon += read_i32(offset);
      lat += read_i32(offset + 4);
    }
    if (lon < -1'800'000'000 || lon > 1'800'000'000 ||
        lat < -900'000'000 || lat > 900'000'000)
      throw std::runtime_error("delta E7 coordinate out of bounds");
    const Point point{lon / 10'000'000.0, lat / 10'000'000.0};
    if (!line.empty() && same_point(line.back(), point))
      throw std::runtime_error("degenerate relation geometry");
    line.push_back(point);
  }
  return line;
}

void load_merge_requirements(sqlite3 *database,
                             std::vector<MergeRequirement> &requirements) {
  MergeQuery requirement_rows(database,
      "SELECT requirement,key,service,mode,mode_bit FROM requirements ORDER BY requirement");
  while (requirement_rows.next()) {
    const int64_t ordinal = requirement_rows.integer(0);
    if (ordinal != static_cast<int64_t>(requirements.size()))
      throw std::runtime_error("non-contiguous relation requirement ordinals");
    const std::string key = requirement_rows.text(1);
    const std::string service = requirement_rows.text(2);
    const std::string mode = requirement_rows.text(3);
    const int64_t mode_bit = requirement_rows.integer(4);
    const bool lowercase = !service.empty() && !mode.empty() &&
        std::all_of(service.begin(), service.end(), [](char value) {
          return value >= 'a' && value <= 'z';
        }) && std::all_of(mode.begin(), mode.end(), [](char value) {
          return value >= 'a' && value <= 'z';
        });
    if (!lowercase || key != service + '_' + mode ||
        (mode != "walk" && mode != "drive") ||
        mode_bit != (mode == "walk" ? 1 : 2))
      throw std::runtime_error("invalid relation requirement identity");
    requirements.push_back({key, {}});
  }
  if (requirements.empty()) throw std::runtime_error("relation database has no requirements");
  MergeQuery preset_rows(database,
      "SELECT requirement,minute FROM presets ORDER BY requirement,minute");
  while (preset_rows.next()) {
    const int64_t requirement = preset_rows.integer(0), minute = preset_rows.integer(1);
    if (requirement < 0 || requirement >= static_cast<int64_t>(requirements.size()) || minute <= 0)
      throw std::runtime_error("invalid relation preset");
    auto &minutes = requirements[requirement].minutes;
    if (!minutes.empty() && minute <= minutes.back())
      throw std::runtime_error("relation preset minutes are not ascending");
    minutes.push_back(minute);
  }
  for (const auto &requirement : requirements)
    if (requirement.minutes.empty()) throw std::runtime_error("requirement has no presets");
}

// A classified, coalesced, not-yet-sliced piece. attr is
// indexed like the requirement list; -1 = requirement absent (unreachable).
struct MergePiece {
  double start;
  double end;
  std::vector<int> attr;
};

// For one geometry group: endpoint union across every
// requirement's bands, 1e-12 first-wins dedup, midpoint classification with
// the nesting abort, and coalescing of adjacent pieces with equal attribute
// maps.
std::vector<MergePiece>
segment_group(const MergeGroup &group,
              const std::vector<MergeRequirement> &requirements) {
  std::vector<double> endpoints;
  for (const std::map<int, std::vector<Interval>> &bands : group.requirements) {
    for (const auto &[minute, band] : bands) {
      static_cast<void>(minute);
      for (const Interval &interval : band) {
        endpoints.push_back(interval.start);
        endpoints.push_back(interval.end);
      }
    }
  }
  std::sort(endpoints.begin(), endpoints.end());
  endpoints.erase(std::unique(endpoints.begin(), endpoints.end(),
                              [](double left, double right) {
                                return std::abs(left - right) <= 1e-12;
                              }),
                  endpoints.end());

  std::vector<MergePiece> pieces;
  std::optional<MergePiece> pending;
  const auto flush = [&]() {
    if (pending) {
      pieces.push_back(std::move(*pending));
      pending.reset();
    }
  };
  for (size_t endpoint_index = 1; endpoint_index < endpoints.size();
       ++endpoint_index) {
    const double start = endpoints[endpoint_index - 1];
    const double end = endpoints[endpoint_index];
    if (end - start <= 1e-12) {
      continue;
    }
    const double midpoint = (start + end) / 2.0;
    std::vector<int> attr(requirements.size(), -1);
    bool any = false;
    for (size_t requirement_index = 0; requirement_index < requirements.size();
         ++requirement_index) {
      const std::map<int, std::vector<Interval>> &bands =
          group.requirements[requirement_index];
      bool found = false;
      for (const int minute : requirements[requirement_index].minutes) {
        const auto band = bands.find(minute);
        const bool present =
            band != bands.end() && contains(band->second, midpoint);
        if (present && !found) {
          found = true;
          attr[requirement_index] = minute;
        } else if (!present && found) {
          throw std::runtime_error(
              "reachable edge intervals are not nested by minute threshold");
        }
      }
      any = any || found;
    }
    if (!any) {
      flush();
      continue;
    }
    if (pending && pending->attr == attr &&
        std::abs(pending->end - start) <= 1e-12) {
      pending->end = end;
    } else {
      flush();
      pending = MergePiece{start, end, std::move(attr)};
    }
  }
  flush();
  return pieces;
}

// Serialized attribute map: JSON object with keys in requirement-list order.
// The requirement list is sorted by key at startup, so this is sorted-keys
// JSON — the deterministic grouping key (and the reason merge
// output cannot depend on dump argument order).
std::string attribute_json(const std::vector<int> &attr,
                           const std::vector<MergeRequirement> &requirements) {
  std::ostringstream out;
  out << '{';
  bool first = true;
  for (size_t index = 0; index < requirements.size(); ++index) {
    if (attr[index] < 0) {
      continue;
    }
    if (!first) {
      out << ',';
    }
    first = false;
    out << json_string(requirements[index].key) << ':' << attr[index];
  }
  out << '}';
  return out.str();
}

struct NetworkPiece {
  Line line;
  std::vector<int> attr;
};

using NetworkPieces = std::map<std::string, NetworkPiece>;

// For one group: slice the coalesced pieces against one
// shared LineMeasure, computing each boundary Point once and sharing it as
// the last point of piece k and the first point of piece k+1 (naive
// independent slice_line() calls per piece would regress the shared-junction
// guarantee into hairline gaps at z14+overzoom); clip; canonicalize; insert
// with per-key attribute minimum on residual canonical-string collision.
void slice_group(const Line &line, const std::vector<MergePiece> &pieces,
                 const Bounds &bounds, NetworkPieces &out) {
  const LineMeasure measure = measure_line(line);
  if (measure.total <= 0.01) {
    return;
  }
  const auto point_at = [&](double distance) -> Point {
    size_t segment =
        std::upper_bound(measure.cumulative.begin(), measure.cumulative.end(),
                         distance) -
        measure.cumulative.begin();
    if (segment == 0) {
      segment = 1;
    }
    if (segment >= measure.cumulative.size()) {
      segment = measure.cumulative.size() - 1;
    }
    const double segment_start = measure.cumulative[segment - 1];
    const double length = measure.cumulative[segment] - segment_start;
    if (length <= 0) {
      return line[segment - 1];
    }
    return interpolate(line[segment - 1], line[segment],
                       (distance - segment_start) / length);
  };
  const auto add_piece = [&](const Line &sliced, const std::vector<int> &attr) {
    for (const Line &clipped : clip_line(sliced, bounds)) {
      CanonicalLine canonical = canonical_line(clipped);
      if (canonical.line.empty()) {
        continue;
      }
      auto [entry, inserted] =
          out.try_emplace(std::move(canonical.key),
                          NetworkPiece{std::move(canonical.line), attr});
      if (!inserted) {
        std::vector<int> &existing = entry->second.attr;
        for (size_t index = 0; index < existing.size(); ++index) {
          if (attr[index] < 0) {
            continue;
          }
          if (existing[index] < 0) {
            existing[index] = attr[index];
          } else {
            existing[index] = std::min(existing[index], attr[index]);
          }
        }
      }
    }
  };
  size_t run_start = 0;
  while (run_start < pieces.size()) {
    size_t run_end = run_start;
    while (run_end + 1 < pieces.size() &&
           pieces[run_end + 1].start == pieces[run_end].end) {
      ++run_end;
    }
    std::vector<double> distances;
    std::vector<Point> boundaries;
    distances.reserve(run_end - run_start + 2);
    boundaries.reserve(run_end - run_start + 2);
    distances.push_back(pieces[run_start].start * measure.total);
    boundaries.push_back(point_at(distances.back()));
    for (size_t index = run_start; index <= run_end; ++index) {
      distances.push_back(pieces[index].end * measure.total);
      boundaries.push_back(point_at(distances.back()));
    }
    for (size_t index = run_start; index <= run_end; ++index) {
      if (pieces[index].end - pieces[index].start <= 1e-12) {
        continue;
      }
      const size_t offset = index - run_start;
      const double start_distance = distances[offset];
      const double end_distance = distances[offset + 1];
      Line sliced;
      sliced.push_back(boundaries[offset]);
      const size_t first_vertex =
          std::upper_bound(measure.cumulative.begin(),
                           measure.cumulative.end(), start_distance) -
          measure.cumulative.begin();
      for (size_t vertex = first_vertex;
           vertex < line.size() && measure.cumulative[vertex] < end_distance;
           ++vertex) {
        if (!same_point(sliced.back(), line[vertex])) {
          sliced.push_back(line[vertex]);
        }
      }
      if (!same_point(sliced.back(), boundaries[offset + 1])) {
        sliced.push_back(boundaries[offset + 1]);
      }
      if (sliced.size() >= 2) {
        add_piece(sliced, pieces[index].attr);
      }
    }
    run_start = run_end + 1;
  }
}

// Tilemaker indexes a complete GeoJSON MultiLineString object into every z14
// tile touched by any of its members, then copies and clips that complete
// object for each tile. Country-wide attribute groups make that quadratic in
// practice. Partition each group on the same stable z10 Web Mercator grid used
// by the low-zoom skeleton: the bucket is the projected centre of a line's
// bbox, so reversing a canonical line cannot change its chunk. The bucket is
// deliberately not an output property.
constexpr unsigned kNetworkChunkZoom = 10;
using NetworkChunk = std::pair<unsigned, unsigned>;

NetworkChunk network_chunk(const Line &line) {
  if (line.empty()) {
    throw std::runtime_error("cannot spatially chunk an empty network line");
  }
  constexpr double kPi = 3.141592653589793238462643383279502884;
  double min_lon = std::numeric_limits<double>::infinity();
  double max_lon = -std::numeric_limits<double>::infinity();
  double min_latp = std::numeric_limits<double>::infinity();
  double max_latp = -std::numeric_limits<double>::infinity();
  for (const Point &point : line) {
    const double latp =
        std::asinh(std::tan(point.lat * kPi / 180.0)) * 180.0 / kPi;
    min_lon = std::min(min_lon, point.lon);
    max_lon = std::max(max_lon, point.lon);
    min_latp = std::min(min_latp, latp);
    max_latp = std::max(max_latp, latp);
  }
  constexpr unsigned dimension = 1u << kNetworkChunkZoom;
  const auto clamp_bucket = [](double coordinate) {
    return static_cast<unsigned>(std::clamp(
        std::floor(coordinate), 0.0, static_cast<double>(dimension - 1)));
  };
  return {
      clamp_bucket(((min_lon + max_lon) / 2.0 + 180.0) / 360.0 * dimension),
      clamp_bucket((180.0 - (min_latp + max_latp) / 2.0) / 360.0 *
                   dimension),
  };
}

// Group pieces by serialized attribute map and then spatial bucket.
// MultiLineString members retain canonical-key order; features are ordered by
// (serialized attribute map, bucket x, bucket y). Every chunk of an attribute
// group carries the same `g` (0..N-1 by attribute-map order) — the group id of the
// low-zoom fast-path (docs/lowzoom-fastpath.md): the single
// source of truth that coarsen.py carries through and that the browser
// metadata `groups` list is derived from. The compact groups sidecar is
// written once per attribute group in this same loop, avoiding a second parser
// for the country-wide GeoJSON.
// `g` is a per-build index; it must never be persisted client-side across
// deploys.
void write_network_collection(const std::filesystem::path &path,
                              const std::filesystem::path &groups_path,
                              const NetworkPieces &pieces,
                              const std::vector<MergeRequirement> &requirements,
                              const Bounds &bounds) {
  std::ofstream groups_output(groups_path, std::ios::binary);
  if (!groups_output) {
    throw std::runtime_error("could not open output: " +
                             groups_path.string());
  }
  std::ofstream output(path, std::ios::binary);
  if (!output) {
    try {
      checked_close(groups_output, groups_path);
    } catch (...) {
      std::throw_with_nested(std::runtime_error(
          "could not open network output: " + path.string()));
    }
    throw std::runtime_error("could not open output: " + path.string());
  }
  // Keep only pointers while regrouping by attributes. Copying every Line
  // here used to retain a second country-wide geometry representation for
  // the whole serialization pass.
  std::map<std::string,
           std::map<NetworkChunk, std::vector<const Line *>>> groups;
  for (const auto &[key, piece] : pieces) {
    static_cast<void>(key);
    groups[attribute_json(piece.attr, requirements)]
          [network_chunk(piece.line)]
              .push_back(&piece.line);
  }
  output << "{\"type\":\"FeatureCollection\",\"bbox\":" << bbox_json(bounds)
         << ",\"features\":[";
  groups_output << "{\"schema_version\":1,\"group_count\":" << groups.size()
                << ",\"groups\":[";
  bool first = true;
  size_t group_index = 0;
  for (const auto &[attributes, chunks] : groups) {
    // Splice "g" into the serialized attribute map: {...attrs...,"g":N}.
    // Empty attribute maps are skipped at segmentation time, so the map
    // always has at least one key; assert rather than special-case.
    if (attributes.size() < 3 || attributes.back() != '}') {
      throw std::runtime_error("unexpected empty attribute map for group " +
                               std::to_string(group_index));
    }
    const std::string attributes_with_group =
        attributes.substr(0, attributes.size() - 1) + ",\"g\":" +
        std::to_string(group_index) + '}';
    if (group_index != 0) groups_output << ',';
    groups_output << attributes_with_group;
    ++group_index;
    for (const auto &[bucket, grouped_lines] : chunks) {
      static_cast<void>(bucket);
      if (!first) {
        output << ',';
      }
      first = false;
      output << "{\"type\":\"Feature\",\"properties\":"
             << attributes_with_group << ",\"geometry\":";
      output << "{\"type\":\"MultiLineString\",\"coordinates\":[";
      bool first_line = true;
      for (const Line *line : grouped_lines) {
        if (!first_line) output << ',';
        first_line = false;
        write_line(output, *line);
      }
      output << "]}";
      output << '}';
    }
  }
  output << "]}\n";
  groups_output << "]}\n";
  std::exception_ptr close_failure;
  try {
    checked_close(output, path);
  } catch (...) {
    close_failure = std::current_exception();
  }
  try {
    checked_close(groups_output, groups_path);
  } catch (...) {
    if (!close_failure) close_failure = std::current_exception();
  }
  if (close_failure) std::rethrow_exception(close_failure);
}

// --debug-segments: the pre-slicing segmentation table — the
// classified, coalesced pieces in fraction space, keyed by canonical
// geometry string, fractions as %.17g exact-round-trip doubles. The
// independent checker re-executes the segmentation and compares this
// table for exact equality.
void write_debug_segments(
    const std::filesystem::path &path,
    const std::map<std::string, std::vector<MergePiece>> &segments,
    const std::vector<MergeRequirement> &requirements) {
  std::ofstream output(path, std::ios::binary);
  if (!output) {
    throw std::runtime_error("could not open output: " + path.string());
  }
  char buffer[64];
  for (const auto &[key, pieces] : segments) {
    for (const MergePiece &piece : pieces) {
      output << key << '\t';
      std::snprintf(buffer, sizeof buffer, "%.17g\t%.17g", piece.start,
                    piece.end);
      output << buffer << '\t' << attribute_json(piece.attr, requirements)
             << '\n';
    }
  }
  checked_close(output, path);
}

int merge_network_database_main(const std::vector<std::string> &args) {
  // args: OUT BOUNDS NORMALIZED_DB --groups-out FILE [--debug-segments FILE]
  if (args.size() != 5 && args.size() != 7)
    throw std::runtime_error(
        "usage: --merge-network-db OUT BOUNDS DB --groups-out FILE "
        "[--debug-segments FILE]");
  const std::filesystem::path out_path = args[0];
  const Bounds bounds = parse_bounds(args[1]);
  const std::filesystem::path database_path = args[2];
  if (args[3] != "--groups-out")
    throw std::runtime_error("merge-network-db requires --groups-out");
  const std::filesystem::path groups_path = args[4];
  std::filesystem::path debug_path;
  if (args.size() == 7) {
    if (args[5] != "--debug-segments")
      throw std::runtime_error("unexpected merge-network-db argument");
    debug_path = args[6];
  }
  std::vector<std::pair<std::string, std::filesystem::path>> identity_paths{
      {"network output", out_path},
      {"groups output", groups_path},
      {"relation database", database_path},
  };
  if (!debug_path.empty())
    identity_paths.push_back({"debug output", debug_path});
  require_distinct_paths(identity_paths);
  const auto load_started = std::chrono::steady_clock::now();
  MergeDatabase database(database_path);
  std::vector<MergeRequirement> requirements;
  load_merge_requirements(database.get(), requirements);
  const auto segment_started = std::chrono::steady_clock::now();
  std::map<std::string, std::vector<MergePiece>> segments;
  NetworkPieces network;
  size_t geometry_count = 0, piece_count = 0;
  // Geometry and relations deliberately use separate ordered cursors. The
  // compact geometry blob is fetched and decoded exactly once per edge while
  // its already-PK-ordered runs stream into one bounded MergeGroup.
  MergeQuery edges(database.get(),
      "SELECT edge_pk,delta_coords FROM edges ORDER BY edge_pk");
  MergeQuery rows(database.get(),
      // Exact breakpoint rows describe zero-length lookup overrides. They
      // cannot produce a rendered line interval, so the access-network merge
      // consumes only runs. Catalog packing merges runs and points.
      "SELECT edge_pk,requirement,minute,start,end FROM relation_runs "
      "ORDER BY edge_pk,requirement,minute,sequence");
  bool have_row = rows.next();
  while (edges.next()) {
    const int64_t edge_pk = edges.integer(0);
    if (have_row && rows.integer(0) < edge_pk)
      throw std::runtime_error("relation row references unknown edge");
    if (!have_row || rows.integer(0) != edge_pk) continue;
    Line line = delta_e7_line(edges.blob(1), edges.bytes(1));
    std::string key;
    for (const Point &point : line) key += point_key(point) + ';';
    std::string reverse;
    for (auto point = line.rbegin(); point != line.rend(); ++point)
      reverse += point_key(*point) + ';';
    if (reverse < key)
      throw std::runtime_error("non-canonical relation geometry");
    MergeGroup group{std::move(line),
        std::vector<std::map<int, std::vector<Interval>>>(requirements.size())};
    do {
      const int64_t requirement = rows.integer(1), minute = rows.integer(2);
      const double start = rows.number(3), end = rows.number(4);
      if (requirement < 0 ||
          requirement >= static_cast<int64_t>(requirements.size()) ||
          !std::isfinite(start) || !std::isfinite(end) || start < 0 ||
          start > end || end > 1)
        throw std::runtime_error("invalid classified relation row");
      const auto &minutes = requirements[requirement].minutes;
      if (!std::binary_search(minutes.begin(), minutes.end(), minute))
        throw std::runtime_error("relation row references unknown preset minute");
      group.requirements[requirement][minute].push_back({start, end});
      have_row = rows.next();
    } while (have_row && rows.integer(0) == edge_pk);
    for (auto &bands : group.requirements)
      for (auto &[minute, intervals] : bands) {
        static_cast<void>(minute);
        intervals = merge_intervals(std::move(intervals));
      }
    std::vector<MergePiece> pieces = segment_group(group, requirements);
    if (!pieces.empty()) {
      piece_count += pieces.size();
      slice_group(group.line, pieces, bounds, network);
      if (!debug_path.empty()) segments.emplace(key, std::move(pieces));
    }
    ++geometry_count;
  }
  if (have_row) throw std::runtime_error("relation row references unknown edge");
  if (geometry_count == 0)
    throw std::runtime_error("relation database has no edges");
  if (!debug_path.empty()) write_debug_segments(debug_path, segments, requirements);
  decltype(segments){}.swap(segments);
  const auto write_started = std::chrono::steady_clock::now();
  if (network.empty()) throw std::runtime_error("network is empty after bbox clipping");
  const std::filesystem::path network_temporary =
      temporary_sibling(out_path, "network");
  std::filesystem::path groups_temporary;
  try {
    groups_temporary = temporary_sibling(groups_path, "groups");
    write_network_collection(network_temporary, groups_temporary, network,
                             requirements, bounds);
    publish_output_pair(network_temporary, out_path, groups_temporary,
                        groups_path);
  } catch (...) {
    remove_owned_path(network_temporary);
    remove_owned_path(groups_temporary);
    throw;
  }
  const auto finished = std::chrono::steady_clock::now();
  const rusage usage = [] { rusage value{}; getrusage(RUSAGE_SELF, &value); return value; }();
  std::cerr << "[mapgames] merge-network-db: " << geometry_count
            << " merged geometries, " << piece_count << " fraction-space pieces, "
            << network.size() << " output pieces, peak-rss="
            << usage.ru_maxrss / 1024.0 << " MiB\n";
  std::cerr << "[mapgames] merge-network-db schema: "
            << std::chrono::duration<double>(segment_started - load_started).count()
            << "s, stream+segment+slice: "
            << std::chrono::duration<double>(write_started - segment_started).count()
            << "s, write: "
            << std::chrono::duration<double>(finished - write_started).count() << "s\n";
  return 0;
}

int self_test() {
  const std::filesystem::path test_directory =
      std::filesystem::temp_directory_path() /
      ("mapgames-valhalla-expand-self-test-" +
       std::to_string(std::chrono::steady_clock::now()
                          .time_since_epoch()
                          .count()));
  std::filesystem::create_directory(test_directory);
  try {
    auto read_file = [](const std::filesystem::path &path) {
      std::ifstream input(path, std::ios::binary);
      return std::string(std::istreambuf_iterator<char>(input),
                         std::istreambuf_iterator<char>());
    };
    const CanonicalLine canonical =
        canonical_line({{25.0, 55.0}, {25.1, 55.0}});
    auto canonical_geometry = std::make_shared<const CanonicalGeometry>(
        CanonicalGeometry{canonical.key, canonical.line});
    std::vector<Request> membership_requests{
        {"", "", "", 7, 0, 0, 10},
        {"", "", "", 3, 0, 0, 10},
        {"", "", "", 9, 0, 0, 10},
    };
    std::vector<DestinationEdges> membership_workers;
    membership_workers.emplace_back(2, membership_requests.size());
    membership_workers.emplace_back(2, membership_requests.size());
    auto [first_edge, first_inserted] =
        membership_workers[0].try_emplace(42, canonical_geometry);
    auto [second_edge, second_inserted] =
        membership_workers[1].try_emplace(42, canonical_geometry);
    if (!first_inserted || !second_inserted) {
      throw std::runtime_error("membership fixture edge insertion failed");
    }
    membership_workers[0].add_full(first_edge->second, 0, 1);
    first_edge->second.partials.push_back({{0.0, 0.5}, 0, 0});
    first_edge->second.partials.push_back({{0.5, 0.75}, 0, 0});
    second_edge->second.partials.push_back({{0.25, 0.5}, 0, 0});
    second_edge->second.partials.push_back({{0.125, 1.0}, 2, 1});
    const RelationBatch relation_batch =
        build_relation_batch(membership_workers, {5, 10}, membership_requests);
    if (relation_batch.edges.size() != 1 || relation_batch.sets.size() != 3 ||
        *relation_batch.sets[0] != std::vector<uint32_t>({3, 7}) ||
        *relation_batch.sets[1] != std::vector<uint32_t>({3}) ||
        *relation_batch.sets[2] != std::vector<uint32_t>({9}) ||
        relation_batch.edges[0].bands.size() != 2 ||
        relation_batch.edges[0].bands[0].runs.size() != 2 ||
        relation_batch.edges[0].bands[0].points.size() != 3 ||
        relation_batch.edges[0].bands[1].runs.size() != 1 ||
        relation_batch.edges[0].bands[1].points.size() != 2) {
      throw std::runtime_error("classified relation fixture failed");
    }
    const auto relation_path = test_directory / "relations.bin";
    {
      std::ofstream relation_output(relation_path, std::ios::binary);
      write_relation_header(relation_output, {5, 10});
      write_relation_batch(relation_output, relation_batch);
    }
    std::ostringstream repeated(std::ios::binary);
    write_relation_header(repeated, {5, 10});
    write_relation_batch(repeated, relation_batch);
    const std::string relations = read_file(relation_path);
    if (relations != repeated.str() ||
        relations.size() <= mapgames::relations::kMagic.size() ||
        !std::equal(mapgames::relations::kMagic.begin(),
                    mapgames::relations::kMagic.end(), relations.begin())) {
      throw std::runtime_error("binary relation handoff self-test failed");
    }

    NetworkPieces chunk_pieces;
    chunk_pieces.emplace(
        "a", NetworkPiece{Line{{-1.0, 0.01}, {0.01, 0.01}}, {5}});
    chunk_pieces.emplace(
        "b", NetworkPiece{Line{{0.01, 0.01}, {1.0, 0.01}}, {5}});
    Line reversed = chunk_pieces.at("a").line;
    std::reverse(reversed.begin(), reversed.end());
    if (network_chunk(chunk_pieces.at("a").line) != network_chunk(reversed) ||
        network_chunk(chunk_pieces.at("a").line) ==
            network_chunk(chunk_pieces.at("b").line)) {
      throw std::runtime_error("network spatial chunk self-test failed");
    }
    const auto chunk_network_path = test_directory / "chunk-network.json";
    const auto chunk_groups_path = test_directory / "chunk-groups.json";
    write_network_collection(
        chunk_network_path, chunk_groups_path, chunk_pieces,
        std::vector<MergeRequirement>{{"coffee_walk", {5}}},
        Bounds{-1.0, -1.0, 1.0, 1.0});
    const std::string expected_chunk_network =
        "{\"type\":\"FeatureCollection\",\"bbox\":[-1,-1,1,1],\"features\":["
        "{\"type\":\"Feature\",\"properties\":{\"coffee_walk\":5,\"g\":0},"
        "\"geometry\":{\"type\":\"MultiLineString\",\"coordinates\":["
        "[[-1,0.01],[0.01,0.01]]]}},"
        "{\"type\":\"Feature\",\"properties\":{\"coffee_walk\":5,\"g\":0},"
        "\"geometry\":{\"type\":\"MultiLineString\",\"coordinates\":["
        "[[0.01,0.01],[1,0.01]]]}}]}\n";
    const std::string expected_chunk_groups =
        "{\"schema_version\":1,\"group_count\":1,\"groups\":["
        "{\"coffee_walk\":5,\"g\":0}]}\n";
    if (read_file(chunk_network_path) != expected_chunk_network ||
        read_file(chunk_groups_path) != expected_chunk_groups) {
      throw std::runtime_error("network chunk serialization self-test failed");
    }
  } catch (...) {
    std::filesystem::remove_all(test_directory);
    throw;
  }
  std::filesystem::remove_all(test_directory);
  return 0;
}

void usage(const char *argv0) {
  std::cerr << "usage: " << argv0
            << " CONFIG REQUESTS_TSV OUT_DIR ROUTING_THREADS BATCH_SIZE"
               " MINUTES BOUNDS ROUTE_KEY SERVICE MODE\n"
            << "       " << argv0
            << " --merge-network-db OUT BOUNDS DB --groups-out FILE"
               " [--debug-segments FILE]\n";
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--self-test") {
    try {
      return self_test();
    } catch (const std::exception &error) {
      std::cerr << "valhalla-expand self-test: " << error.what() << '\n';
      return 1;
    }
  }
  if (argc >= 2 && std::string(argv[1]) == "--merge-network-db") {
    try {
      return merge_network_database_main(
          std::vector<std::string>(argv + 2, argv + argc));
    } catch (const std::exception &error) {
      std::cerr << "valhalla-expand: " << error.what() << '\n';
      return 1;
    }
  }
  if (argc >= 2 && std::string(argv[1]) == "--finalize-relations") {
    return destination_lookup_main(
        std::vector<std::string>(argv + 2, argv + argc));
  }
  if (argc != 11) {
    usage(argv[0]);
    return 2;
  }

  try {
    const std::string config_path = argv[1];
    const std::filesystem::path requests_path = argv[2];
    // Native relation batches land here (the caller's work directory; the
    // handoff is not published).
    const std::filesystem::path out_dir = argv[3];
    const size_t requested_threads = std::stoul(argv[4]);
    const size_t batch_size = std::stoul(argv[5]);
    const std::vector<int> minutes = parse_minutes(argv[6]);
    const Bounds bounds = parse_bounds(argv[7]);
    const std::string route_key = argv[8];
    const std::string service = argv[9];
    const std::string mode = argv[10];
    if (requested_threads == 0) {
      throw std::runtime_error("routing threads must be positive");
    }
    if (batch_size == 0) {
      throw std::runtime_error("routing batch size must be positive");
    }

    const std::vector<Request> requests = read_requests(requests_path);
    if (requests.size() > UINT32_MAX || minutes.size() > UINT32_MAX) {
      throw std::runtime_error(
          "too many requests or minute thresholds for compact relations");
    }
    if (std::any_of(requests.begin(), requests.end(),
                    [&](const Request &request) {
                      return request.minutes != minutes.back();
                    })) {
      throw std::runtime_error(
          "request maximum does not match minute thresholds");
    }
    if (std::any_of(requests.begin(), requests.end(),
                    [&](const Request &request) {
                      return request.costing != requests.front().costing;
                    })) {
      throw std::runtime_error("all requests must use the same costing");
    }

    const auto &config = valhalla::config(config_path);
    const size_t max_worker_count =
        std::min({requested_threads, batch_size, requests.size()});
    // Each worker constructs its own GraphReader, and Valhalla's default
    // mjolnir.max_cache_size is 1 GiB per reader, so N workers could hold
    // N GiB of tile cache. Cap it here (not in generate.py's valhalla.json,
    // which valhalla_build_tiles also consumes): 4 GiB split across workers
    // with a 256 MiB floor. Workers read this copy; the shared config used
    // by actor_t stays unmodified. Caching affects only speed, never
    // results.
    auto mjolnir = config.get_child("mjolnir");
    const uint64_t max_cache_size =
        std::max<uint64_t>(256ull << 20, (4096ull << 20) / max_worker_count);
    mjolnir.put("max_cache_size", max_cache_size);
    std::cerr << "[mapgames] native expansion GraphReader cache cap: "
              << max_cache_size << " bytes per worker\n";
    std::filesystem::create_directories(out_dir);
    const auto routing_started = std::chrono::steady_clock::now();
    const auto relation_path = out_dir / ("relations-" + route_key + ".bin");
    std::ofstream relation_output(relation_path, std::ios::binary);
    if (!relation_output) {
      throw std::runtime_error("could not open output: " +
                               relation_path.string());
    }
    write_relation_header(relation_output, minutes);
    size_t completed = 0;
    size_t batch_number = 0;
    // Civil-protection shelters are a pinned external POI snapshot, not OSM
    // features matched onto the road graph, so a few sit beyond the 100 m snap
    // radius of any routable edge (islands, courtyards, digitised-off points).
    // For that service alone, skip such origins -- recording their request ids
    // so the caller can keep them as unrouted POIs -- instead of failing the
    // whole build. Every other service still fails loudly, so a genuine data or
    // routing-graph regression is never silently dropped.
    const bool allow_unroutable = service == "shelter";
    std::vector<std::string> unrouted_ids;
    std::mutex unrouted_mutex;
    for (size_t batch_start = 0; batch_start < requests.size();
         batch_start += batch_size) {
      const size_t batch_end = std::min(requests.size(), batch_start + batch_size);
      const std::vector<Request> batch_requests(requests.begin() + batch_start,
                                                requests.begin() + batch_end);
      // Skips recorded during this batch, so progress logs count only routed
      // origins (unrouted_ids only grows and workers are joined before use).
      const size_t unrouted_before_batch = unrouted_ids.size();
      const size_t worker_count =
          std::min(requested_threads, batch_requests.size());
      std::vector<DestinationEdges> worker_destinations;
      worker_destinations.reserve(worker_count);
      for (size_t worker_index = 0; worker_index < worker_count; ++worker_index) {
        worker_destinations.emplace_back(minutes.size(), batch_requests.size());
      }
      std::atomic_size_t next_request{0};
      std::atomic_bool failed{false};
      std::exception_ptr first_error;
      std::mutex error_mutex;
      std::mutex log_mutex;
      auto worker = [&](size_t worker_index) {
        try {
          valhalla::baldr::GraphReader graph_reader(mjolnir);
          valhalla::tyr::actor_t actor(config, graph_reader, true);
          valhalla::sif::cost_ptr_t costing;
          EdgeCache edge_cache;
          while (!failed.load(std::memory_order_acquire)) {
            const size_t request_index = next_request.fetch_add(1);
            if (request_index >= batch_requests.size()) {
              break;
            }
            const Request &request = batch_requests[request_index];
            try {
              valhalla::Api validation_api;
              static_cast<void>(actor.isochrone(
                  validation_request_json(request), nullptr, &validation_api));
              if (costing == nullptr) {
                costing = valhalla::sif::CostFactory{}.Create(
                    validation_api.options());
              }
              valhalla::Api expansion_api;
              static_cast<void>(actor.expansion(request_json(request), nullptr,
                                                &expansion_api));
              if (!expansion_api.has_expansion()) {
                throw std::runtime_error(
                    "Valhalla returned no expansion protobuf");
              }
              const valhalla::Expansion &expansion = expansion_api.expansion();
              const ExpansionEdgeIndex edges = index_expansion_edges(expansion);
              std::vector<bool> destination_found(minutes.size(), false);
              for (const ExpansionEdgeRef &edge_reference : edges) {
                const Edge edge = expansion_edge(expansion, edge_reference);
                const double start_seconds =
                    predecessor_duration(edge, expansion, edges);
                EdgeCacheEntry &cache_entry =
                    edge_cache_entry(edge, graph_reader, edge_cache);
                const double traversal_seconds =
                    edge.pred_id == kInvalidGraphId
                        ? 0.0
                        : reverse_edge_traversal_seconds(
                              edge, cache_entry, graph_reader, costing);
                for (size_t minute_index = 0; minute_index < minutes.size();
                     ++minute_index) {
                  const std::optional<Interval> interval = reachable_interval(
                      edge, start_seconds,
                      minutes[minute_index] * 60.0,
                      traversal_seconds);
                  if (interval) {
                    const bool added = add_destination_interval(
                        worker_destinations[worker_index], cache_entry,
                        *interval, request_index, minute_index);
                    if (added && !destination_found[minute_index] &&
                        interval_intersects_bounds(edge.line, *interval,
                                                   bounds)) {
                      destination_found[minute_index] = true;
                    }
                  }
                }
              }
              for (size_t minute_index = 0; minute_index < minutes.size();
                   ++minute_index) {
                if (!destination_found[minute_index]) {
                  throw std::runtime_error(
                      "no reachable lines for " +
                      std::to_string(minutes[minute_index]) + " minutes");
                }
              }
            } catch (const std::exception &error) {
              {
                std::lock_guard<std::mutex> lock(log_mutex);
                std::cerr << "valhalla-expand: request " << request.id << " ("
                          << request.feature_id << ") "
                          << (allow_unroutable ? "skipped (unroutable): "
                                               : "failed: ")
                          << error.what() << '\n';
              }
              if (!allow_unroutable) {
                throw;
              }
              // A shelter origin that will not snap or cannot reach any line is
              // dropped from routing but kept for the caller as an unrouted POI.
              std::lock_guard<std::mutex> lock(unrouted_mutex);
              unrouted_ids.push_back(request.id);
            }
          }
        } catch (...) {
          failed.store(true, std::memory_order_release);
          std::lock_guard<std::mutex> lock(error_mutex);
          if (first_error == nullptr) {
            first_error = std::current_exception();
          }
        }
      };
      std::vector<std::jthread> workers;
      workers.reserve(worker_count);
      for (size_t worker_index = 0; worker_index < worker_count;
           ++worker_index) {
        workers.emplace_back(worker, worker_index);
      }
      for (auto &thread : workers) {
        thread.join();
      }
      if (first_error != nullptr) {
        std::rethrow_exception(first_error);
      }
      validate_destination_geometry(worker_destinations);
      if (std::all_of(worker_destinations.begin(), worker_destinations.end(),
                      [](const DestinationEdges &edges) {
                        return edges.empty();
                      })) {
        if (allow_unroutable) {
          // Every origin in this batch was unroutable; skip it rather than
          // emitting an empty relation batch or failing the build.
          continue;
        }
        throw std::runtime_error("relation batch is empty");
      }
      const RelationBatch relation_batch = build_relation_batch(
          worker_destinations, minutes, batch_requests);
      write_relation_batch(relation_output, relation_batch);
      if (!relation_output) {
        throw std::runtime_error("could not append output: " +
                                 relation_path.string());
      }
      completed += batch_requests.size() -
                   (unrouted_ids.size() - unrouted_before_batch);
      ++batch_number;
      const size_t resident_edge_rows =
          std::accumulate(worker_destinations.begin(),
                          worker_destinations.end(), size_t{0},
                          [](size_t count, const DestinationEdges &edges) {
                            return count + edges.size();
                          });
      std::cerr << "[mapgames] native relation batch " << batch_number
                << ": origins " << batch_start << '-' << (batch_end - 1)
                << ", " << resident_edge_rows << " worker edge rows, "
                << relation_batch.sets.size() << " local sets, "
                << relation_batch.edges.size() << " classified edges, "
                << completed << '/' << requests.size() << " routed\n";
    }
    relation_output.close();
    if (!relation_output) {
      throw std::runtime_error("could not close output: " +
                               relation_path.string());
    }
    if (allow_unroutable) {
      // Always emit the skip list (empty when every shelter routed) so the
      // caller can distinguish "carve-out ran, none skipped" from a crash.
      std::sort(unrouted_ids.begin(), unrouted_ids.end());
      const auto unrouted_path = out_dir / ("unrouted-" + route_key + ".tsv");
      std::ofstream unrouted_output(unrouted_path, std::ios::binary);
      if (!unrouted_output) {
        throw std::runtime_error("could not open unrouted output: " +
                                 unrouted_path.string());
      }
      for (const std::string &id : unrouted_ids) {
        unrouted_output << id << '\n';
      }
      unrouted_output.close();
      if (!unrouted_output) {
        throw std::runtime_error("could not write unrouted output: " +
                                 unrouted_path.string());
      }
      std::cerr << "[mapgames] native expansion " << route_key << ": "
                << unrouted_ids.size() << " unroutable " << service
                << " origin(s) skipped\n";
    }
    const auto routing_finished = std::chrono::steady_clock::now();

    std::cerr << "[mapgames] native batched routing+relation output: "
              << std::chrono::duration<double>(routing_finished -
                                               routing_started)
                     .count()
              << "s\n";
    std::cerr << "[mapgames] native expansion+lines: "
              << (requests.size() - unrouted_ids.size())
              << " routed in " << batch_number << " batch(es), at most "
              << batch_size << " origins and " << max_worker_count
              << " routing worker(s) resident\n";
  } catch (const std::exception &error) {
    std::cerr << "valhalla-expand: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
