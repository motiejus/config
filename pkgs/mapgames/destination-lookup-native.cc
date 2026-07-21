#include <sqlite3.h>
#include <fcntl.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <queue>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>
#include <unistd.h>

#include "destination-relations.hh"
#include "destination-lookup-finalize.hh"

namespace {

class Database {
public:
  explicit Database(const std::filesystem::path &path) {
    if (sqlite3_open(path.c_str(), &db_) != SQLITE_OK) {
      throw std::runtime_error("open sqlite: " + std::string(sqlite3_errmsg(db_)));
    }
  }
  ~Database() { sqlite3_close(db_); }
  Database(const Database &) = delete;
  sqlite3 *get() { return db_; }
  void exec(const char *sql) {
    char *error = nullptr;
    if (sqlite3_exec(db_, sql, nullptr, nullptr, &error) != SQLITE_OK) {
      std::string message = error == nullptr ? sqlite3_errmsg(db_) : error;
      sqlite3_free(error);
      throw std::runtime_error("sqlite: " + message);
    }
  }
private:
  sqlite3 *db_ = nullptr;
};

class Statement {
public:
  Statement(sqlite3 *db, const char *sql) : db_(db) {
    if (sqlite3_prepare_v2(db, sql, -1, &statement_, nullptr) != SQLITE_OK) {
      throw std::runtime_error("prepare sqlite: " + std::string(sqlite3_errmsg(db)));
    }
  }
  ~Statement() { sqlite3_finalize(statement_); }
  Statement(const Statement &) = delete;
  void reset() {
    sqlite3_reset(statement_);
    sqlite3_clear_bindings(statement_);
  }
  void text(int index, std::string_view value) {
    if (sqlite3_bind_text(statement_, index, value.data(), value.size(), SQLITE_TRANSIENT) != SQLITE_OK)
      fail();
  }
  void integer(int index, int64_t value) {
    if (sqlite3_bind_int64(statement_, index, value) != SQLITE_OK) fail();
  }
  void number(int index, double value) {
    if (sqlite3_bind_double(statement_, index, value) != SQLITE_OK) fail();
  }
  bool row() {
    const int result = sqlite3_step(statement_);
    if (result == SQLITE_ROW) return true;
    if (result == SQLITE_DONE) return false;
    fail();
    return false;
  }
  void done() {
    if (sqlite3_step(statement_) != SQLITE_DONE) fail();
    reset();
  }
  int64_t i64(int column) const { return sqlite3_column_int64(statement_, column); }
  double real(int column) const { return sqlite3_column_double(statement_, column); }
  const void *blob(int column) const { return sqlite3_column_blob(statement_, column); }
  int bytes(int column) const { return sqlite3_column_bytes(statement_, column); }
  std::string text_value(int column) const {
    const auto *value = sqlite3_column_text(statement_, column);
    if (value == nullptr) throw std::runtime_error("unexpected sqlite NULL text");
    return reinterpret_cast<const char *>(value);
  }
  std::string blob_value(int column) const {
    const void *value = sqlite3_column_blob(statement_, column);
    const int size = sqlite3_column_bytes(statement_, column);
    if (value == nullptr || size <= 0)
      throw std::runtime_error("unexpected sqlite NULL/empty blob");
    return {static_cast<const char *>(value), static_cast<size_t>(size)};
  }
  sqlite3_stmt *get() { return statement_; }
private:
  [[noreturn]] void fail() const {
    throw std::runtime_error("sqlite statement: " + std::string(sqlite3_errmsg(db_)));
  }
  sqlite3 *db_;
  sqlite3_stmt *statement_ = nullptr;
};

struct Route { std::string service, mode; std::filesystem::path path; };
using Members = std::vector<uint32_t>;

Route parse_route(std::string_view value) {
  const size_t first = value.find(':');
  const size_t second = first == value.npos ? value.npos : value.find(':', first + 1);
  if (first == value.npos || second == value.npos || second + 1 == value.size())
    throw std::runtime_error("route must be SERVICE:walk|drive:PATH");
  Route route{std::string(value.substr(0, first)),
              std::string(value.substr(first + 1, second - first - 1)),
              std::string(value.substr(second + 1))};
  if (route.mode != "walk" && route.mode != "drive")
    throw std::runtime_error("unknown route mode " + route.mode);
  return route;
}

using Coordinate = std::pair<int32_t, int32_t>;

void validate_geometry(const std::vector<Coordinate> &points,
                       const std::string &context) {
  if (points.size() < 2)
    throw std::runtime_error("degenerate geometry in " + context);
  std::string forward, reverse;
  for (size_t index = 0; index < points.size(); ++index) {
    const auto [lon, lat] = points[index];
    if (lon < -1'800'000'000 || lon > 1'800'000'000 ||
        lat < -900'000'000 || lat > 900'000'000)
      throw std::runtime_error("geometry coordinate out of bounds in " + context);
    if (index && points[index - 1] == points[index])
      throw std::runtime_error("degenerate geometry in " + context);
    forward += std::to_string(lon) + ',' + std::to_string(lat) + ';';
  }
  for (auto point = points.rbegin(); point != points.rend(); ++point)
    reverse += std::to_string(point->first) + ',' +
               std::to_string(point->second) + ';';
  if (reverse < forward)
    throw std::runtime_error("non-canonical geometry in " + context);
}

std::string delta_blob(const std::vector<Coordinate> &points) {
  std::string result;
  result.reserve(points.size() * sizeof(int32_t) * 2);
  const auto append = [&](int32_t value) {
    for (size_t byte = 0; byte < sizeof(value); ++byte)
      result.push_back(static_cast<char>(static_cast<uint32_t>(value) >> (byte * 8)));
  };
  append(points[0].first);
  append(points[0].second);
  for (size_t index = 1; index < points.size(); ++index) {
    const int64_t lon = static_cast<int64_t>(points[index].first) - points[index - 1].first;
    const int64_t lat = static_cast<int64_t>(points[index].second) - points[index - 1].second;
    if (lon < INT32_MIN || lon > INT32_MAX || lat < INT32_MIN || lat > INT32_MAX)
      throw std::runtime_error("delta coordinate overflow");
    append(static_cast<int32_t>(lon));
    append(static_cast<int32_t>(lat));
  }
  return result;
}

std::vector<Coordinate> geometry_points(const void *data, int bytes,
                                        const std::string &context) {
  if (data == nullptr || bytes < 16 || bytes % 8 != 0)
    throw std::runtime_error("invalid delta geometry in " + context);
  const auto *input = static_cast<const unsigned char *>(data);
  const auto read_i32 = [&](size_t offset) {
    const uint32_t value = static_cast<uint32_t>(input[offset]) |
        static_cast<uint32_t>(input[offset + 1]) << 8 |
        static_cast<uint32_t>(input[offset + 2]) << 16 |
        static_cast<uint32_t>(input[offset + 3]) << 24;
    return std::bit_cast<int32_t>(value);
  };
  std::vector<Coordinate> result;
  result.reserve(bytes / 8);
  int64_t lon = read_i32(0), lat = read_i32(4);
  result.emplace_back(static_cast<int32_t>(lon), static_cast<int32_t>(lat));
  for (size_t offset = 8; offset < static_cast<size_t>(bytes); offset += 8) {
    lon += read_i32(offset);
    lat += read_i32(offset + 4);
    if (lon < INT32_MIN || lon > INT32_MAX || lat < INT32_MIN || lat > INT32_MAX)
      throw std::runtime_error("delta coordinate overflow in " + context);
    result.emplace_back(static_cast<int32_t>(lon), static_cast<int32_t>(lat));
  }
  validate_geometry(result, context);
  return result;
}

void create_schema(Database &database) {
  database.exec(R"SQL(
    PRAGMA journal_mode=OFF;
    PRAGMA synchronous=OFF;
    PRAGMA temp_store=FILE;
    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE requirements (requirement INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE,
      service TEXT NOT NULL, mode TEXT NOT NULL, mode_bit INTEGER NOT NULL);
    CREATE TABLE presets (requirement INTEGER NOT NULL, minute INTEGER NOT NULL,
      collection TEXT, set_count INTEGER, PRIMARY KEY(requirement,minute)) WITHOUT ROWID;
    CREATE TABLE edges (edge_pk INTEGER PRIMARY KEY, edge_id INTEGER UNIQUE,
      delta_coords BLOB NOT NULL UNIQUE, mode_mask INTEGER NOT NULL);
    CREATE TABLE sets (requirement INTEGER NOT NULL, minute INTEGER NOT NULL,
      members BLOB NOT NULL, set_id INTEGER NOT NULL,
      PRIMARY KEY(requirement,minute,set_id)) WITHOUT ROWID;
    CREATE TABLE relation_runs (edge_pk INTEGER NOT NULL, requirement INTEGER NOT NULL,
      minute INTEGER NOT NULL, sequence INTEGER NOT NULL, start REAL NOT NULL,
      end REAL NOT NULL, set_id INTEGER NOT NULL,
      PRIMARY KEY(edge_pk,requirement,minute,sequence)) WITHOUT ROWID;
    CREATE TABLE relation_points (edge_pk INTEGER NOT NULL, requirement INTEGER NOT NULL,
      minute INTEGER NOT NULL, sequence INTEGER NOT NULL, point REAL NOT NULL,
      set_id INTEGER NOT NULL,
      PRIMARY KEY(edge_pk,requirement,minute,sequence)) WITHOUT ROWID;
    CREATE TABLE spatial_hits (x INTEGER NOT NULL, y INTEGER NOT NULL,
      edge_id INTEGER NOT NULL, PRIMARY KEY(x,y,edge_id)) WITHOUT ROWID;
    CREATE TEMP TABLE batch_sets (batch INTEGER NOT NULL, local_set INTEGER NOT NULL,
      members BLOB NOT NULL, PRIMARY KEY(batch,local_set)) WITHOUT ROWID;
    CREATE TEMP TABLE batch_runs (edge_pk INTEGER NOT NULL, requirement INTEGER NOT NULL,
      minute INTEGER NOT NULL, batch INTEGER NOT NULL, source INTEGER NOT NULL, start REAL NOT NULL,
      end REAL NOT NULL, local_set INTEGER NOT NULL,
      PRIMARY KEY(requirement,edge_pk,minute,source,start)) WITHOUT ROWID;
    CREATE TEMP TABLE batch_points (edge_pk INTEGER NOT NULL, requirement INTEGER NOT NULL,
      minute INTEGER NOT NULL, batch INTEGER NOT NULL, source INTEGER NOT NULL, point REAL NOT NULL,
      local_set INTEGER NOT NULL,
      PRIMARY KEY(requirement,edge_pk,minute,source,point)) WITHOUT ROWID;
    CREATE TEMP TABLE canonical_keys (canonical_key INTEGER PRIMARY KEY,
      delta_coords BLOB NOT NULL) WITHOUT ROWID;
  )SQL");
}

template <typename Integer> Integer read_le(std::istream &input, const std::string &context) {
  static_assert(std::is_integral_v<Integer>);
  using Unsigned = std::make_unsigned_t<Integer>;
  Unsigned value = 0;
  for (size_t index = 0; index < sizeof(Integer); ++index) {
    const int byte = input.get();
    if (byte == std::char_traits<char>::eof()) throw std::runtime_error("truncated " + context);
    value |= static_cast<Unsigned>(static_cast<unsigned char>(byte)) << (index * 8);
  }
  return static_cast<Integer>(value);
}

double read_double(std::istream &input, const std::string &context) {
  const double value = std::bit_cast<double>(read_le<uint64_t>(input, context));
  if (!std::isfinite(value) || value < 0 || value > 1)
    throw std::runtime_error("invalid fraction in " + context);
  return value;
}

std::string members_blob(const Members &members) {
  std::string result;
  result.reserve(members.size() * sizeof(uint32_t));
  for (uint32_t value : members)
    for (size_t byte = 0; byte < sizeof(value); ++byte)
      result.push_back(static_cast<char>((value >> (byte * 8)) & 0xff));
  return result;
}

Members decode_members(const void *data, int bytes) {
  if (bytes <= 0 || bytes % 4 != 0) throw std::runtime_error("invalid staged member set");
  const auto *input = static_cast<const unsigned char *>(data);
  Members result(bytes / 4);
  for (size_t index = 0; index < result.size(); ++index) {
    result[index] = static_cast<uint32_t>(input[index * 4]) |
                    static_cast<uint32_t>(input[index * 4 + 1]) << 8 |
                    static_cast<uint32_t>(input[index * 4 + 2]) << 16 |
                    static_cast<uint32_t>(input[index * 4 + 3]) << 24;
  }
  return result;
}

void bind_blob(sqlite3 *db, sqlite3_stmt *statement, int index, const std::string &value) {
  if (sqlite3_bind_blob(statement, index, value.data(), value.size(), SQLITE_TRANSIENT) != SQLITE_OK)
    throw std::runtime_error("bind sqlite blob: " + std::string(sqlite3_errmsg(db)));
}

struct BatchFunction {
  struct Run { double start, end; Members members; };
  std::vector<Run> runs;
  std::map<double, Members> points;
};

// Sized for the full multi-service finalize: the set-dedup cache holds every
// distinct (minute, members) tuple across all routes at once. Adding the
// ~9k-origin shelter service (coffee+fuel+hospital+shelter+supermarket x2)
// pushes well past the original 500k/256 MiB gate, so raise it to keep the
// whole workload in memory. ~4-5 GiB of finalize RAM at the ceiling.
constexpr size_t kMaxRouteSetCacheEntries = 16'000'000;
constexpr size_t kMaxRouteSetCacheKeyBytes = 4ull * 1024 * 1024 * 1024;

class RelationWriter {
public:
  explicit RelationWriter(Database &database)
      : database_(database.get()),
        insert_set_(database.get(), "INSERT INTO sets"
          "(requirement,minute,members,set_id) VALUES(?,?,?,?)"),
        run_(database.get(), "INSERT INTO relation_runs VALUES(?,?,?,?,?,?,?)"),
        point_(database.get(), "INSERT INTO relation_points VALUES(?,?,?,?,?,?)") {}

