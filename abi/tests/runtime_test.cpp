#include "flax/runtime.h"
#ifndef FLAX_ENGINE_HEADER
#define FLAX_ENGINE_HEADER "flax_hermes.h"
#define FLAX_ENGINE_API flax_hermes_get_api
#endif
#include FLAX_ENGINE_HEADER
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace {
const FlaxApi *api;
void require(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}
struct Error {
  FlaxError value{};
  ~Error() { api->error_clear(&value); }
  void check(int32_t status) {
    if (status != FLAX_OK) {
      throw std::runtime_error(std::string(
          reinterpret_cast<char *>(value.message), value.message_length));
    }
  }
};
FlaxValueId eval(FlaxRuntime *runtime, const char *source) {
  Error error;
  FlaxValueId result = 0;
  const char *url = "native-test.js";
  error.check(api->evaluate(runtime, reinterpret_cast<const uint8_t *>(source),
                            std::strlen(source),
                            reinterpret_cast<const uint8_t *>(url),
                            std::strlen(url), &result, &error.value));
  return result;
}
double number(FlaxRuntime *runtime, FlaxValueId id) {
  Error error;
  FlaxValueInfo info{};
  error.check(api->inspect(runtime, id, &info, &error.value));
  api->buffer_free(info.string_data);
  require(info.kind == FLAX_NUMBER, "Expected a number");
  return info.number;
}
int32_t host(void *, FlaxRuntime *runtime, FlaxValueId, const FlaxValueId *args,
             size_t count, FlaxValueId *result, FlaxError *outError) {
  try {
    require(count == 1, "Callback argument count");
    Error error;
    require(api->destroy(runtime, &error.value) == FLAX_STATE_ERROR,
            "Active destruction must fail");
    bool rejected = false;
    std::thread other([&] {
      Error foreignError;
      FlaxValueId ignored = 0;
      rejected = api->global_object(runtime, &ignored, &foreignError.value) ==
                 FLAX_STATE_ERROR;
    });
    other.join();
    require(rejected, "Concurrent entry must fail");
    auto nested = eval(runtime, "21 * 2");
    const auto answer = number(runtime, nested) + number(runtime, args[0]);
    error.check(api->release_value(runtime, nested, &error.value));
    return api->make_value(runtime, FLAX_NUMBER, answer, nullptr, 0, result,
                           outError);
  } catch (const std::exception &error) {
    const auto *message = reinterpret_cast<const uint8_t *>(error.what());
    api->error_set(outError, FLAX_JS_ERROR, message, std::strlen(error.what()),
                   nullptr, 0);
    return FLAX_JS_ERROR;
  }
}
} // namespace

