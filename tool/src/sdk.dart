import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'target.dart';

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

Directory androidLlvmPrebuilt() {
  final ndk = Platform.environment['ANDROID_NDK_HOME'];
  if (ndk == null) throw StateError('ANDROID_NDK_HOME is required');
  final hosts = Directory(p.join(ndk, 'toolchains', 'llvm', 'prebuilt'))
      .listSync()
      .whereType<Directory>()
      .toList();
  if (hosts.length != 1) throw StateError('Expected one Android NDK host');
  return hosts.single;
}

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
Directory newStage(Directory root, String engine, SdkTarget target) {
  final stage = Directory(
    p.join(root.path, 'build', 'sdk', '$engine-${target.id}'),
  );
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  return stage;
}

Future<List<String>> stageLibraries(
  Directory stage,
  List<File> inputs,
  SdkTarget target,
) async {
  final files = [...inputs];
  if (target.os == 'android') {
    final triple = switch (target.architecture) {
      'arm32' => 'arm-linux-androideabi',
      'arm64' => 'aarch64-linux-android',
      'x64' => 'x86_64-linux-android',
      _ => throw StateError('Unsupported Android architecture'),
    };
    files.add(
      File(
        p.join(
          androidLlvmPrebuilt().path,
          'sysroot',
          'usr',
          'lib',
          triple,
          'libc++_shared.so',
        ),
      ),
    );
  }
  final libraries = <String>[];
  final names = <String>{};
  final installNames = <String, String>{};
  for (final file in files) {
    final name = p.basename(file.path);
    if (!file.existsSync() || !names.add(name)) {
      throw StateError('Missing or duplicate SDK library: ${file.path}');
    }
    if (target.isApple) {
      final oldId = await command('otool', ['-D', file.path], capture: true);
      installNames[oldId.split('\n').last.trim()] = '@rpath/$name';
    }
    final relative = 'lib/$name';
    final out = File(p.join(stage.path, relative))
      ..parent.createSync(recursive: true);
    file.copySync(out.path);
    libraries.add(relative);
    if (target.os == 'windows') {
      final base = p.basenameWithoutExtension(name);
      final importLibrary = [
        File(p.join(file.parent.path, '$base.lib')),
        File(p.join(file.parent.path, '$name.lib')),
      ].where((candidate) => candidate.existsSync()).firstOrNull;
      if (importLibrary == null) {
        throw StateError('Missing Windows import library for $name');
      }
      importLibrary.copySync(p.join(stage.path, 'lib', '$base.lib'));
    }
  }
  for (final relative in libraries) {
    final file = File(p.join(stage.path, relative));
    final deps = await libraryDependencies(file, target);
    final changes = <String>[];
    for (final dep in deps) {
      if (_systemLibrary(dep, target)) continue;
      if (!names.any(
            (name) => name.toLowerCase() == p.basename(dep).toLowerCase(),
          ) &&
          !installNames.containsKey(dep)) {
        throw StateError('Unbundled SDK dependency: $dep');
      }
      if (target.isApple) {
        changes.addAll([
          '-change',
          dep,
          installNames[dep] ?? '@rpath/${p.basename(dep)}',
        ]);
      }
    }
    if (target.isApple) {
      await command('install_name_tool', [
        '-id',
        '@rpath/${p.basename(relative)}',
        ...changes,
        file.path,
      ]);
      await command('codesign', ['--force', '--sign', '-', file.path]);
    } else if (target.os == 'linux' || target.os == 'android') {
      await command('patchelf', ['--set-rpath', r'$ORIGIN', file.path]);
    }
  }
  return libraries;
}

bool _systemLibrary(String value, SdkTarget target) {
  if (target.isApple) {
    return value.startsWith('/usr/lib/') ||
        value.startsWith('/System/Library/');
  }
  final name = p.basename(value).toLowerCase();
  if (target.os == 'windows') {
    return name.startsWith('api-ms-win-') ||
        name.startsWith('ext-ms-win-') ||
        const {
          'kernel32.dll',
          'user32.dll',
          'advapi32.dll',
          'ole32.dll',
          'shell32.dll',
          'ucrtbase.dll',
          'vcruntime140.dll',
          'vcruntime140_1.dll',
          'msvcp140.dll',
        }.contains(name);
  }
  if (target.os == 'android') {
    return const {
      'libc.so',
      'libm.so',
      'libdl.so',
      'liblog.so',
      'libandroid.so',
      'libz.so',
      'libstdc++.so',
    }.contains(name);
  }
  return const {
    'libc.so.6',
    'libm.so.6',
    'libdl.so.2',
    'libpthread.so.0',
    'librt.so.1',
    'libgcc_s.so.1',
    'libstdc++.so.6',
    'ld-linux-x86-64.so.2',
    'ld-linux-aarch64.so.1',
  }.contains(name);
}