  int64_t intern(int requirement, int minute, const Members &members) {
    const std::string encoded = members_blob(members);
    std::string cache_key(sizeof(minute), '\0');
    std::memcpy(cache_key.data(), &minute, sizeof(minute));
    cache_key += encoded;
    if (const auto found = cache_.find(cache_key); found != cache_.end())
      return found->second;
    if (cache_.size() >= kMaxRouteSetCacheEntries ||
        cache_key.size() > kMaxRouteSetCacheKeyBytes - cache_key_bytes_)
      throw std::runtime_error("route membership cache exceeds its resource gate");

    // A writer owns one previously unseen requirement, so a route-cache miss
    // is necessarily a new set; probing a disk index cannot discover a match.
    const int64_t result = next_set_id_[minute]++;
    insert_set_.integer(1, requirement); insert_set_.integer(2, minute);
    bind_blob(database_, insert_set_.get(), 3, encoded);
    insert_set_.integer(4, result);
    insert_set_.done();
    // RelationWriter lives for one route. Explicit entry and encoded-byte
    // gates fail before an adversarial route can exhaust memory; normal routes
    // retain their full working set and avoid the SQLite-probe threshold cliff.
    cache_key_bytes_ += cache_key.size();
    cache_.emplace(std::move(cache_key), result);
    return result;
  }

