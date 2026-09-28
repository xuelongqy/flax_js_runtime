# Flax JavaScript Engine SDKs

This repository pins and patches upstream Hermes and V8, builds shared libraries, and packages relocatable engine SDK archives. It does not contain Flax's C ABI or engine adapters. Those live in [Flax](https://github.com/xuelongqy/flax) and are compiled against the SDK by its native asset hooks.

The candidate SDK version is `runtime.json`'s `runtimeVersion` (`0.3.0`). Published `0.2.0` archives remain unchanged. Hermes retains the ArrayBuffer transfer patch. The Android Hermes SDK omits React Native's fbjni finalizer-thread wrapper; JSI finalizers in this SDK must not release JNI references. V8 uses shared components on macOS and Linux; Windows, Android, and iOS link monolith archives into shared libraries. V8's experimental Temporal support is disabled on monolith targets because upstream's Rust dependency is absent from the monolith archive ([upstream issue](https://issues.chromium.org/issues/434763436)); component targets retain it. iOS is jitless. QuickJS remains experimental and has no SDK.

On a matching build host, select one of the targets listed in `tool/src/target.dart`:

```sh
dart pub get
dart run tool/verify.dart
dart run tool/build.dart --engine=hermes --target=macos-arm64
dart run tool/package.dart --engine=hermes --target=macos-arm64
dart run tool/check_sdk.dart hermes build/sdk/hermes-macos-arm64
```

Use `--engine=v8` for V8. The macOS arm64 V8 build requires the pinned Xcode 26.6 host described in `engines/v8/engine.json`. Building an engine never compiles Flax's ABI. An SDK contains its dynamic libraries, headers, licenses, `manifest.json` with file hashes, dependencies and build metadata, and a relocatable `FlaxEngineSDKConfig.cmake`. Consumers link `FlaxEngineSDK::hermes` or `FlaxEngineSDK::v8`.

Windows SDKs also bundle the selected Visual Studio toolset's release C++ runtime DLLs and Microsoft license terms. Deploy all `lib/*.dll` files alongside the executable. The manifest separates runtime DLLs (`runtimeLibraries`) from engine DLLs with import libraries (`importLibraries`); only engine DLLs are CMake link targets. Windows supplies the Universal CRT and ICU.

Linux V8 SDKs bundle Chromium's matching libc++ headers and `libc++.so`. Their CMake target requires Clang 21 or newer; CI uses Clang 23. Consumers must compile against the bundled headers so their C++ ABI matches the engine.

Run `Engine SDK candidates` manually to build the 12 target variants for both engines. Linux arm64 is cross-compiled on an x64 host and its relocated consumer runs in a separate arm64 CI job. Other desktop jobs run an out-of-repository relocated consumer; Android and iOS jobs only compile and link it. Executed V8 consumers check machine-code events against the target's JIT or jitless mode. A successful build is not device validation. Use `tool/check_sdk.dart` with `--adb-serial` or `--simulator` for executable mobile checks. iOS device loading still requires an app on a signed physical device. New 0.3.0 targets are candidates until they have run on their target platforms.

The `Publish engine SDK` workflow accepts a successful single candidate run containing all 24 archives. A `v<runtimeVersion>-rc.N` tag publishes those verified bytes as a build-only prerelease; the stable `v<runtimeVersion>` tag additionally requires confirmation of target-device and Flax validation. Neither route accepts incomplete candidate runs.