int main() {
  try {
    require(FLAX_ENGINE_API(999) == nullptr, "Unknown ABI accepted");
    api = static_cast<const FlaxApi *>(FLAX_ENGINE_API(FLAX_ABI_VERSION));
    require(api && api->version == FLAX_ABI_VERSION &&
                api->struct_size == sizeof(FlaxApi),
            "ABI layout mismatch");
    Error error;
    FlaxRuntime *runtime = nullptr;
    error.check(api->create(&runtime, &error.value));
    const uint8_t bytes[] = {0, 127, 255};
    FlaxValueId byteValue = 0;
    error.check(api->make_bytes(runtime, bytes, 3, &byteValue, &error.value));
    uint8_t *copied = nullptr;
    size_t byteLength = 0;
    error.check(api->read_bytes(runtime, byteValue, &copied, &byteLength, &error.value));
    require(byteLength == 3 && std::memcmp(bytes, copied, 3) == 0, "Bulk bytes lost data");
    api->buffer_free(copied);
    auto transferFrozen = eval(runtime, R"JS(buffer => {
      const view = new Uint8Array(buffer);
      Object.freeze(buffer);
      const moved = buffer.transfer(5);
      return view.byteLength + buffer.byteLength + new Uint8Array(moved)[2];
    })JS");
    FlaxValueId transferred = 0;
    error.check(api->call(runtime, transferFrozen, 0, &byteValue, 1, &transferred, &error.value));
    require(number(runtime, transferred) == 255, "Frozen copied buffer did not transfer");
    error.check(api->release_value(runtime, transferred, &error.value));
    error.check(api->release_value(runtime, transferFrozen, &error.value));
    require(api->make_bytes(runtime, nullptr, 1, &transferred, &error.value) == FLAX_ARGUMENT_ERROR, "Null input accepted");
    require(api->make_bytes(runtime, bytes, SIZE_MAX, &transferred, &error.value) == FLAX_ARGUMENT_ERROR, "Unsafe byte length accepted");
    error.check(api->release_value(runtime, byteValue, &error.value));
    require(api->read_bytes(runtime, byteValue, &copied, &byteLength, &error.value) == FLAX_STATE_ERROR, "Released byte handle accepted");
    require(FLAX_ENGINE_API(1) == nullptr, "Old ABI accepted");
    require(number(runtime, eval(runtime, "(() => { const b = new ArrayBuffer(4); const v = new Uint8Array(b); v[0] = 42; const moved = b.transfer(8); return b.byteLength + v.byteLength + new Uint8Array(moved)[0]; })()")) == 42, "Transfer did not detach the original views");

    auto captured = eval(runtime, R"JS(
      (() => {
        const callbacks = [];
        for (const value of [1, 2]) callbacks.push(() => value);
        return callbacks[0]() * 10 + callbacks[1]();
      })()
    )JS");
    require(number(runtime, captured) == 12,
            "Loop closures must retain each iteration's binding");
    error.check(api->release_value(runtime, captured, &error.value));
    auto object = eval(runtime, "globalThis.object = {answer: 42}");
    auto same = eval(runtime, "object");
    int32_t equal = 0;
    error.check(
        api->strict_equals(runtime, object, same, &equal, &error.value));
    require(equal, "Object identity lost");
    error.check(api->release_value(runtime, same, &error.value));
    require(api->release_value(runtime, same, &error.value) == FLAX_STATE_ERROR,
            "Released handle accepted");
    FlaxRuntime *other = nullptr;
    error.check(api->create(&other, &error.value));
    FlaxValueInfo info{};
    require(api->inspect(other, object, &info, &error.value) ==
                FLAX_STATE_ERROR,
            "Foreign handle accepted");
    error.check(api->destroy(other, &error.value));

    const auto *name = reinterpret_cast<const uint16_t *>(u"host");
    error.check(
        api->register_host(runtime, name, 4, host, nullptr, &error.value));
    require(number(runtime, eval(runtime, "host(8)")) == 50,
            "Synchronous roundtrip failed");
    const auto *bad =
        reinterpret_cast<const uint8_t *>("throw new Error('expected')");
    FlaxValueId ignored = 0;
    require(api->evaluate(runtime, bad,
                          std::strlen(reinterpret_cast<const char *>(bad)),
                          nullptr, 0, &ignored, &error.value) == FLAX_JS_ERROR,
            "JS exception did not cross ABI as an error");
    require(error.value.message_length > 0, "Missing error message");
    require(number(runtime, eval(runtime, "1+2")) == 3,
            "Runtime unusable after exception");
    eval(runtime, "globalThis.jobs=0; Promise.resolve().then(() => jobs=1)");
    require(number(runtime, eval(runtime, "jobs")) == 0,
            "Unexpected automatic microtask flush");
    int32_t complete = 0;
    error.check(api->drain_microtasks(runtime, -1, &complete, &error.value));
    require(complete && number(runtime, eval(runtime, "jobs")) == 1,
            "Microtask drain failed");
    error.check(api->destroy(runtime, &error.value));
    for (int i = 0; i < 100; ++i) {
      error.check(api->create(&runtime, &error.value));
      eval(runtime, "({value: new Array(100).fill('retained')})");
      error.check(api->destroy(runtime, &error.value));
    }
    for (int i = 0; i < 20; ++i) {
      error.check(api->create(&runtime, &error.value));
      auto retained = eval(runtime, "({value: 42})");
      std::exception_ptr failure;
      std::thread next([&] {
        try {
          Error inner;
          require(number(runtime, eval(runtime, "21 * 2")) == 42,
                  "Migrated evaluation failed");
          inner.check(api->release_value(runtime, retained, &inner.value));
          inner.check(api->destroy(runtime, &inner.value));
        } catch (...) { failure = std::current_exception(); }
      });
      next.join();
      if (failure) std::rethrow_exception(failure);
    }
    std::cout << "Native runtime ABI, reentry, ownership, exceptions, jobs, "
                 "and teardown passed.\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
