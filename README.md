# Flax JavaScript Engine SDKs

This repository pins and patches upstream Hermes and V8, builds shared libraries, and packages relocatable engine SDK archives. It does not contain Flax's C ABI or engine adapters. Those live in [Flax](https://github.com/xuelongqy/flax) and are compiled against the SDK by its native asset hooks.

The candidate SDK version is `runtime.json`'s `runtimeVersion` (`0.3.0`). Published `0.2.0` archives remain unchanged. Hermes retains the ArrayBuffer transfer patch. V8 uses shared components on desktop; Android and iOS link monolith archives into shared libraries. iOS is jitless. QuickJS remains experimental and has no SDK.

On a matching build host, select one of the targets listed in `tool/src/target.dart`:

```sh
dart pub get
dart run tool/verify.dart
dart run tool/build.dart --engine=hermes --target=macos-arm64
dart run tool/package.dart --engine=hermes --target=macos-arm64
dart run tool/check_sdk.dart hermes build/sdk/hermes-macos-arm64
```

Use `--engine=v8` for V8. The macOS arm64 V8 build requires the pinned Xcode 26.6 host described in `engines/v8/engine.json`. Building an engine never compiles Flax's ABI. An SDK contains its dynamic libraries, headers, licenses, `manifest.json` with file hashes, dependencies and build metadata, and a relocatable `FlaxEngineSDKConfig.cmake`. Consumers link `FlaxEngineSDK::hermes` or `FlaxEngineSDK::v8`.

Run `Engine SDK candidates` manually to build the 12 target variants for both engines. Linux arm64 is cross-compiled on an x64 host and its relocated consumer runs in a separate arm64 CI job. Other desktop jobs run an out-of-repository relocated consumer; Android and iOS jobs only compile and link it. A successful build is not device validation. Use `tool/check_sdk.dart` with `--adb-serial` or `--simulator` for executable mobile checks. iOS device loading still requires an app on a signed physical device. New 0.3.0 targets are candidates until they have run on their target platforms.

The `Publish engine SDK` workflow accepts a successful single candidate run on a matching `v<runtimeVersion>` tag, requires confirmation of physical-device validation, checks all 24 archives and their manifests, and would publish the same bytes. Do not trigger it before platform validation is complete.
