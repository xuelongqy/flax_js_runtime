import 'dart:io';

import 'src/sdk.dart';
import 'src/target.dart';

void main() {
  final manifest = <String, dynamic>{
    'libraries': [
      'lib/hermesvm.dll',
      'lib/MSVCP140.dll',
      'lib/vcruntime140.dll',
    ],
    'runtimeLibraries': ['lib/MSVCP140.dll', 'lib/vcruntime140.dll'],
    'importLibraries': {'lib/hermesvm.dll': 'lib/hermesvm.lib'},
    'files': {
      'lib/hermesvm.dll': 'hashed',
      'lib/hermesvm.lib': 'hashed',
      'lib/MSVCP140.dll': 'hashed',
      'lib/vcruntime140.dll': 'hashed',
    },
  };
  verifyWindowsLibraries(manifest);
  for (final invalid in [
    {...manifest, 'runtimeLibraries': []},
    {
      ...manifest,
      'runtimeLibraries': ['lib/MSVCP140.dll', 'lib/MSVCP140.dll'],
    },
    {...manifest, 'importLibraries': {}},
    {
      ...manifest,
      'importLibraries': {
        'lib/hermesvm.dll': 'lib/hermesvm.lib',
        'lib/MSVCP140.dll': 'lib/MSVCP140.lib',
      },
    },
  ]) {
    var rejected = false;
    try {
      verifyWindowsLibraries(invalid);
    } on StateError {
      rejected = true;
    }
    if (!rejected) throw StateError('Invalid Windows SDK accepted');
  }
  final stage = Directory.systemTemp.createTempSync('windows-sdk-contract-');
  try {
    writeCmakeConfig(
      stage,
      'hermes',
      (manifest['libraries'] as List).cast<String>(),
      sdkTarget: sdkTargets['windows-x64']!,
    );
    final config = File('${stage.path}/cmake/FlaxEngineSDKConfig.cmake')
        .readAsStringSync();
    if (!config.contains('hermesvm.lib') ||
        config.contains('MSVCP140') ||
        config.contains('vcruntime140')) {
      throw StateError('CMake must link the engine, not deployment DLLs');
    }
  } finally {
    stage.deleteSync(recursive: true);
  }
  stdout.writeln('Windows SDK runtime deployment contract passed.');
}
