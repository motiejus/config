#pragma once

#include <array>
#include <bit>
#include <cstdint>
#include <ostream>
#include <stdexcept>
#include <type_traits>

// Native, versioned handoff between the bounded Valhalla expansion batches and
// the destination catalog builder.  All integers and IEEE-754 doubles are
// little endian.  Keeping the framing primitives here makes the producer and
// consumer share one wire contract without a generated schema or text parser.
namespace mapgames::relations {

inline constexpr std::array<char, 16> kMagic{
    'M', 'A', 'P', 'G', 'A', 'M', 'E', 'S', '-', 'R', 'E', 'L', '-', '0', '1', '\0'};
inline constexpr uint32_t kVersion = 1;
inline constexpr uint32_t kBatchMarker = 0xb47c4e01;

template <typename Integer>
void write_le(std::ostream &output, Integer value) {
  static_assert(std::is_integral_v<Integer>);
  using Unsigned = std::make_unsigned_t<Integer>;
  Unsigned bits = static_cast<Unsigned>(value);
  // Serialize the little-endian bytes into a stack buffer and emit them in one
  // ostream::write. The byte content is identical to a per-byte put() loop, but
  // a single buffered write per value avoids the per-byte sentry/put overhead
  // that dominates the relation handoff (millions of values per batch).
  char bytes[sizeof(Integer)];
  for (size_t index = 0; index < sizeof(Integer); ++index) {
    bytes[index] = static_cast<char>(bits & 0xff);
    bits >>= 8;
  }
  output.write(bytes, sizeof(Integer));
}

inline void write_double(std::ostream &output, double value) {
  static_assert(sizeof(double) == sizeof(uint64_t));
  write_le(output, std::bit_cast<uint64_t>(value));
}

inline void require_output(const std::ostream &output) {
  if (!output) {
    throw std::runtime_error("could not write destination relation handoff");
  }
}

} // namespace mapgames::relations
