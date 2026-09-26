#include "engine.h"
#include <cstdlib>
#include "flax_v8.h"
#include "jsi_abi/JsiAbiRuntime.h"
#include "jsi_abi/v8_jsi_config.h"

namespace flax {
std::unique_ptr<facebook::jsi::Runtime> createEngineRuntime() {
  auto runtime = jsi::abi::makeJsiAbiRuntime(
      v8_create_runtime,
      [](void *, jsi_config config) {
        v8_jsi_config_set_explicit_microtask_policy(config, true);
        v8_jsi_config_enable_multi_thread(config, true);
        v8_jsi_config_enable_jit_tracing(config, std::getenv("FLAX_VERIFY_V8_JIT") != nullptr);
        return jsi_no_error;
      }, nullptr);
  if (std::getenv("FLAX_VERIFY_V8_JIT")) {
    runtime->evaluateJavaScript(std::make_shared<facebook::jsi::StringBuffer>(
        "function flaxJitProbe(x) { return x + 1; }"
        "for (let i = 0; i < 1000000; ++i) flaxJitProbe(i);"), "flax:jit-verification");
  }
  return runtime;
}
} // namespace flax

extern "C" const void *flax_v8_get_api(uint32_t version) {
  return version == FLAX_ABI_VERSION ? flax::runtimeApi() : nullptr;
}
