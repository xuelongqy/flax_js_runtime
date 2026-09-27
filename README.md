# Flax JavaScript Engine SDKs

This repository pins and patches upstream Hermes and V8, builds their shared libraries, and publishes relocatable macOS arm64 SDK archives. It does not contain Flax's C ABI or engine adapters. Those live in [Flax](https://github.com/xuelongqy/flax) and are compiled against the SDK by its native asset hooks.

The current SDK version is `runtime.json`'s `runtimeVersion`. Hermes retains the ArrayBuffer transfer patch. V8 is built as shared components with JIT enabled. QuickJS remains experimental and has no SDK.

On macOS arm64:

```sh
dart pub get
dart run tool/verify.dart
dart run tool/build.dart --engine=hermes
dart run tool/package.dart --engine=hermes
dart run tool/check_sdk.dart hermes build/sdk/hermes-macos-arm64
```

Use `--engine=v8` for V8 on the pinned Xcode 26.6 host described in `engines/v8/engine.json`. Building an engine never compiles Flax's ABI. An SDK contains all required dynamic libraries, headers, licenses, `manifest.json` with file hashes and build metadata, and a relocatable `FlaxEngineSDKConfig.cmake`. Consumers link `FlaxEngineSDK::hermes` or `FlaxEngineSDK::v8`.

`Engine builds` CI saves candidate archives. The `Publish engine SDK` workflow accepts a successful candidate run ID on a matching `v<runtimeVersion>` tag, rechecks the exact candidate archives and publishes those bytes. The old 0.1.0 ABI-containing archives are not compatible with SDK schema 2.
