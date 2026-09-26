#ifndef FLAX_VALUE_ID_H
#define FLAX_VALUE_ID_H

#include <atomic>
#include <cstdint>
#include <stdexcept>

namespace flax {
// IDs are opaque, process-local values. Each engine library owns one allocator.
template <uint8_t EngineId> class ValueIdAllocator {
  static_assert(EngineId == 1 || EngineId == 2, "Unknown Flax engine ID");
 public:
  static constexpr uint64_t maxSequence = (uint64_t{1} << 56) - 1;
  explicit ValueIdAllocator(uint64_t first = 1) : sequence_(first) {
    if (!first || first > maxSequence + 1)
      throw std::invalid_argument("Invalid value sequence");
  }
  uint64_t next() {
    auto sequence = sequence_.load(std::memory_order_relaxed);
    // Saturate instead of wrapping, including when several runtimes allocate.
    while (sequence <= maxSequence) {
      if (sequence_.compare_exchange_weak(sequence, sequence + 1,
                                          std::memory_order_relaxed)) {
        return (uint64_t{EngineId} << 56) | sequence;
      }
    }
    throw std::overflow_error("Value ID space exhausted");
  }
 private:
  std::atomic<uint64_t> sequence_;
};
} // namespace flax
#endif
