import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const sdkTarget = 'macos-arm64';
const sdkMinimumOS = '15.0';

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void writeJson(String path, Object value) {
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

Future<String> digestFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> requireDigest(File file, String expected) async {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected) ||
      !file.existsSync() ||
      await digestFile(file) != expected) {
    throw StateError('Checksum mismatch: ${file.path}');
  }
}

Future<String> command(
  String executable,
  List<String> args, {
  String? directory,
  Map<String, String>? environment,
  bool capture = false,
}) async {
  stdout.writeln('> $executable ${args.join(' ')}');
  if (capture) {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: directory,
      environment: environment,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        args,
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    return result.stdout.toString().trim();
  }
  final process = await Process.start(
    executable,
    args,
    workingDirectory: directory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0)
    throw ProcessException(executable, args, 'Command failed', code);
  return '';
}

int buildJobs() {
  final value = int.tryParse(Platform.environment['FLAX_BUILD_JOBS'] ?? '2');
  if (value == null || value < 1) {
    throw ArgumentError('FLAX_BUILD_JOBS must be a positive integer');
  }
  return value;
}

Directory sourceCache(Directory engine) => Directory(
  Platform.environment['FLAX_ENGINE_SOURCE_CACHE'] ??
      p.join(engine.path, '.cache', 'native'),
)..createSync(recursive: true);

void copyTree(
  Directory source,
  Directory destination, {
  bool Function(File)? include,
}) {
  if (!source.existsSync())
    throw StateError('Missing SDK input: ${source.path}');
  for (final item in source.listSync(recursive: true, followLinks: false)) {
    if (item is! File || (include != null && !include(item))) continue;
    final file = File(
      p.join(destination.path, p.relative(item.path, from: source.path)),
    );
    file.parent.createSync(recursive: true);
    item.copySync(file.path);
  }
}

void copyHeaders(Directory source, Directory destination) => copyTree(
  source,
  destination,
  include: (f) =>
      const ['.h', '.hpp', '.inc', '.def'].contains(p.extension(f.path)),
);

void copyNotices(Directory source, Directory destination) {
  copyTree(
    source,
    destination,
    include: (file) {
      final name = p.basename(file.path).toLowerCase();
      return (name.startsWith('license') ||
              name.startsWith('copying') ||
              name.startsWith('notice')) &&
          const [
            '',
            '.txt',
            '.md',
            '.rst',
            '.html',
          ].contains(p.extension(name));
    },
  );
}

/// A new stage is disposable; previously verified archives are never rewritten.
Directory newStage(Directory root, String engine) {
  final stage = Directory(
    p.join(root.path, 'build', 'sdk', '$engine-$sdkTarget'),
  );
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  return stage;
}

Future<List<String>> stageLibraries(Directory stage, List<File> inputs) async {
  final libraries = <String>[];
  final names = <String>{};
  final installNames = <String, String>{};
  for (final file in inputs) {
    final name = p.basename(file.path);
    if (!file.existsSync() || !names.add(name)) {
      throw StateError('Missing or duplicate SDK library: ${file.path}');
    }
    final oldId = await command('otool', ['-D', file.path], capture: true);
    installNames[oldId.split('\n').last.trim()] = '@rpath/$name';
    final relative = 'lib/$name';
    final out = File(p.join(stage.path, relative))
      ..parent.createSync(recursive: true);
    file.copySync(out.path);
    libraries.add(relative);
  }
  for (final relative in libraries) {
    final file = File(p.join(stage.path, relative));
    final deps = await libraryDependencies(file);
    final changes = <String>[];
    for (final dep in deps) {
      if (_systemLibrary(dep)) continue;
      final replacement =
          installNames[dep] ??
          (names.contains(p.basename(dep))
              ? '@rpath/${p.basename(dep)}'
              : null);
      if (replacement == null)
        throw StateError('Unbundled SDK dependency: $dep');
      changes.addAll(['-change', dep, replacement]);
    }
    await command('install_name_tool', [
      '-id',
      '@rpath/${p.basename(relative)}',
      ...changes,
      file.path,
    ]);
    await command('codesign', ['--force', '--sign', '-', file.path]);
  }
  return libraries;
}

bool _systemLibrary(String value) =>
    value.startsWith('/usr/lib/') || value.startsWith('/System/Library/');

Future<List<String>> libraryDependencies(File file) async {
  final output = await command('otool', ['-L', file.path], capture: true);
  return output
      .split('\n')
      .skip(1)
      .map((s) => s.trim().split(' (compatibility version ').first)
      .where((s) => s.isNotEmpty)
      .toList();
}

String cmakeQuote(String s) =>
    '"${s.replaceAll('\\', '/').replaceAll('"', '\\"')}"';