Future<List<String>> libraryDependencies(File file, SdkTarget target) async {
  if (target.isApple) {
    final output = await command('otool', ['-L', file.path], capture: true);
    return output
        .split('\n')
        .skip(1)
        .map((s) => s.trim().split(' (compatibility version ').first)
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (target.os == 'windows') {
    final output = await command('dumpbin', [
      '/DEPENDENTS',
      file.path,
    ], capture: true);
    return RegExp(r'(?im)^\s*([\w.-]+\.dll)\s*$')
        .allMatches(output)
        .map((m) => m.group(1)!)
        .toList();
  }
  final output = await command('readelf', ['-d', file.path], capture: true);
  return RegExp(r'\(NEEDED\).*\[([^\]]+)\]')
      .allMatches(output)
      .map((m) => m.group(1)!)
      .toList();
}

String cmakeQuote(String s) =>
    '"${s.replaceAll('\\', '/').replaceAll('"', '\\"')}"';

void writeCmakeConfig(
  Directory stage,
  String engine,
  List<String> libraries, {
  required SdkTarget sdkTarget,
  List<String> defines = const [],
  int cxxStandard = 17,
}) {
  final config = File(p.join(stage.path, 'cmake', 'FlaxEngineSDKConfig.cmake'))
    ..parent.createSync(recursive: true);
  final system = switch (sdkTarget.os) {
    'macos' => 'Darwin',
    'ios' => 'iOS',
    'android' => 'Android',
    'linux' => 'Linux',
    'windows' => 'Windows',
    _ => throw StateError('Unknown SDK OS: ${sdkTarget.os}'),
  };
  final content = StringBuffer(
    '''# Generated relocatable engine SDK. No Flax ABI is included.
get_filename_component(_flax_sdk "\${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "$system")
  message(FATAL_ERROR "This engine SDK targets ${sdkTarget.id}")
endif()
''',
  );
  if (sdkTarget.isApple) {
    final arch = sdkTarget.architecture == 'x64' ? 'x86_64' : 'arm64';
    content.writeln(
      '''if(CMAKE_OSX_ARCHITECTURES AND NOT CMAKE_OSX_ARCHITECTURES STREQUAL "$arch")
  message(FATAL_ERROR "This engine SDK requires $arch")
endif()
if(CMAKE_OSX_DEPLOYMENT_TARGET AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS "${sdkTarget.minimumVersion}")
  message(FATAL_ERROR "This engine SDK requires ${sdkTarget.minimumVersion} or newer")
endif()''',
    );
    if (sdkTarget.appleSdk != null) {
      content.writeln(
        '''string(TOLOWER "\${CMAKE_OSX_SYSROOT}" _flax_sdk_sysroot)
if(_flax_sdk_sysroot AND NOT _flax_sdk_sysroot MATCHES "${sdkTarget.appleSdk}")
  message(FATAL_ERROR "This engine SDK requires ${sdkTarget.appleSdk}")
endif()''',
      );
    }
  } else if (sdkTarget.os == 'android') {
    content.writeln(
      '''if(NOT ANDROID_ABI STREQUAL "${sdkTarget.androidAbi}" OR ANDROID_PLATFORM_LEVEL LESS 24)
  message(FATAL_ERROR "This engine SDK requires ${sdkTarget.androidAbi} and API 24+")
endif()''',
    );
  } else {
    final processors = sdkTarget.architecture == 'x64'
        ? 'x86_64|AMD64|amd64'
        : 'aarch64|arm64|ARM64';
    content.writeln('''if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^($processors)\$")
  message(FATAL_ERROR "This engine SDK requires ${sdkTarget.architecture}")
endif()''');
  }
  final targets = <String>[];
  for (var i = 0; i < libraries.length; i++) {
    final target = 'FlaxEngineSDK::${engine}_$i';
    targets.add(target);
    final name = p.basename(libraries[i]);
    content.writeln(
      'if(NOT TARGET $target)\n'
              '  add_library($target SHARED IMPORTED)\n'
              '  set_target_properties($target PROPERTIES\n'
              '    IMPORTED_LOCATION "\${_flax_sdk}/${libraries[i]}"\n' +
          (sdkTarget.os == 'windows'
              ? '    IMPORTED_IMPLIB "\${_flax_sdk}/lib/${p.basenameWithoutExtension(name)}.lib"\n'
              : '    IMPORTED_SONAME "${sdkTarget.isApple ? '@rpath/' : ''}$name"\n') +
          '  )\nendif()',
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
  SdkTarget target,
) async {
  final files = <String, String>{};
  final inputs =
      stage
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in inputs) {
    files[p.relative(file.path, from: stage.path).replaceAll('\\', '/')] =
        await digestFile(file);
  }
  final dependencies = <String, List<String>>{
    for (final library in libraries)
      library: await libraryDependencies(
        File(p.join(stage.path, library)),
        target,
      ),
  };
  writeJson(p.join(stage.path, 'manifest.json'), {
    'schemaVersion': 3,
    'sdkVersion': readJson(p.join(root.path, 'runtime.json'))['runtimeVersion'],
    'engine': engine,
    'target': target.id,
    'os': target.os,
    'architecture': target.architecture,
    'minimumOSVersion': target.minimumVersion,
    if (target.appleSdk != null) 'appleSdk': target.appleSdk,
    if (target.minimumGlibc != null) 'minimumGlibcVersion': target.minimumGlibc,
    'libraries': libraries,
    'dynamicDependencies': dependencies,
    if (target.os == 'windows')
      'importLibraries': {
        for (final library in libraries)
          library: 'lib/${p.basenameWithoutExtension(library)}.lib',
      },
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
  final target = sdkTargets[manifest['target']];
  if (manifest['schemaVersion'] != 3 ||
      target == null ||
      manifest['os'] != target.os ||
      manifest['architecture'] != target.architecture ||
      manifest['minimumOSVersion'] != target.minimumVersion ||
      manifest['appleSdk'] != target.appleSdk ||
      manifest['minimumGlibcVersion'] != target.minimumGlibc ||
      manifest.containsKey('abiVersion') ||
      manifest.containsKey('entrySymbol')) {
    throw StateError('Invalid engine SDK target or schema');
  }
  final files = Map<String, String>.from(manifest['files'] as Map);
  for (final entry in files.entries) {
    if (p.posix.isAbsolute(entry.key) ||
        p.posix.split(entry.key).contains('..')) {
      throw StateError('Unsafe SDK path: ${entry.key}');
    }
    await requireDigest(File(p.join(stage.path, entry.key)), entry.value);
  }
  final libraries = (manifest['libraries'] as List).cast<String>();
  final declaredDependencies = Map<String, dynamic>.from(
    manifest['dynamicDependencies'] as Map,
  );
  if (libraries.isEmpty || !files.containsKey(manifest['cmakeConfig'])) {
    throw StateError('Incomplete SDK manifest');
  }
  final names = libraries.map(p.basename).toSet();
  for (final library in libraries) {
    if (!files.containsKey(library))
      throw StateError('Unhashed library: $library');
    final file = File(p.join(stage.path, library));
    await _verifyArchitecture(file, target);
    final actualDependencies = await libraryDependencies(file, target);
    if (declaredDependencies[library] is! List ||
        (declaredDependencies[library] as List).cast<String>().join('\n') !=
            actualDependencies.join('\n')) {
      throw StateError('Dynamic dependencies changed in $library');
    }
    for (final dep in actualDependencies) {
      if (!_systemLibrary(dep, target) &&
          !names.any(
            (name) => name.toLowerCase() == p.basename(dep).toLowerCase(),
          )) {
        throw StateError('Unbundled dependency in $library: $dep');
      }
    }
    if (target.os == 'windows') {
      final imports = Map<String, String>.from(
        manifest['importLibraries'] as Map,
      );
      if (!files.containsKey(imports[library])) {
        throw StateError('Missing import library for $library');
      }
    }
    final exports = target.os == 'windows'
        ? await command('dumpbin', ['/EXPORTS', file.path], capture: true)
        : await command(
            'nm',
            target.isApple
                ? ['-gUj', file.path]
                : ['-D', '--defined-only', file.path],
            capture: true,
          );
    if (exports.contains('flax_hermes_get_api') ||
        exports.contains('flax_v8_get_api')) {
      throw StateError('Engine SDK must not contain Flax ABI symbols');
    }
    if (target.minimumGlibc != null) {
      final versions = await command('readelf', [
        '--version-info',
        file.path,
      ], capture: true);
      final maximum = target.minimumGlibc!.split('.').map(int.parse).toList();
      for (final match in RegExp(r'GLIBC_(\d+)\.(\d+)').allMatches(versions)) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        if (major > maximum[0] || major == maximum[0] && minor > maximum[1]) {
          throw StateError(
            'GLIBC baseline exceeded in $library: $major.$minor',
          );
        }
      }
    }
  }
}

Future<void> _verifyArchitecture(File file, SdkTarget target) async {
  if (target.isApple) {
    final actual = await command('lipo', ['-archs', file.path], capture: true);
    final expected = target.architecture == 'x64' ? 'x86_64' : 'arm64';
    if (actual != expected)
      throw StateError('Wrong architecture: ${file.path}');
    final kind = await command('xcrun', [
      'vtool',
      '-show-build',
      file.path,
    ], capture: true);
    final platform = RegExp(r'platform\s+(IOSSIMULATOR|IOS)\b')
        .firstMatch(kind)
        ?.group(1);
    if (target.os == 'ios' &&
        platform != (target.appleSdk == 'iphoneos' ? 'IOS' : 'IOSSIMULATOR')) {
      throw StateError('Wrong iOS SDK in ${file.path}: found $platform');
    }
    return;
  }
  if (target.os == 'windows') {
    final headers = await command('dumpbin', [
      '/HEADERS',
      file.path,
    ], capture: true);
    final machine = target.architecture == 'x64'
        ? '8664 machine'
        : 'AA64 machine';
    if (!headers.toUpperCase().contains(machine.toUpperCase())) {
      throw StateError('Wrong PE machine in ${file.path}');
    }
    return;
  }
  final headers = await command('readelf', ['-h', file.path], capture: true);
  final machine = switch (target.architecture) {
    'arm32' => 'ARM',
    'arm64' => 'AArch64',
    _ => 'Advanced Micro Devices X86-64',
  };
  if (!headers.contains(machine))
    throw StateError('Wrong ELF machine in ${file.path}');
}
