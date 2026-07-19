#include <valhalla/baldr/graphreader.h>
#include <valhalla/config.h>
#include <valhalla/sif/costfactory.h>
#include <valhalla/tyr/actor.h>

#include <rapidjson/document.h>
#include <rapidjson/internal/dtoa.h>

#include <boost/property_tree/ptree.hpp>

#include <algorithm>
#include <atomic>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

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

struct DestinationLine {
  Line line;
  std::vector<uint32_t> lookup_ids;
};

using DestinationLines = std::map<std::string, DestinationLine>;

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
  // Expansion GeoJSON is written through RapidJSON with at most six decimal
  // places. Preserve that historical double exactly while avoiding the huge
  // GeoJSON string and DOM: direct coordinate / 1e6 can differ by one
  // microdegree when its binary approximation lies below the decimal value.
  char buffer[32];
  char *end = rapidjson::internal::dtoa(coordinate / 1e6, buffer, 6);
  double result = 0;
  const auto [parsed_end, error] = std::from_chars(buffer, end, result);
  if (error != std::errc{} || parsed_end != end) {
    throw std::runtime_error("could not decode expansion coordinate");
  }
  return result;
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

void normalize_lookup_ids(DestinationLines &lines) {
  for (auto &[key, line] : lines) {
    static_cast<void>(key);
    std::sort(line.lookup_ids.begin(), line.lookup_ids.end());
    line.lookup_ids.erase(
        std::unique(line.lookup_ids.begin(), line.lookup_ids.end()),
        line.lookup_ids.end());
  }
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

DestinationLine &add_destination_line(DestinationLines &result,
                                      CanonicalLine canonical) {
  auto [entry, inserted] = result.try_emplace(
      std::move(canonical.key), DestinationLine{std::move(canonical.line), {}});
  static_cast<void>(inserted);
  return entry->second;
}

DestinationLines
destination_lines(const std::vector<DestinationEdges> &worker_destinations,
                  size_t minute_index, const std::vector<Request> &requests,
                  const Bounds &bounds) {
  DestinationLines result;
  for_each_destination_edge_group(
      worker_destinations,
      [&](uint64_t canonical_id, const DestinationEdgeGroup &group) {
        static_cast<void>(canonical_id);
        const Line &line = group.front().edge->canonical->line;
        const LineMeasure measure = measure_line(line);

        // Every full membership produces the same clipped geometry. Slice and
        // canonicalize it once across all workers, then enumerate their compact
        // membership rows.
        const bool full =
            std::any_of(group.begin(), group.end(), [&](const auto &reference) {
              return reference.edges->has_full(*reference.edge, minute_index);
            });
        if (full) {
          const Line reachable = slice_line(line, measure, 0.0, 1.0);
          for (const Line &clipped : clip_line(reachable, bounds)) {
            CanonicalLine canonical = canonical_line(clipped);
            if (canonical.line.empty()) {
              continue;
            }
            DestinationLine &destination =
                add_destination_line(result, std::move(canonical));
            for (const DestinationEdgeRef &reference : group) {
              reference.edges->for_each_full(
                  *reference.edge, minute_index, [&](size_t request_index) {
                    destination.lookup_ids.push_back(
                        requests[request_index].lookup_id);
                  });
            }
          }
        }

        // Fractional contour-frontier records retain their exact doubles and
        // are materialized individually, matching the old path.
        for (const DestinationEdgeRef &reference : group) {
          for (const DestinationInterval &partial : reference.edge->partials) {
            if (partial.minute_index != minute_index) {
              continue;
            }
            const Line reachable = slice_line(
                line, measure, partial.interval.start, partial.interval.end);
            for (const Line &clipped : clip_line(reachable, bounds)) {
              CanonicalLine canonical = canonical_line(clipped);
              if (canonical.line.empty()) {
                continue;
              }
              add_destination_line(result, std::move(canonical))
                  .lookup_ids.push_back(
                      requests[partial.request_index].lookup_id);
            }
          }
        }
      });
  normalize_lookup_ids(result);
  return result;
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

void collect_dump_bands(const DestinationEdgeGroup &group, size_t minute_count,
                        std::vector<std::vector<Interval>> &bands) {
  if (bands.size() != minute_count) {
    bands.resize(minute_count);
  }
  for (size_t minute_index = 0; minute_index < minute_count; ++minute_index) {
    std::vector<Interval> &band = bands[minute_index];
    band.clear();
    const bool full =
        std::any_of(group.begin(), group.end(), [&](const auto &reference) {
          return reference.edges->has_full(*reference.edge, minute_index);
        });
    if (full) {
      band.push_back({0.0, 1.0});
      continue;
    }
    for (const DestinationEdgeRef &reference : group) {
      for (const DestinationInterval &partial : reference.edge->partials) {
        if (partial.minute_index == minute_index) {
          band.push_back(partial.interval);
        }
      }
    }
    band = merge_intervals(std::move(band));
  }
}

// Dump consumers re-derive band membership from the intervals alone, so
// enforce the band-nesting invariant per uint64 entry at dump time with the
// same midpoint classification the merge tool's segment_group() applies to
// the string-merged geometry groups.
void verify_dump_nesting(
    const std::vector<DestinationEdges> &worker_destinations,
    size_t minute_count) {
  std::vector<std::vector<Interval>> bands(minute_count);
  for_each_destination_edge_group(
      worker_destinations,
      [&](uint64_t canonical_id, const DestinationEdgeGroup &group) {
        collect_dump_bands(group, minute_count, bands);
        std::vector<double> endpoints;
        for (const std::vector<Interval> &band : bands) {
          for (const Interval &interval : band) {
            endpoints.push_back(interval.start);
            endpoints.push_back(interval.end);
          }
        }
        std::sort(endpoints.begin(), endpoints.end());
        endpoints.erase(std::unique(endpoints.begin(), endpoints.end(),
                                    [](double left, double right) {
                                      return std::abs(left - right) <= 1e-12;
                                    }),
                        endpoints.end());
        for (size_t endpoint_index = 1; endpoint_index < endpoints.size();
             ++endpoint_index) {
          const double start = endpoints[endpoint_index - 1];
          const double end = endpoints[endpoint_index];
          if (end - start <= 1e-12) {
            continue;
          }
          const double midpoint = (start + end) / 2.0;
          bool found = false;
          for (const std::vector<Interval> &band : bands) {
            const bool present = contains(band, midpoint);
            if (present && !found) {
              found = true;
            } else if (!present && found) {
              throw std::runtime_error(
                  "dump edge " + std::to_string(canonical_id) +
                  ": reachable edge intervals are not nested by minute "
                  "threshold");
            }
          }
        }
      });
}

// Edge-interval dump: one line per canonical edge, ascending numeric uint64
// key order (std::map iteration; matches the merge tool's uint64 k-way merge
// comparator, NOT decimal-string order), ASCII, deterministic:
//   <key_u64>\t<lon,lat;...>\t<minutes>:<start>-<end>[,...][|<minutes>:...]
// Geometry is the stored string-canonical orientation, %.7f fixed format
// (exact for 1e-7-rounded values). Fractions print as %.17g so they
// round-trip to the identical double. Bands left empty by merge_intervals()
// are omitted; entries whose bands are all empty are skipped entirely (they
// contribute nothing to any consumer).
void write_edge_dump(const std::filesystem::path &path,
                     const std::vector<DestinationEdges> &worker_destinations,
                     const std::vector<int> &minutes) {
  std::ofstream output(path, std::ios::binary);
  if (!output) {
    throw std::runtime_error("could not open output: " + path.string());
  }
  char buffer[64];
  std::vector<std::vector<Interval>> bands(minutes.size());
  for_each_destination_edge_group(
      worker_destinations,
      [&](uint64_t canonical_id, const DestinationEdgeGroup &group) {
        collect_dump_bands(group, minutes.size(), bands);
        if (std::all_of(bands.begin(), bands.end(),
                        [](const std::vector<Interval> &band) {
                          return band.empty();
                        })) {
          return;
        }
        const Line &line = group.front().edge->canonical->line;
        output << canonical_id << '\t';
        for (size_t index = 0; index < line.size(); ++index) {
          if (index != 0) {
            output << ';';
          }
          std::snprintf(buffer, sizeof buffer, "%.7f,%.7f", line[index].lon,
                        line[index].lat);
          output << buffer;
        }
        output << '\t';
        bool first_band = true;
        for (size_t minute_index = 0; minute_index < minutes.size();
             ++minute_index) {
          const std::vector<Interval> &band = bands[minute_index];
          if (band.empty()) {
            continue;
          }
          if (!first_band) {
            output << '|';
          }
          first_band = false;
          output << minutes[minute_index] << ':';
          for (size_t index = 0; index < band.size(); ++index) {
            if (index != 0) {
              output << ',';
            }
            std::snprintf(buffer, sizeof buffer, "%.17g-%.17g",
                          band[index].start, band[index].end);
            output << buffer;
          }
        }
        output << '\n';
      });
  if (!output) {
    throw std::runtime_error("could not write output: " + path.string());
  }
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

using LineRefs = std::vector<const Line *>;

void write_multiline(std::ostream &output, const LineRefs &lines) {
  output << "{\"type\":\"MultiLineString\",\"coordinates\":[";
  bool first = true;
  for (const Line *line : lines) {
    if (!first) {
      output << ',';
    }
    first = false;
    write_line(output, *line);
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

std::string lookup_ids_json(const std::vector<uint32_t> &lookup_ids) {
  std::ostringstream output;
  output << '[';
  bool first = true;
  for (const uint32_t lookup_id : lookup_ids) {
    if (!first) {
      output << ',';
    }
    first = false;
    output << lookup_id;
  }
  output << ']';
  return output.str();
}

void write_destination_collection(const std::filesystem::path &path,
                                  const DestinationLines &lines,
                                  const std::string &service,
                                  const std::string &mode, int minutes,
                                  const Bounds &bounds) {
  std::ofstream output(path, std::ios::binary);
  if (!output) {
    throw std::runtime_error("could not open output: " + path.string());
  }
  // Group by references: DestinationLines already owns every geometry until
  // this writer returns, so copying all lines into a second country-wide map
  // only raises the output-phase peak.
  std::map<std::string, LineRefs> groups;
  for (const auto &[key, destination_line] : lines) {
    static_cast<void>(key);
    groups[lookup_ids_json(destination_line.lookup_ids)].push_back(
        &destination_line.line);
  }
  output << "{\"type\":\"FeatureCollection\",\"bbox\":" << bbox_json(bounds)
         << ",\"features\":[";
  bool first = true;
  for (const auto &[lookup_ids, grouped_lines] : groups) {
    if (!first) {
      output << ',';
    }
    first = false;
    output << "{\"type\":\"Feature\",\"properties\":{\"minutes\":" << minutes
           << ",\"mode\":" << json_string(mode)
           << ",\"lookup_ids\":" << json_string(lookup_ids)
           << ",\"service\":" << json_string(service) << "},\"geometry\":";
    write_multiline(output, grouped_lines);
    output << '}';
  }
  output << "]}\n";
  if (!output) {
    throw std::runtime_error("could not write output: " + path.string());
  }
}

// ---------------------------------------------------------------------------
// Merge tool (docs/unified-access-layer.md):
// consumes the per-route edge-interval dumps and writes one edge-attributed
// network.geojson. Single-threaded k-way merge over the numerically-sorted
// dumps on the input side; whole-network resident by design — the
// geometry-string groups, the output canonical-string map, and the
// attribute-map feature grouping all live in RAM before the first byte is
// written. Peak RSS must remain below the 8 GB spill threshold when this
// implementation is profiled.

// One requirement = one dump = one attribute key {service}_{mode}, derived
// from the dump filename edges-<service>-<mode>.tsv. `minutes` is the
// ascending union of band labels seen in the dump (per-edge lines omit empty
// bands; classification treats a missing band as empty and the nesting abort
// catches inconsistent data).
struct MergeRequirement {
  std::string key;
  std::filesystem::path dump_path;
  std::vector<int> minutes;
};

// Per canonical-geometry-string group: the per-requirement,
// per-band-minute concatenated (then merged) interval lists of every dump
// entry sharing this geometry.
struct MergeGroup {
  Line line;
  std::vector<std::map<int, std::vector<Interval>>> requirements;
};

using MergeGroups = std::map<std::string, MergeGroup>;

// A classified, coalesced, not-yet-sliced piece. attr is
// indexed like the requirement list; -1 = requirement absent (unreachable).
struct MergePiece {
  double start;
  double end;
  std::vector<int> attr;
};

struct MergeDumpRecord {
  uint64_t id;
  std::string geometry_text;
  Line line;
  std::vector<std::pair<int, std::vector<Interval>>> bands;
};

double parse_double(const char *&cursor, const std::string &context) {
  char *end = nullptr;
  const double value = std::strtod(cursor, &end);
  if (end == cursor) {
    throw std::runtime_error("bad number in " + context);
  }
  cursor = end;
  return value;
}

class DumpReader {
public:
  explicit DumpReader(const std::filesystem::path &path)
      : path_(path.string()), file_(path) {
    if (!file_) {
      throw std::runtime_error("could not open dump: " + path_);
    }
  }

  // Parses the next record, enforcing the ascending numeric uint64 key order
  // the dump format guarantees (the k-way merge comparator relies on it).
  bool next(MergeDumpRecord &record) {
    std::string line;
    if (!std::getline(file_, line)) {
      if (!file_.eof()) {
        throw std::runtime_error("could not read dump: " + path_);
      }
      return false;
    }
    ++line_number_;
    const std::string context = path_ + ":" + std::to_string(line_number_);
    const auto fields = split(line, '\t');
    if (fields.size() != 3) {
      throw std::runtime_error(context + ": expected 3 TSV fields");
    }
    if (fields[0].empty() ||
        fields[0].find_first_not_of("0123456789") != std::string::npos) {
      throw std::runtime_error(context + ": bad uint64 key");
    }
    record.id = std::stoull(fields[0]);
    if (have_previous_ && record.id <= previous_id_) {
      throw std::runtime_error(context +
                               ": dump keys not in ascending uint64 order");
    }
    previous_id_ = record.id;
    have_previous_ = true;
    record.geometry_text = fields[1];
    record.line.clear();
    const char *cursor = fields[1].c_str();
    while (true) {
      const double lon = parse_double(cursor, context);
      if (*cursor != ',') {
        throw std::runtime_error(context + ": bad geometry");
      }
      ++cursor;
      const double lat = parse_double(cursor, context);
      record.line.push_back({lon, lat});
      if (*cursor == '\0') {
        break;
      }
      if (*cursor != ';') {
        throw std::runtime_error(context + ": bad geometry");
      }
      ++cursor;
    }
    if (record.line.size() < 2) {
      throw std::runtime_error(context + ": degenerate geometry");
    }
    record.bands.clear();
    for (const std::string &band_text : split(fields[2], '|')) {
      const size_t colon = band_text.find(':');
      if (colon == std::string::npos) {
        throw std::runtime_error(context + ": bad band");
      }
      const int minute = std::stoi(band_text.substr(0, colon));
      if (minute <= 0 ||
          (!record.bands.empty() && minute <= record.bands.back().first)) {
        throw std::runtime_error(context +
                                 ": band minutes not ascending and positive");
      }
      std::vector<Interval> intervals;
      cursor = band_text.c_str() + colon + 1;
      while (true) {
        Interval interval{};
        interval.start = parse_double(cursor, context);
        if (*cursor != '-') {
          throw std::runtime_error(context + ": bad interval");
        }
        ++cursor;
        interval.end = parse_double(cursor, context);
        intervals.push_back(interval);
        if (*cursor == '\0') {
          break;
        }
        if (*cursor != ',') {
          throw std::runtime_error(context + ": bad interval list");
        }
        ++cursor;
      }
      record.bands.emplace_back(minute, std::move(intervals));
    }
    if (record.bands.empty()) {
      throw std::runtime_error(context + ": entry with no bands");
    }
    return true;
  }

private:
  std::string path_;
  std::ifstream file_;
  size_t line_number_ = 0;
  uint64_t previous_id_ = 0;
  bool have_previous_ = false;
};

// Grammar shared with check-network-segments.py's _DUMP_NAME_RE and the
// authoritative-key assertion in generate.py: edges-<service>-<mode>.tsv with
// service and mode non-empty lowercase [a-z] runs. Keep the three in lockstep.
std::string requirement_key_from_dump(const std::filesystem::path &path) {
  const std::string name = path.filename().string();
  const std::string prefix = "edges-";
  const std::string suffix = ".tsv";
  if (name.size() <= prefix.size() + suffix.size() ||
      name.compare(0, prefix.size(), prefix) != 0 ||
      name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) {
    throw std::runtime_error(
        "dump filename must be edges-<service>-<mode>.tsv: " + name);
  }
  std::string key =
      name.substr(prefix.size(), name.size() - prefix.size() - suffix.size());
  const size_t dash = key.find('-');
  const bool one_dash =
      dash != std::string::npos && key.find('-', dash + 1) == std::string::npos;
  const bool lowercase_runs =
      dash != 0 && dash + 1 != key.size() &&
      std::all_of(key.begin(), key.end(), [](char character) {
        return character == '-' || (character >= 'a' && character <= 'z');
      });
  if (!one_dash || !lowercase_runs) {
    throw std::runtime_error(
        "dump filename must be edges-<service>-<mode>.tsv: " + name);
  }
  key[dash] = '_';
  return key;
}

// K-way merge the dumps by ascending uint64 key (asserting
// identical geometry text when the same key appears in several dumps), then
// group every entry by its canonical geometry string — a dual-digitized
// group's uint64 representative can differ per route, so the string is the
// only cross-route join key — concatenating the per-band interval lists.
MergeGroups load_merge_groups(std::vector<MergeRequirement> &requirements) {
  MergeGroups groups;
  std::vector<DumpReader> readers;
  readers.reserve(requirements.size());
  for (const MergeRequirement &requirement : requirements) {
    readers.emplace_back(requirement.dump_path);
  }
  std::vector<std::set<int>> minute_sets(requirements.size());
  std::vector<MergeDumpRecord> heads(requirements.size());
  std::vector<bool> live(requirements.size(), false);
  for (size_t index = 0; index < readers.size(); ++index) {
    live[index] = readers[index].next(heads[index]);
  }
  uint64_t current_id = 0;
  std::string current_geometry;
  bool have_current = false;
  while (true) {
    size_t best = requirements.size();
    for (size_t index = 0; index < readers.size(); ++index) {
      if (live[index] &&
          (best == requirements.size() || heads[index].id < heads[best].id)) {
        best = index;
      }
    }
    if (best == requirements.size()) {
      break;
    }
    MergeDumpRecord &record = heads[best];
    // Same key in several dumps must carry identical geometry;
    // equal-id records are adjacent in the k-way merge order.
    if (have_current && record.id == current_id &&
        record.geometry_text != current_geometry) {
      throw std::runtime_error("canonical edge " + std::to_string(record.id) +
                               " has inconsistent geometry across dumps");
    }
    std::string forward;
    for (const Point &point : record.line) {
      forward += point_key(point) + ";";
    }
    {
      std::string reverse;
      for (auto point = record.line.rbegin(); point != record.line.rend();
           ++point) {
        reverse += point_key(*point) + ";";
      }
      if (reverse < forward) {
        throw std::runtime_error(
            "dump geometry is not in canonical orientation for edge " +
            std::to_string(record.id));
      }
    }
    auto [group, inserted] = groups.try_emplace(
        std::move(forward),
        MergeGroup{record.line, std::vector<std::map<int, std::vector<Interval>>>(
                                    requirements.size())});
    if (!inserted && !lines_equal(group->second.line, record.line)) {
      throw std::runtime_error("dump entries with equal canonical keys "
                               "disagree on geometry");
    }
    std::map<int, std::vector<Interval>> &bands =
        group->second.requirements[best];
    for (auto &[minute, intervals] : record.bands) {
      minute_sets[best].insert(minute);
      std::vector<Interval> &band = bands[minute];
      band.insert(band.end(), intervals.begin(), intervals.end());
    }
    current_id = record.id;
    current_geometry = std::move(record.geometry_text);
    have_current = true;
    live[best] = readers[best].next(record);
  }
  for (size_t index = 0; index < requirements.size(); ++index) {
    requirements[index].minutes.assign(minute_sets[index].begin(),
                                       minute_sets[index].end());
    if (requirements[index].minutes.empty()) {
      throw std::runtime_error("dump has no bands: " +
                               requirements[index].dump_path.string());
    }
  }
  for (auto &[key, group] : groups) {
    static_cast<void>(key);
    for (std::map<int, std::vector<Interval>> &bands : group.requirements) {
      for (auto &[minute, band] : bands) {
        static_cast<void>(minute);
        band = merge_intervals(std::move(band));
      }
    }
  }
  return groups;
}

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

// Group pieces by serialized attribute map, one Feature per
// group, MultiLineString members in canonical-key order, features in
// serialized-attribute-map order. Each feature additionally carries `g` =
// its index in emission order (0..N-1 in file order) — the group id of the
// low-zoom fast-path (docs/lowzoom-fastpath.md): the single
// source of truth that coarsen.py carries through and that the browser
// metadata `groups` list is derived from. `g` is a per-build index; it must
// never be persisted client-side across deploys.
void write_network_collection(const std::filesystem::path &path,
                              const NetworkPieces &pieces,
                              const std::vector<MergeRequirement> &requirements,
                              const Bounds &bounds) {
  std::ofstream output(path, std::ios::binary);
  if (!output) {
    throw std::runtime_error("could not open output: " + path.string());
  }
  std::map<std::string, Lines> groups;
  for (const auto &[key, piece] : pieces) {
    groups[attribute_json(piece.attr, requirements)].emplace(key, piece.line);
  }
  output << "{\"type\":\"FeatureCollection\",\"bbox\":" << bbox_json(bounds)
         << ",\"features\":[";
  bool first = true;
  size_t group_index = 0;
  for (const auto &[attributes, grouped_lines] : groups) {
    if (!first) {
      output << ',';
    }
    first = false;
    // Splice "g" into the serialized attribute map: {...attrs...,"g":N}.
    // Empty attribute maps are skipped at segmentation time, so the map
    // always has at least one key; assert rather than special-case.
    if (attributes.size() < 3 || attributes.back() != '}') {
      throw std::runtime_error("unexpected empty attribute map for group " +
                               std::to_string(group_index));
    }
    output << "{\"type\":\"Feature\",\"properties\":"
           << attributes.substr(0, attributes.size() - 1) << ",\"g\":"
           << group_index << "},\"geometry\":";
    ++group_index;
    write_multiline(output, grouped_lines);
    output << '}';
  }
  output << "]}\n";
  if (!output) {
    throw std::runtime_error("could not write output: " + path.string());
  }
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
  if (!output) {
    throw std::runtime_error("could not write output: " + path.string());
  }
}

int merge_network_main(const std::vector<std::string> &args) {
  // args: OUT BOUNDS DUMP... [--debug-segments FILE]
  if (args.size() < 3) {
    throw std::runtime_error(
        "usage: --merge-network OUT BOUNDS DUMP... [--debug-segments FILE]");
  }
  const std::filesystem::path out_path = args[0];
  const Bounds bounds = parse_bounds(args[1]);
  std::filesystem::path debug_path;
  std::vector<MergeRequirement> requirements;
  for (size_t index = 2; index < args.size(); ++index) {
    if (args[index] == "--debug-segments") {
      if (index + 1 >= args.size() || !debug_path.empty()) {
        throw std::runtime_error("--debug-segments requires one FILE");
      }
      debug_path = args[index + 1];
      ++index;
      continue;
    }
    requirements.push_back({requirement_key_from_dump(args[index]),
                            std::filesystem::path(args[index]),
                            {}});
  }
  if (requirements.empty()) {
    throw std::runtime_error("no dumps given");
  }
  std::sort(requirements.begin(), requirements.end(),
            [](const MergeRequirement &left, const MergeRequirement &right) {
              return left.key < right.key;
            });
  for (size_t index = 1; index < requirements.size(); ++index) {
    if (requirements[index].key == requirements[index - 1].key) {
      throw std::runtime_error("duplicate requirement key: " +
                               requirements[index].key);
    }
  }

  const auto load_started = std::chrono::steady_clock::now();
  MergeGroups groups = load_merge_groups(requirements);
  const auto segment_started = std::chrono::steady_clock::now();
  std::map<std::string, std::vector<MergePiece>> segments;
  size_t piece_count = 0;
  for (const auto &[key, group] : groups) {
    std::vector<MergePiece> pieces = segment_group(group, requirements);
    if (!pieces.empty()) {
      piece_count += pieces.size();
      segments.emplace(key, std::move(pieces));
    }
  }
  if (!debug_path.empty()) {
    write_debug_segments(debug_path, segments, requirements);
  }
  const auto slice_started = std::chrono::steady_clock::now();
  NetworkPieces network;
  for (const auto &[key, pieces] : segments) {
    slice_group(groups.at(key).line, pieces, bounds, network);
  }
  if (network.empty()) {
    throw std::runtime_error("network is empty after bbox clipping");
  }
  write_network_collection(out_path, network, requirements, bounds);
  const auto finished = std::chrono::steady_clock::now();
  std::cerr << "[mapgames] merge-network: " << groups.size()
            << " merged geometries, " << piece_count
            << " fraction-space pieces, " << network.size()
            << " output pieces\n";
  std::cerr << "[mapgames] merge-network load+group: "
            << std::chrono::duration<double>(segment_started - load_started)
                   .count()
            << "s, segment: "
            << std::chrono::duration<double>(slice_started - segment_started)
                   .count()
            << "s, slice+write: "
            << std::chrono::duration<double>(finished - slice_started).count()
            << "s\n";
  return 0;
}

void usage(const char *argv0) {
  std::cerr << "usage: " << argv0
            << " CONFIG REQUESTS_TSV OUT_DIR ROUTING_THREADS OUTPUT_THREADS"
               " MINUTES BOUNDS ROUTE_KEY SERVICE MODE\n"
            << "       " << argv0
            << " --merge-network OUT BOUNDS DUMP... [--debug-segments FILE]\n";
}

} // namespace

int main(int argc, char **argv) {
  if (argc >= 2 && std::string(argv[1]) == "--merge-network") {
    try {
      return merge_network_main(std::vector<std::string>(argv + 2, argv + argc));
    } catch (const std::exception &error) {
      std::cerr << "valhalla-expand: " << error.what() << '\n';
      return 1;
    }
  }
  if (argc != 11) {
    usage(argv[0]);
    return 2;
  }

  try {
    const std::string config_path = argv[1];
    const std::filesystem::path requests_path = argv[2];
    // Destination GeoJSON and the edge-interval dump both land here (the
    // caller's work directory; neither artifact is published).
    const std::filesystem::path out_dir = argv[3];
    const size_t requested_threads = std::stoul(argv[4]);
    const size_t requested_output_threads = std::stoul(argv[5]);
    const std::vector<int> minutes = parse_minutes(argv[6]);
    const Bounds bounds = parse_bounds(argv[7]);
    const std::string route_key = argv[8];
    const std::string service = argv[9];
    const std::string mode = argv[10];
    if (requested_threads == 0) {
      throw std::runtime_error("routing threads must be positive");
    }
    if (requested_output_threads == 0) {
      throw std::runtime_error("output threads must be positive");
    }

    const std::vector<Request> requests = read_requests(requests_path);
    if (requests.size() > UINT32_MAX || minutes.size() > UINT32_MAX) {
      throw std::runtime_error(
          "too many requests or minute thresholds for compact memberships");
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
    const size_t worker_count = std::min(requested_threads, requests.size());
    // Each worker constructs its own GraphReader, and Valhalla's default
    // mjolnir.max_cache_size is 1 GiB per reader, so N workers could hold
    // N GiB of tile cache. Cap it here (not in generate.py's valhalla.json,
    // which valhalla_build_tiles also consumes): 4 GiB split across workers
    // with a 256 MiB floor. Workers read this copy; the shared config used
    // by actor_t stays unmodified. Caching affects only speed, never
    // results.
    auto mjolnir = config.get_child("mjolnir");
    const uint64_t max_cache_size =
        std::max<uint64_t>(256ull << 20, (4096ull << 20) / worker_count);
    mjolnir.put("max_cache_size", max_cache_size);
    std::cerr << "[mapgames] native expansion GraphReader cache cap: "
              << max_cache_size << " bytes per worker\n";
    std::filesystem::create_directories(out_dir);

    std::vector<DestinationEdges> worker_destinations;
    worker_destinations.reserve(worker_count);
    for (size_t worker_index = 0; worker_index < worker_count; ++worker_index) {
      worker_destinations.emplace_back(minutes.size(), requests.size());
    }
    std::atomic_size_t next_request{0};
    std::atomic_size_t completed{0};
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
          if (request_index >= requests.size()) {
            break;
          }
          const Request &request = requests[request_index];
          try {
            // Unlike Valhalla's expansion action, the regular isochrone action
            // propagates request-setup errors (e.g. Loki's "no edges near
            // location") that the expansion swallows. With its 1-minute
            // contour this validation covers exactly those time-independent
            // errors, not mid-expansion failures.
            valhalla::Api validation_api;
            static_cast<void>(actor.isochrone(validation_request_json(request),
                                              nullptr, &validation_api));
            if (costing == nullptr) {
              costing =
                  valhalla::sif::CostFactory{}.Create(validation_api.options());
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
                      : reverse_edge_traversal_seconds(edge, cache_entry,
                                                       graph_reader, costing);
              for (size_t minute_index = 0; minute_index < minutes.size();
                   ++minute_index) {
                const std::optional<Interval> interval = reachable_interval(
                    edge, start_seconds, minutes[minute_index] * 60.0,
                    traversal_seconds);
                if (interval) {
                  const bool added = add_destination_interval(
                      worker_destinations[worker_index], cache_entry, *interval,
                      request_index, minute_index);
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
                throw std::runtime_error("no reachable lines for " +
                                         std::to_string(minutes[minute_index]) +
                                         " minutes");
              }
            }
          } catch (const std::exception &error) {
            std::lock_guard<std::mutex> lock(log_mutex);
            std::cerr << "valhalla-expand: request " << request.id << " ("
                      << request.feature_id << ") failed: " << error.what()
                      << '\n';
            throw;
          }

          const size_t now_completed = completed.fetch_add(1) + 1;
          if (now_completed % 100 == 0 || now_completed == requests.size()) {
            std::lock_guard<std::mutex> lock(log_mutex);
            std::cerr << "[mapgames] native expansion+lines: " << now_completed
                      << '/' << requests.size() << " routed\n";
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

    const auto routing_started = std::chrono::steady_clock::now();
    std::vector<std::jthread> workers;
    workers.reserve(worker_count);
    for (size_t worker_index = 0; worker_index < worker_count; ++worker_index) {
      workers.emplace_back(worker, worker_index);
    }
    for (auto &thread : workers) {
      thread.join();
    }
    if (first_error != nullptr) {
      std::rethrow_exception(first_error);
    }
    const auto routing_finished = std::chrono::steady_clock::now();

    validate_destination_geometry(worker_destinations);

    // Bound concurrent DestinationLines maps independently from routing.
    // Keeping this below the number of bands prevents the historical
    // all-bands-at-once multi-GiB output peak while allowing the Nix resource
    // policy to spend measured headroom on serialization throughput.
    const size_t output_worker_count =
        std::min(requested_output_threads, minutes.size());
    std::atomic_size_t next_minute{0};
    std::atomic_bool output_failed{false};
    std::exception_ptr first_output_error;
    std::mutex output_error_mutex;
    auto output_worker = [&]() {
      try {
        while (!output_failed.load(std::memory_order_acquire)) {
          const size_t minute_index = next_minute.fetch_add(1);
          if (minute_index >= minutes.size()) {
            break;
          }
          const DestinationLines destinations = destination_lines(
              worker_destinations, minute_index, requests, bounds);
          if (destinations.empty()) {
            throw std::runtime_error(
                "destination lookup is empty after bbox clipping for " +
                std::to_string(minutes[minute_index]) + " minutes");
          }
          const int minute = minutes[minute_index];
          write_destination_collection(
              out_dir / ("destinations-" + route_key + "-" +
                         std::to_string(minute) + ".geojson"),
              destinations, service, mode, minute, bounds);
        }
      } catch (...) {
        output_failed.store(true, std::memory_order_release);
        std::lock_guard<std::mutex> lock(output_error_mutex);
        if (first_output_error == nullptr) {
          first_output_error = std::current_exception();
        }
      }
    };
    std::vector<std::jthread> output_workers;
    output_workers.reserve(output_worker_count);
    for (size_t output_worker_index = 0;
         output_worker_index < output_worker_count; ++output_worker_index) {
      output_workers.emplace_back(output_worker);
    }
    for (auto &thread : output_workers) {
      thread.join();
    }
    if (first_output_error != nullptr) {
      std::rethrow_exception(first_output_error);
    }

    if (std::all_of(
            worker_destinations.begin(), worker_destinations.end(),
            [](const DestinationEdges &edges) { return edges.empty(); })) {
      throw std::runtime_error("edge-interval dump is empty");
    }
    verify_dump_nesting(worker_destinations, minutes.size());
    write_edge_dump(out_dir / ("edges-" + route_key + ".tsv"),
                    worker_destinations, minutes);
    const auto output_finished = std::chrono::steady_clock::now();
    std::cerr << "[mapgames] native parallel routing+line extraction: "
              << std::chrono::duration<double>(routing_finished -
                                               routing_started)
                     .count()
              << "s\n";
    std::cerr << "[mapgames] native interval union+bounded-parallel output: "
              << std::chrono::duration<double>(output_finished -
                                               routing_finished)
                     .count()
              << "s\n";
    std::cerr << "[mapgames] native expansion+lines: " << requests.size()
              << " routed with " << worker_count << " routing worker(s), "
              << output_worker_count << " output worker(s)\n";
  } catch (const std::exception &error) {
    std::cerr << "valhalla-expand: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