void writeCmakeConfig(
  Directory stage,
  String engine,
  List<String> libraries, {
  List<String> defines = const [],
  int cxxStandard = 17,
}) {
  final config = File(p.join(stage.path, 'cmake', 'FlaxEngineSDKConfig.cmake'))
    ..parent.createSync(recursive: true);
  final content = StringBuffer(
    r'''# Generated relocatable engine SDK. No Flax ABI is included.
get_filename_component(_flax_sdk "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  message(FATAL_ERROR "This engine SDK targets macOS arm64 only")
endif()
if(CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
  message(FATAL_ERROR "This engine SDK requires arm64")
endif()
if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  message(FATAL_ERROR "This SDK requires Clang with Apple's libc++")
endif()
if(CMAKE_OSX_DEPLOYMENT_TARGET AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS "15.0")
  message(FATAL_ERROR "This engine SDK requires macOS 15.0 or newer")
endif()
''',
  );
  final targets = <String>[];
  for (var i = 0; i < libraries.length; i++) {
    final target = 'FlaxEngineSDK::${engine}_$i';
    targets.add(target);
    content.writeln(
      'if(NOT TARGET $target)\n'
      '  add_library($target SHARED IMPORTED)\n'
      '  set_target_properties($target PROPERTIES\n'
      '    IMPORTED_LOCATION "\${_flax_sdk}/${libraries[i]}"\n'
      '    IMPORTED_SONAME "@rpath/${p.basename(libraries[i])}")\nendif()',
    );
  }
  final target = 'FlaxEngineSDK::$engine';
  content.writeln(
    'if(NOT TARGET $target)\n'
    '  add_library($target INTERFACE IMPORTED)\n'
    '  set_target_properties($target PROPERTIES\n'
    '    INTERFACE_INCLUDE_DIRECTORIES "\${_flax_sdk}/include"\n'
    '    INTERFACE_COMPILE_FEATURES "cxx_std_$cxxStandard"\n'
    '    INTERFACE_COMPILE_DEFINITIONS ${cmakeQuote(defines.join(';'))}\n'
    '    INTERFACE_LINK_LIBRARIES ${cmakeQuote(targets.join(';'))})\nendif()',
  );
  config.writeAsStringSync(content.toString());
}

Future<void> finishSdk(
  Directory root,
  Directory stage,
  String engine,
  List<String> libraries,
  Map<String, Object?> metadata,
) async {
  final files = <String, String>{};
  final inputs =
      stage
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in inputs) {
    files[p.relative(file.path, from: stage.path)] = await digestFile(file);
  }
  writeJson(p.join(stage.path, 'manifest.json'), {
    'schemaVersion': 2,
    'sdkVersion': readJson(p.join(root.path, 'runtime.json'))['runtimeVersion'],
    'engine': engine,
    'os': 'macos',
    'architecture': 'arm64',
    'minimumOSVersion': sdkMinimumOS,
    'libraries': libraries,
    'cmakeConfig': 'cmake/FlaxEngineSDKConfig.cmake',
    'cmakeTarget': 'FlaxEngineSDK::$engine',
    'metadata': metadata,
    'files': files,
  });
  await verifySdk(stage);
  stdout.writeln('Prepared standalone $engine SDK: ${stage.path}');
}

Future<void> verifySdk(Directory stage) async {
  final manifest = readJson(p.join(stage.path, 'manifest.json'));
  if (manifest['schemaVersion'] != 2 ||
      manifest['os'] != 'macos' ||
      manifest['architecture'] != 'arm64' ||
      manifest.containsKey('abiVersion') ||
      manifest.containsKey('entrySymbol')) {
    throw StateError('Not a macOS arm64 engine SDK v2');
  }
  final files = Map<String, String>.from(manifest['files'] as Map);
  for (final entry in files.entries) {
    if (p.isAbsolute(entry.key) || p.split(entry.key).contains('..')) {
      throw StateError('Unsafe SDK path: ${entry.key}');
    }
    await requireDigest(File(p.join(stage.path, entry.key)), entry.value);
  }
  final libraries = (manifest['libraries'] as List).cast<String>();
  if (libraries.isEmpty || !files.containsKey(manifest['cmakeConfig'])) {
    throw StateError('Incomplete SDK manifest');
  }
  final names = libraries.map(p.basename).toSet();
  for (final library in libraries) {
    if (!files.containsKey(library))
      throw StateError('Unhashed library: $library');
    final file = File(p.join(stage.path, library));
    if (await command('lipo', ['-archs', file.path], capture: true) !=
        'arm64') {
      throw StateError('Wrong SDK architecture: $library');
    }
    for (final dep in await libraryDependencies(file)) {
      if (!_systemLibrary(dep) &&
          !(dep.startsWith('@rpath/') && names.contains(p.basename(dep)))) {
        throw StateError('Unbundled dependency in $library: $dep');
      }
    }
    final exports = await command('nm', ['-gUj', file.path], capture: true);
    if (exports.contains('_flax_hermes_get_api') ||
        exports.contains('_flax_v8_get_api')) {
      throw StateError('Engine SDK must not contain Flax ABI symbols');
    }
  }
}
