# Flax JavaScript Runtime

Builds, verifies, and distributes JavaScript engines for Flax.

This repository owns engine source pinning, patches, native adapters, conformance testing, and release artifacts. The Flax framework consumes normalized artifacts and does not need to build an engine from source.

## Engines

| Engine | Status | Adapter |
| --- | --- | --- |
| Hermes | stable | Flax ABI over JSI |
| V8 | stable | Flax ABI over v8-jsi |
| QuickJS | experimental | not implemented |

The public compatibility boundary is the versioned Flax C ABI in `abi/`. Engine build systems are intentionally not normalized.

Initial release target: macOS arm64.