  void write(int64_t edge_pk, int requirement, int minute,
             const std::vector<std::tuple<double, double, Members>> &runs,
             const std::vector<std::pair<double, Members>> &points) {
    for (size_t sequence = 0; sequence < runs.size(); ++sequence) {
      const auto &[start, end, members] = runs[sequence];
      run_.integer(1, edge_pk); run_.integer(2, requirement); run_.integer(3, minute);
      run_.integer(4, sequence); run_.number(5, start); run_.number(6, end);
      run_.integer(7, intern(requirement, minute, members)); run_.done();
    }
    for (size_t sequence = 0; sequence < points.size(); ++sequence) {
      const auto &[position, members] = points[sequence];
      point_.integer(1, edge_pk); point_.integer(2, requirement); point_.integer(3, minute);
      point_.integer(4, sequence); point_.number(5, position);
      point_.integer(6, intern(requirement, minute, members)); point_.done();
    }
    ++groups_; runs_ += runs.size(); points_ += points.size();
  }

  uint64_t groups() const { return groups_; }
  uint64_t runs() const { return runs_; }
  uint64_t points() const { return points_; }
private:
  sqlite3 *database_;
  Statement insert_set_, run_, point_;
  std::map<int, int64_t> next_set_id_;
  std::unordered_map<std::string, int64_t> cache_;
  size_t cache_key_bytes_ = 0;
  uint64_t groups_ = 0, runs_ = 0, points_ = 0;
};

void load_relation_route(Database &database, const Route &route, int requirement) {
  const int mode_bit = route.mode == "walk" ? 1 : 2;
  Statement requirement_row(database.get(), "INSERT INTO requirements VALUES(?,?,?,?,?)");
  requirement_row.integer(1, requirement); requirement_row.text(2, route.service + "_" + route.mode);
  requirement_row.text(3, route.service); requirement_row.text(4, route.mode);
  requirement_row.integer(5, mode_bit); requirement_row.done();
  std::ifstream input(route.path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot open " + route.path.string());
  for (char expected : mapgames::relations::kMagic)
    if (input.get() != static_cast<unsigned char>(expected))
      throw std::runtime_error("invalid relation magic: " + route.path.string());
  if (read_le<uint32_t>(input, "relation version") != mapgames::relations::kVersion)
    throw std::runtime_error("unsupported relation version: " + route.path.string());
  const uint32_t minute_count = read_le<uint32_t>(input, "minute count");
  if (minute_count == 0 || minute_count > 1024) throw std::runtime_error("invalid minute count");
  std::vector<uint32_t> minutes(minute_count);
  Statement preset(database.get(), "INSERT INTO presets(requirement,minute,collection) VALUES(?,?,?)");
  for (uint32_t index = 0; index < minute_count; ++index) {
    minutes[index] = read_le<uint32_t>(input, "minute");
    if (minutes[index] == 0 || (index && minutes[index] <= minutes[index - 1]))
      throw std::runtime_error("minutes must be positive and strictly increasing");
    preset.integer(1, requirement); preset.integer(2, minutes[index]);
    preset.text(3, "destination_edge_set:" + route.service + ':' + route.mode + ':' +
                       std::to_string(minutes[index]));
    preset.done();
  }
  Statement edge(database.get(), "INSERT INTO edges(delta_coords,mode_mask) VALUES(?,?) "
                                 "ON CONFLICT(delta_coords) DO UPDATE SET mode_mask=mode_mask|excluded.mode_mask "
                                 "RETURNING edge_pk");
  Statement insert_key(database.get(), "INSERT OR IGNORE INTO canonical_keys VALUES(?,?)");
  Statement find_key(database.get(),
                     "SELECT delta_coords FROM canonical_keys WHERE canonical_key=?");
  Statement set_row(database.get(), "INSERT INTO batch_sets VALUES(?,?,?)");
  Statement run(database.get(), "INSERT INTO batch_runs VALUES(?,?,?,?,?,?,?,?)");
  Statement point(database.get(), "INSERT INTO batch_points VALUES(?,?,?,?,?,?,?)");
  uint64_t batch = 0;
  uint64_t source = 0;
  uint64_t edge_rows = 0, run_rows = 0, point_rows = 0;
  while (input.peek() != std::char_traits<char>::eof()) {
    if (read_le<uint32_t>(input, "batch marker") != mapgames::relations::kBatchMarker)
      throw std::runtime_error("invalid relation batch marker");
    const uint32_t set_count = read_le<uint32_t>(input, "set count");
    if (set_count == 0 || set_count > 10'000'000) throw std::runtime_error("invalid set count");
    for (uint32_t local_set = 0; local_set < set_count; ++local_set) {
      const uint32_t member_count = read_le<uint32_t>(input, "set member count");
      if (member_count == 0 || member_count > 10'000'000)
        throw std::runtime_error("invalid set member count");
      Members members(member_count);
      for (uint32_t index = 0; index < member_count; ++index) {
        members[index] = read_le<uint32_t>(input, "set member");
        if (index && members[index] <= members[index - 1])
          throw std::runtime_error("set members must be strictly increasing");
      }
      const std::string encoded = members_blob(members);
      set_row.integer(1, batch); set_row.integer(2, local_set);
      bind_blob(database.get(), set_row.get(), 3, encoded); set_row.done();
    }
    const uint32_t edge_count = read_le<uint32_t>(input, "edge count");
    if (edge_count == 0 || edge_count > 10'000'000) throw std::runtime_error("invalid edge count");
    uint64_t previous_key = 0;
    for (uint32_t edge_index = 0; edge_index < edge_count; ++edge_index) {
      const uint64_t key = read_le<uint64_t>(input, "edge key");
      if (edge_index && key <= previous_key) throw std::runtime_error("edge keys not strictly increasing");
      previous_key = key;
      if (source == static_cast<uint64_t>(INT64_MAX)) throw std::runtime_error("too many edge sources");
      const int64_t source_id = source++;
      const uint32_t point_count = read_le<uint32_t>(input, "geometry point count");
      if (point_count < 2 || point_count > 1'000'000)
        throw std::runtime_error("invalid geometry point count");
      std::vector<Coordinate> points;
      points.reserve(point_count);
      for (uint32_t index = 0; index < point_count; ++index) {
        const int32_t lon = read_le<int32_t>(input, "longitude");
        const int32_t lat = read_le<int32_t>(input, "latitude");
        points.emplace_back(lon, lat);
      }
      validate_geometry(points, route.path.string());
      const std::string geometry = delta_blob(points);
      insert_key.integer(1, std::bit_cast<int64_t>(key));
      bind_blob(database.get(), insert_key.get(), 2, geometry);
      insert_key.done();
      find_key.integer(1, std::bit_cast<int64_t>(key));
      if (!find_key.row() || find_key.blob_value(0) != geometry)
        throw std::runtime_error("canonical edge key maps to inconsistent geometry");
      find_key.reset();
      bind_blob(database.get(), edge.get(), 1, geometry);
      edge.integer(2, mode_bit);
      if (!edge.row()) throw std::runtime_error("edge upsert returned no row");
      const int64_t edge_pk = edge.i64(0);
      edge.reset();
      const uint32_t band_count = read_le<uint32_t>(input, "band count");
      if (band_count == 0 || band_count > minute_count) throw std::runtime_error("invalid band count");
      uint32_t previous_minute_index = 0;
      for (uint32_t band_index = 0; band_index < band_count; ++band_index) {
        const uint32_t minute_index = read_le<uint32_t>(input, "minute index");
        if (minute_index >= minute_count || (band_index && minute_index <= previous_minute_index))
          throw std::runtime_error("invalid or unordered minute index");
        previous_minute_index = minute_index;
        const uint32_t runs = read_le<uint32_t>(input, "run count");
        if (runs > 10'000'000) throw std::runtime_error("invalid run count");
        double previous_end = -1;
        for (uint32_t index = 0; index < runs; ++index) {
          const double start = read_double(input, "run start"), end = read_double(input, "run end");
          const uint32_t local_set = read_le<uint32_t>(input, "run set");
          if (start >= end || start < previous_end || local_set >= set_count)
            throw std::runtime_error("invalid or unordered relation run");
          previous_end = end;
          run.integer(1, edge_pk); run.integer(2, requirement);
          run.integer(3, minutes[minute_index]); run.integer(4, batch);
          run.integer(5, source_id); run.number(6, start); run.number(7, end);
          run.integer(8, local_set); run.done(); ++run_rows;
        }
        const uint32_t points = read_le<uint32_t>(input, "breakpoint count");
        if (points > 10'000'000) throw std::runtime_error("invalid breakpoint count");
        double previous_position = -1;
        for (uint32_t index = 0; index < points; ++index) {
          const double position = read_double(input, "breakpoint");
          const uint32_t local_set = read_le<uint32_t>(input, "breakpoint set");
          if (position <= previous_position || local_set >= set_count)
            throw std::runtime_error("invalid or unordered breakpoint");
          previous_position = position;
          point.integer(1, edge_pk); point.integer(2, requirement);
          point.integer(3, minutes[minute_index]); point.integer(4, batch);
          point.integer(5, source_id); point.number(6, position);
          point.integer(7, local_set);
          point.done(); ++point_rows;
        }
        if (runs == 0 && points == 0) throw std::runtime_error("empty relation band");
      }
      ++edge_rows;
    }
    if (batch == static_cast<uint64_t>(INT64_MAX)) throw std::runtime_error("too many batches");
    ++batch;
  }
  if (!input.eof() || batch == 0) throw std::runtime_error("invalid relation handoff ending");
  std::cerr << "[mapgames] native classified load " << route.path.filename().string()
            << ": " << batch << " batches, " << edge_rows << " edge rows, "
            << run_rows << " runs, " << point_rows << " breakpoints\n";
}

void prepare_classified_relations(Database &database, int requirement_ordinal,
                                  bool final_route) {
  RelationWriter writer(database);
  // The temporary tables carry their downstream order in their primary keys.
  // Merge two cursors here instead of asking SQLite to materialize and sort a
  // country-wide UNION of runs and points for every route.
  constexpr const char *runs_sql =
    "SELECT r.edge_pk,r.minute,r.source,r.start,r.end,s.members"
    " FROM batch_runs r"
    " JOIN batch_sets s ON s.batch=r.batch AND s.local_set=r.local_set"
    " WHERE r.requirement=? ORDER BY r.edge_pk,r.minute,r.source,r.start";
  constexpr const char *points_sql =
    "SELECT p.edge_pk,p.minute,p.source,p.point,s.members"
    " FROM batch_points p"
    " JOIN batch_sets s ON s.batch=p.batch AND s.local_set=p.local_set"
    " WHERE p.requirement=? ORDER BY p.edge_pk,p.minute,p.source,p.point";
  const auto require_streaming_plan = [&](const std::string &sql) {
    Statement plan(database.get(), ("EXPLAIN QUERY PLAN " + sql).c_str());
    while (plan.row())
      if (plan.text_value(3).find("TEMP B-TREE") != std::string::npos)
        throw std::runtime_error("classified overlay query regressed to a temp sort");
  };
  require_streaming_plan(runs_sql);
  require_streaming_plan(points_sql);
  Statement runs(database.get(), runs_sql);
  Statement points(database.get(), points_sql);
  runs.integer(1, requirement_ordinal);
  points.integer(1, requirement_ordinal);
  bool have_run = runs.row(), have_point = points.row();
  int64_t current_edge = 0;
  bool have_current_edge = false;
  int current_minute = -1;
  std::map<int64_t, BatchFunction> source_functions;
  auto flush = [&] {
    if (!have_current_edge) return;
    struct SourceState {
      const BatchFunction *function;
      size_t next_run = 0;
      std::map<double, Members>::const_iterator next_point;
      const BatchFunction::Run *active = nullptr;
    };
    std::vector<SourceState> sources;
    sources.reserve(source_functions.size());
    for (const auto &[source, function] : source_functions) {
      static_cast<void>(source);
      sources.push_back({&function, 0, function.points.begin(), nullptr});
    }

    // Advance each source's already-sorted cursors once. The old implementation
    // searched every run in every source at every coordinate, which becomes
    // quadratic on edges shared by many expansion batches. Counts preserve the
    // sorted union while each source state implements exact-point overrides.
    std::map<uint32_t, size_t> member_counts;
    const auto add_members = [&](const Members &members) {
      for (const uint32_t member : members) ++member_counts[member];
    };
    const auto remove_members = [&](const Members &members) {
      for (const uint32_t member : members) {
        auto found = member_counts.find(member);
        if (found == member_counts.end())
          throw std::runtime_error("classified relation sweep underflow");
        if (--found->second == 0) member_counts.erase(found);
      }
    };
    const auto active_members = [&] {
      Members result;
      result.reserve(member_counts.size());
      for (const auto &[member, count] : member_counts) {
        static_cast<void>(count);
        result.push_back(member);
      }
      return result;
    };
    const auto source_next_coordinate = [&](const SourceState &source) {
      double result = 0;
      bool found = false;
      const auto consider = [&](double coordinate) {
        if (!found || coordinate < result) {
          result = coordinate;
          found = true;
        }
      };
      if (source.active != nullptr) consider(source.active->end);
      if (source.next_run < source.function->runs.size())
        consider(source.function->runs[source.next_run].start);
      if (source.next_point != source.function->points.end())
        consider(source.next_point->first);
      return std::pair{found, result};
    };

    std::vector<std::tuple<double, double, Members>> combined_runs;
    std::vector<std::pair<double, Members>> combined_points;
    using Pending = std::pair<double, size_t>;
    std::priority_queue<Pending, std::vector<Pending>, std::greater<Pending>> pending;
    for (size_t index = 0; index < sources.size(); ++index) {
      const auto [found, coordinate] = source_next_coordinate(sources[index]);
      if (found) pending.emplace(coordinate, index);
    }
    while (!pending.empty()) {
      const double position = pending.top().first;
      std::vector<size_t> touched;
      do {
        touched.push_back(pending.top().second);
        pending.pop();
      } while (!pending.empty() && pending.top().first == position);

      for (const size_t index : touched) {
        SourceState &source = sources[index];
        if (source.active != nullptr && source.active->end == position) {
          remove_members(source.active->members);
          source.active = nullptr;
        }
      }

      for (const size_t index : touched) {
        SourceState &source = sources[index];
        if (source.next_point != source.function->points.end() &&
            source.next_point->first == position) {
          if (source.active != nullptr) remove_members(source.active->members);
          add_members(source.next_point->second);
        }
      }
      Members point_members = active_members();
      if (!point_members.empty())
        combined_points.emplace_back(position, std::move(point_members));
      for (const size_t index : touched) {
        SourceState &source = sources[index];
        if (source.next_point != source.function->points.end() &&
            source.next_point->first == position) {
          remove_members(source.next_point->second);
          if (source.active != nullptr) add_members(source.active->members);
          ++source.next_point;
        }
      }

      for (const size_t index : touched) {
        SourceState &source = sources[index];
        if (source.next_run < source.function->runs.size() &&
            source.function->runs[source.next_run].start == position) {
          if (source.active != nullptr)
            throw std::runtime_error("classified relation run overlap");
          source.active = &source.function->runs[source.next_run++];
          add_members(source.active->members);
        }
        const auto [found, coordinate] = source_next_coordinate(source);
        if (found) pending.emplace(coordinate, index);
      }
      if (!pending.empty() && position < pending.top().first) {
        const double next = pending.top().first;
        Members run_members = active_members();
        if (!run_members.empty()) {
          if (!combined_runs.empty() && std::get<1>(combined_runs.back()) == position &&
              std::get<2>(combined_runs.back()) == run_members)
            std::get<1>(combined_runs.back()) = next;
          else
            combined_runs.emplace_back(position, next, std::move(run_members));
        }
      }
    }
    if (!member_counts.empty())
      throw std::runtime_error("classified relation sweep did not finish empty");
    if (combined_runs.empty() && combined_points.empty())
      throw std::runtime_error("classified relation overlay is empty");
    writer.write(current_edge, requirement_ordinal, current_minute,
                 combined_runs, combined_points);
  };
  while (have_run || have_point) {
    // kind=0 sorts every source's runs before kind=1 exact breakpoints.
    const bool take_run = !have_point || (have_run &&
        std::tuple{runs.i64(0), runs.i64(1), runs.i64(2), 0, runs.real(3)} <
        std::tuple{points.i64(0), points.i64(1), points.i64(2), 1, points.real(3)});
    Statement &rows = take_run ? runs : points;
    const int64_t edge_pk = rows.i64(0);
    const int minute = rows.i64(1);
    const int64_t source = rows.i64(2);
    if (!have_current_edge || edge_pk != current_edge || minute != current_minute) {
      flush(); current_edge = edge_pk;
      have_current_edge = true;
      current_minute = minute; source_functions.clear();
    }
    if (take_run) {
      Members members = decode_members(rows.blob(5), rows.bytes(5));
      source_functions[source].runs.push_back(
          {rows.real(3), rows.real(4), std::move(members)});
      have_run = runs.row();
    } else {
      Members members = decode_members(rows.blob(4), rows.bytes(4));
      source_functions[source].points.emplace(rows.real(3), std::move(members));
      have_point = points.row();
    }
  }
  flush();
  if (final_route)
    database.exec("DROP TABLE batch_runs; DROP TABLE batch_points; DROP TABLE batch_sets; "
                  "DROP TABLE canonical_keys;");
  else
    database.exec("DELETE FROM batch_runs; DELETE FROM batch_points; DELETE FROM batch_sets;");
  std::cerr << "[mapgames] native classified overlay: " << writer.groups() << " groups, "
            << writer.runs() << " runs, " << writer.points() << " breakpoints\n";
}

constexpr int kSchemaVersion = 3;
constexpr int kSpatialZoom = 15;
constexpr int kSpatialSpan = 1 << kSpatialZoom;

std::pair<double, double> mercator_tile(const Coordinate &point) {
  constexpr double scale = kSpatialSpan;
  constexpr double pi = 3.141592653589793238462643383279502884;
  const double lon = point.first / 10'000'000.0;
  const double lat = std::clamp(point.second / 10'000'000.0,
                                -85.05112878, 85.05112878);
  const double radians = lat * pi / 180.0;
  return {(lon + 180.0) / 360.0 * scale,
          (1.0 - std::asinh(std::tan(radians)) / pi) / 2.0 * scale};
}

bool segment_intersects(double x0, double y0, double x1, double y1,
                        double left, double top, double right, double bottom) {
  const double dx = x1 - x0, dy = y1 - y0;
  double low = 0, high = 1;
  for (auto [p, q] : std::array<std::pair<double, double>, 4>{
           std::pair{-dx, x0 - left}, {dx, right - x0},
           {-dy, y0 - top}, {dy, bottom - y0}}) {
    if (p == 0) { if (q < 0) return false; continue; }
    const double ratio = q / p;
    if (p < 0) low = std::max(low, ratio); else high = std::min(high, ratio);
    if (low > high) return false;
  }
  return true;
}

std::set<std::pair<int, int>> geometry_tiles(const std::vector<Coordinate> &points) {
  std::vector<std::pair<double, double>> projected;
  projected.reserve(points.size());
  for (const Coordinate point : points) projected.push_back(mercator_tile(point));
  std::set<std::pair<int, int>> result;
  constexpr double epsilon = 1e-10;
  for (size_t index = 1; index < projected.size(); ++index) {
    const auto [x0, y0] = projected[index - 1];
    const auto [x1, y1] = projected[index];
    const int min_x = std::max(0, static_cast<int>(std::floor(std::min(x0, x1) - epsilon)));
    const int max_x = std::min(kSpatialSpan - 1,
                               static_cast<int>(std::floor(std::max(x0, x1) + epsilon)));
    const int min_y = std::max(0, static_cast<int>(std::floor(std::min(y0, y1) - epsilon)));
    const int max_y = std::min(kSpatialSpan - 1,
                               static_cast<int>(std::floor(std::max(y0, y1) + epsilon)));
    for (int x = min_x; x <= max_x; ++x)
      for (int y = min_y; y <= max_y; ++y)
        if (segment_intersects(x0, y0, x1, y1, x, y, x + 1, y + 1))
          result.emplace(x, y);
  }
  return result;
}

void finalize_edge_ids_and_spatial(Database &database) {
  // First-seen edge order is deterministic for a fixed, explicit expansion
  // batch layout. The resulting IDs are build-scoped and deployed atomically
  // under edge_build_id. Relation rows stay in their ingestion keys and are
  // never rematerialized.
  Statement edges(database.get(),
      "SELECT edge_pk,delta_coords FROM edges ORDER BY edge_pk");
  Statement update(database.get(), "UPDATE edges SET edge_id=? WHERE edge_pk=?");
  Statement hit(database.get(), "INSERT INTO spatial_hits VALUES(?,?,?)");
  int64_t edge_id = 0;
  uint64_t hits = 0;
  while (edges.row()) {
    const int64_t edge_pk = edges.i64(0);
    const std::vector<Coordinate> points =
        geometry_points(edges.blob(1), edges.bytes(1), "stored edge");
    const int64_t id = edge_id++;
    update.integer(1, id); update.integer(2, edge_pk);
    update.done();
    for (auto [x, y] : geometry_tiles(points)) {
      hit.integer(1, x); hit.integer(2, y); hit.integer(3, id);
      hit.done(); ++hits;
    }
  }
  database.exec(R"SQL(
    UPDATE presets SET set_count=(SELECT count(*) FROM sets
      WHERE sets.requirement=presets.requirement AND sets.minute=presets.minute);
  )SQL");
  Statement metadata(database.get(), "INSERT INTO metadata(key,value) VALUES(?,?)");
  const auto write_metadata = [&](std::string_view key, uint64_t value) {
    const std::string encoded = std::to_string(value);
    metadata.text(1, key);
    metadata.text(2, encoded);
    metadata.done();
  };
  write_metadata("schema_version", kSchemaVersion);
  write_metadata("spatial_zoom", kSpatialZoom);
  write_metadata("edge_count", static_cast<uint64_t>(edge_id));
  write_metadata("spatial_hit_count", hits);
  std::cerr << "[mapgames] native lookup finalized " << edge_id << " edge ids and "
            << hits << " spatial candidates\n";
}

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

std::filesystem::path temporary_sibling(const std::filesystem::path &target) {
  const std::filesystem::path absolute =
      std::filesystem::absolute(target).lexically_normal();
  std::string pattern =
      (absolute.parent_path() /
       (absolute.filename().string() + ".mapgames-build-XXXXXX"))
          .string();
  std::vector<char> writable(pattern.begin(), pattern.end());
  writable.push_back('\0');
  const int descriptor = mkstemp(writable.data());
  if (descriptor < 0) {
    throw std::runtime_error("could not create temporary database sibling for " +
                             target.string());
  }
  if (close(descriptor) != 0) {
    const std::filesystem::path failed(writable.data());
    std::error_code ignored;
    std::filesystem::remove(failed, ignored);
    throw std::runtime_error("could not close temporary database sibling for " +
                             target.string());
  }
  return writable.data();
}

void remove_owned_path(const std::filesystem::path &path) noexcept {
  if (path.empty()) return;
  std::error_code ignored;
  std::filesystem::remove(path, ignored);
}

void fsync_file(const std::filesystem::path &path) {
  const int descriptor = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::runtime_error("could not open database for sync: " + path.string());
  }
  if (fsync(descriptor) != 0) {
    const std::string message = "could not sync database: " + path.string();
    close(descriptor);
    throw std::runtime_error(message);
  }
  if (close(descriptor) != 0) {
    throw std::runtime_error("could not close synced database: " + path.string());
  }
}

void fsync_parent_directory(const std::filesystem::path &path) {
  const auto parent = std::filesystem::absolute(path).parent_path();
  const int descriptor = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (descriptor < 0) {
    throw std::runtime_error("could not open database directory for sync: " +
                             parent.string());
  }
  if (fsync(descriptor) != 0) {
    const std::string message = "could not sync database directory: " +
                                parent.string();
    close(descriptor);
    throw std::runtime_error(message);
  }
  if (close(descriptor) != 0) {
    throw std::runtime_error("could not close synced database directory: " +
                             parent.string());
  }
}

} // namespace

