// White-box adapter test: inspect queue lifetime without exporting test APIs.
#include "jsi_abi/jsi_abi_v8.cpp"
#include "jsi_abi/JsiAbiRuntime.h"
#include <stdexcept>
#include <thread>

struct CountedTask : v8::Task {
  int &runs;
  int &deletions;
  CountedTask(int &r, int &d) : runs(r), deletions(d) {}
  ~CountedTask() override { ++deletions; }
  void Run() override { ++runs; }
};

int main() {
  if (v8_create_runtime(JSI_ABI_VERSION + 1, nullptr, nullptr)) return 5;
  for (int iteration = 0; iteration < 20; ++iteration) {
    auto *runtime = v8_create_runtime(JSI_ABI_VERSION,
        [](void *, jsi_config config) {
          v8_jsi_config_enable_multi_thread(config, true);
          v8_jsi_config_set_explicit_microtask_policy(config, true);
          return jsi_no_error;
        }, nullptr);
    if (!runtime) return 1;
    // A wrapper must reject an old table before reading any ABI 2 slots.
    auto *original = runtime->vt;
    auto oldTable = *original;
    oldTable.get_abi_version = [](jsi_runtime *) -> uint32_t { return 1; };
    runtime->vt = &oldTable;
    bool rejected = false;
    try { auto wrapper = jsi::abi::wrapJsiRuntime(runtime); }
    catch (const facebook::jsi::JSINativeException &) { rejected = true; }
    runtime->vt = original;
    if (!rejected) return 6;
    const uint16_t unit = 0;
    auto tooLong = runtime->vt->create_string_from_utf16(
        runtime, &unit, static_cast<size_t>(v8::String::kMaxLength) + 1);
    if (!abi::is_error(tooLong)) return 7;
    auto empty = runtime->vt->create_string_from_utf16(runtime, nullptr, 0);
    if (abi::is_error(empty)) return 8;
    abi::get_string(empty).pointer->vtable->invalidate(abi::get_string(empty).pointer);
    auto *state = static_cast<JsiRuntimeState *>(runtime);
    auto runner = v8rt::V8PlatformHolder::foregroundTaskRunner(state->isolate);
    int runs = 0;
    int deletions = 0;
    runner->PostTask(std::make_unique<CountedTask>(runs, deletions));
    runner->PostDelayedTask(std::make_unique<CountedTask>(runs, deletions), 3600);
    if (runs || deletions) return 2;
    std::thread next([&] {
      { V8Scope scope(state); }
      if (runs != 1 || deletions != 1) std::terminate();
      runner->PostTask(std::make_unique<CountedTask>(runs, deletions));
      runtime->vt->release(runtime);
    });
    next.join();
    // Disposal cancels immediate and delayed work without executing callbacks.
    if (runs != 1 || deletions != 3) return 3;
    runner->PostTask(std::make_unique<CountedTask>(runs, deletions));
    if (runs != 1 || deletions != 4) return 4;
  }
  std::puts("V8 foreground entry, migration, cancellation and recreation passed.");
}
