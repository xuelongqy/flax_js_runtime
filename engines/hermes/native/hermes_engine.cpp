#include "engine.h"
#include "flax_hermes.h"
#include <hermes/hermes.h>

namespace flax {
std::unique_ptr<facebook::jsi::Runtime> createEngineRuntime() {
  // Upstream defaults block scoping off; source closures need per-iteration bindings.
  auto config = hermes::vm::RuntimeConfig::Builder()
                    .withES6BlockScoping(true)
                    .withMicrotaskQueue(true)
                    .build();
  return facebook::hermes::makeHermesRuntime(config);
}
} // namespace flax

extern "C" const void *flax_hermes_get_api(uint32_t version) {
  return version == FLAX_ABI_VERSION ? flax::runtimeApi() : nullptr;
}