int destination_lookup_main(const std::vector<std::string> &args) {
  try {
    std::filesystem::path database_path;
    std::vector<Route> routes;
    for (size_t index = 0; index < args.size(); ++index) {
      const std::string_view argument = args[index];
      if (argument == "--database" && ++index < args.size()) database_path = args[index];
      else if (argument == "--route" && ++index < args.size()) routes.push_back(parse_route(args[index]));
      else throw std::runtime_error("usage: destination-lookup-native --database DB --route SERVICE:MODE:PATH ...");
    }
    if (database_path.empty() || routes.empty()) throw std::runtime_error("database and routes are required");
    std::sort(routes.begin(), routes.end(), [](const Route &a, const Route &b) {
      return std::tie(a.service, a.mode) < std::tie(b.service, b.mode);
    });
    for (size_t index = 1; index < routes.size(); ++index)
      if (routes[index - 1].service == routes[index].service && routes[index - 1].mode == routes[index].mode)
        throw std::runtime_error("duplicate service/mode route");
    for (const auto &route : routes) {
      if (same_file_identity(database_path, route.path)) {
        throw std::runtime_error("database output and route input must identify different files");
      }
    }
    std::filesystem::path database_temporary = temporary_sibling(database_path);
    const auto started = std::chrono::steady_clock::now();
    try {
      {
        Database database(database_temporary);
        create_schema(database);
        database.exec("BEGIN");
        for (size_t index = 0; index < routes.size(); ++index) {
          const auto route_started = std::chrono::steady_clock::now();
          load_relation_route(database, routes[index], index);
          const auto overlay_started = std::chrono::steady_clock::now();
          prepare_classified_relations(database, index, index + 1 == routes.size());
          const auto route_finished = std::chrono::steady_clock::now();
          std::cerr << "[mapgames] native route phases " << routes[index].service
                    << '_' << routes[index].mode << ": load="
                    << std::chrono::duration<double>(overlay_started - route_started).count()
                    << "s, overlay="
                    << std::chrono::duration<double>(route_finished - overlay_started).count()
                    << "s\n";
        }
        finalize_edge_ids_and_spatial(database);
        database.exec("COMMIT");
      }
      const auto database_size = std::filesystem::file_size(database_temporary);
      fsync_file(database_temporary);
      std::filesystem::rename(database_temporary, database_path);
      // The rename has consumed the staging file; clear the handle before the
      // parent-directory sync so a sync failure does not send the cleanup path
      // chasing an already-renamed temporary while the database is published.
      database_temporary.clear();
      fsync_parent_directory(database_path);
      std::cerr << "[mapgames] native lookup normalization: "
                << std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count()
                << "s, sqlite=" << database_size << " bytes\n";
    } catch (...) {
      remove_owned_path(database_temporary);
      throw;
    }
  } catch (const std::exception &error) {
    std::cerr << "destination-lookup-native: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
