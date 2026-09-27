import 'dart:ffi';
import 'dart:io';

final class SdkTarget {
  const SdkTarget(
    this.id,
    this.os,
    this.architecture,
    this.minimumVersion, {
    this.appleSdk,
    this.minimumGlibc,
  });

  final String id;
  final String os;
  final String architecture;
  final String minimumVersion;
  final String? appleSdk;
  final String? minimumGlibc;

  bool get isApple => os == 'macos' || os == 'ios';
  bool get isMobile => os == 'ios' || os == 'android';
  String get extension => isApple
      ? '.dylib'
      : os == 'windows'
      ? '.dll'
      : '.so';
  String get cmakeArchitecture => architecture == 'x64'
      ? 'x86_64'
      : architecture == 'arm32'
      ? 'armv7'
      : 'arm64';
  String get androidAbi => switch (architecture) {
    'arm32' => 'armeabi-v7a',
    'arm64' => 'arm64-v8a',
    'x64' => 'x86_64',
    _ => throw StateError('Unsupported Android architecture: $architecture'),
  };

  void requireBuildHost() {
    final host = Platform.operatingSystem;
    final abi = Abi.current().toString().toLowerCase();
    final valid = switch (os) {
      'macos' =>
        host == 'macos' &&
            (architecture == 'arm64'
                ? abi.contains('arm64')
                : abi.contains('x64')),
      'ios' => host == 'macos',
      'android' => host == 'linux',
      'linux' || 'windows' =>
        host == os &&
            (architecture == 'arm64'
                ? abi.contains('arm64')
                : abi.contains('x64')),
      _ => false,
    };
    if (!valid) throw UnsupportedError('$id cannot be built on $host/$abi');
  }
}

const sdkTargets = <String, SdkTarget>{
  'macos-arm64': SdkTarget('macos-arm64', 'macos', 'arm64', '15.0'),
  'macos-x64': SdkTarget('macos-x64', 'macos', 'x64', '15.0'),
  'linux-x64': SdkTarget(
    'linux-x64',
    'linux',
    'x64',
    '20.04',
    minimumGlibc: '2.31',
  ),
  'linux-arm64': SdkTarget(
    'linux-arm64',
    'linux',
    'arm64',
    '20.04',
    minimumGlibc: '2.31',
  ),
  'windows-x64': SdkTarget('windows-x64', 'windows', 'x64', '11'),
  'windows-arm64': SdkTarget('windows-arm64', 'windows', 'arm64', '11'),
  'android-arm32': SdkTarget('android-arm32', 'android', 'arm32', '24'),
  'android-arm64': SdkTarget('android-arm64', 'android', 'arm64', '24'),
  'android-x64': SdkTarget('android-x64', 'android', 'x64', '24'),
  'ios-device-arm64': SdkTarget(
    'ios-device-arm64',
    'ios',
    'arm64',
    '15.0',
    appleSdk: 'iphoneos',
  ),
  'ios-simulator-arm64': SdkTarget(
    'ios-simulator-arm64',
    'ios',
    'arm64',
    '15.0',
    appleSdk: 'iphonesimulator',
  ),
  'ios-simulator-x64': SdkTarget(
    'ios-simulator-x64',
    'ios',
    'x64',
    '15.0',
    appleSdk: 'iphonesimulator',
  ),
};

SdkTarget parseTarget(List<String> arguments) {
  final values = arguments
      .where((argument) => argument.startsWith('--target='))
      .map((argument) => argument.substring('--target='.length))
      .toList();
  if (values.length != 1 || !sdkTargets.containsKey(values.single)) {
    throw ArgumentError('Expected --target=<${sdkTargets.keys.join('|')}>');
  }
  return sdkTargets[values.single]!;
}
