import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/sdk.dart' as sdk;
import 'src/target.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3 ||
      !const ['hermes', 'v8'].contains(args[0]) ||
      !sdkTargets.containsKey(args[1])) {
    throw ArgumentError(
      'Usage: dart run tool/check_archive.dart '
      '<hermes|v8> <target> <extracted-sdk-directory>',
    );
  }
  final target = sdkTargets[args[1]]!;
  final root = Directory(p.absolute(args[2]));
  final manifest = sdk.readJson(p.join(root.path, 'manifest.json'));
  if (manifest['schemaVersion'] != 3 ||
      manifest['sdkVersion'] !=
          sdk.readJson('runtime.json')['runtimeVersion'] ||
      manifest['engine'] != args[0] ||
      manifest['target'] != target.id ||
      manifest['os'] != target.os ||
      manifest['architecture'] != target.architecture ||
      manifest['minimumOSVersion'] != target.minimumVersion ||
      manifest['appleSdk'] != target.appleSdk ||
      manifest['minimumGlibcVersion'] != target.minimumGlibc ||
      manifest.containsKey('abiVersion') ||
      manifest.containsKey('entrySymbol')) {
    throw StateError('SDK manifest does not match ${args[0]}/${target.id}');
  }
  final files = Map<String, String>.from(manifest['files'] as Map);
  if (files.isEmpty ||
      !files.containsKey(manifest['cmakeConfig']) ||
      manifest['cmakeTarget'] != 'FlaxEngineSDK::${args[0]}') {
    throw StateError('Incomplete SDK manifest');
  }
  for (final entry in files.entries) {
    if (p.posix.isAbsolute(entry.key) ||
        p.posix.split(entry.key).contains('..')) {
      throw StateError('Unsafe SDK member: ${entry.key}');
    }
    await sdk.requireDigest(File(p.join(root.path, entry.key)), entry.value);
  }
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is Link) throw StateError('SDK archive contains a link');
    if (entity is File) {
      final name = p.relative(entity.path, from: root.path);
      if (name != 'manifest.json' && !files.containsKey(name)) {
        throw StateError('Unlisted SDK file: $name');
      }
    }
  }
  final libraries = (manifest['libraries'] as List).cast<String>();
  if (libraries.isEmpty ||
      libraries.any((library) => !files.containsKey(library))) {
    throw StateError('Missing dynamic library');
  }
  final dependencies = Map<String, dynamic>.from(
    manifest['dynamicDependencies'] as Map,
  );
  if (dependencies.keys.toSet().difference(libraries.toSet()).isNotEmpty ||
      libraries.any((library) => dependencies[library] is! List)) {
    throw StateError('Incomplete dynamic dependency list');
  }
  if (target.os == 'windows') {
    final imports = Map<String, String>.from(
      manifest['importLibraries'] as Map,
    );
    if (libraries.any((library) => !files.containsKey(imports[library]))) {
      throw StateError('Missing Windows import library');
    }
  }
  stdout.writeln('Verified ${args[0]}/${target.id} SDK archive contents.');
}
