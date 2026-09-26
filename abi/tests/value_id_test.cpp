#include "value_id.h"
#include <algorithm>
#include <iostream>
#include <thread>
#include <vector>

void require(bool result) {
  if (!result) throw std::runtime_error("Value ID allocator regression");
}
int main() {
  try {
    flax::ValueIdAllocator<1> hermes;
    flax::ValueIdAllocator<2> v8;
    require(hermes.next() == (uint64_t{1} << 56) + 1);
    require(v8.next() == (uint64_t{2} << 56) + 1);
    constexpr size_t threads = 8, count = 10000;
    std::vector<uint64_t> ids(threads * count);
    std::vector<std::thread> workers;
    for (size_t t = 0; t < threads; ++t) {
      workers.emplace_back([&, t] {
        for (size_t i = 0; i < count; ++i) ids[t * count + i] = hermes.next();
      });
    }
    for (auto &worker : workers) worker.join();
    std::sort(ids.begin(), ids.end());
    for (size_t i = 0; i < ids.size(); ++i)
      require(ids[i] == (uint64_t{1} << 56) + 2 + i);
    constexpr auto max = flax::ValueIdAllocator<2>::maxSequence;
    flax::ValueIdAllocator<2> exhausted(max - 1);
    require(exhausted.next() == (uint64_t{2} << 56) + max - 1);
    require(exhausted.next() == (uint64_t{2} << 56) + max);
    for (int i = 0; i < 10; ++i) {
      bool rejected = false;
      try { exhausted.next(); } catch (const std::overflow_error &) { rejected = true; }
      require(rejected);
    }
    std::cout << "Value ID namespaces, concurrency and permanent exhaustion passed.\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
