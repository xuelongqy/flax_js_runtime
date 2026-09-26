#ifndef FLAX_ENGINE_H
#define FLAX_ENGINE_H

#include "flax/runtime.h"
#include <jsi/jsi.h>
#include <memory>

namespace flax {
// Implemented once by the selected engine adapter, not by the shared runtime.
std::unique_ptr<facebook::jsi::Runtime> createEngineRuntime();
const FlaxApi *runtimeApi();
} // namespace flax
#endif
