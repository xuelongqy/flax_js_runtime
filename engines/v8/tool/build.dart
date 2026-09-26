import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<String> _output(
  String executable,
  List<String> arguments, {
  required String directory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: directory,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout.toString().trim();
}

Future<void> _checkout(String directory, String url, String revision) async {
  if (!Directory('$directory/.git').existsSync()) {
    Directory(directory).createSync(recursive: true);
    await _run('git', ['init', directory]);
    await _run('git', ['remote', 'add', 'origin', url], directory: directory);
  }
  final head = await Process.run('git', [
    'rev-parse',
    '--verify',
    'HEAD',
  ], workingDirectory: directory);
  if (head.exitCode != 0) {
    await _run('git', [
      'fetch',
      '--depth',
      '1',
      'origin',
      revision,
    ], directory: directory);
    await _run('git', ['checkout', '--detach', revision], directory: directory);
  }
  final actual = await _output('git', [
    'rev-parse',
    'HEAD',
  ], directory: directory);
  if (actual != revision) {
    throw StateError('Unexpected cached revision in $directory: $actual');
  }
}

String _quoted(String value) =>
    '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

Future<void> main() async {
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
    throw UnsupportedError('Native runtime verification requires macOS arm64.');
  }
  final package = Directory.fromUri(Platform.script.resolve('../'));
  final core = Directory.fromUri(Platform.script.resolve('../../../abi/'));
  final input = jsonDecode(
    File('${package.path}/engine.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final ninja = await _output('which', ['ninja'], directory: package.path);
  final hostTools = input['hostTools'] as Map<String, Object?>;
  final actualTools = {
    'cmake': (await _output('cmake', [
      '--version',
    ], directory: package.path)).split('\n').first.split(' ').last,
    'ninja': await _output(ninja, ['--version'], directory: package.path),
    'xcode': (await _output('xcodebuild', [
      '-version',
    ], directory: package.path)).split('\n').first.split(' ').last,
    'macosSdk': await _output('xcrun', [
      '--show-sdk-version',
    ], directory: package.path),
  };
  for (final entry in actualTools.entries) {
    if (entry.value != hostTools[entry.key]) {
      throw StateError(
        'V8 requires ${entry.key} ${hostTools[entry.key]}, found ${entry.value}',
      );
    }
  }
  final cache = '${package.path}/.cache/native';
  final source = '$cache/v8';
  final adapter = '$cache/adapter';
  final depot = '$cache/depot_tools';
  await _checkout(
    source,
    'https://chromium.googlesource.com/v8/v8.git',
    input['revision'] as String,
  );
  await _checkout(
    adapter,
    'https://github.com/microsoft/v8-jsi.git',
    input['adapterRevision'] as String,
  );
  await _checkout(
    depot,
    'https://chromium.googlesource.com/chromium/tools/depot_tools.git',
    input['depotToolsRevision'] as String,
  );
  await _run('git', ['diff', 'HEAD', '--exit-code'], directory: source);

  final patch = '${package.path}/patches/v8-jsi.patch';
  final reversed = await Process.run('git', [
    'apply',
    '--reverse',
    '--check',
    patch,
  ], workingDirectory: adapter);
  if (reversed.exitCode != 0) {
    await _run('git', ['diff', 'HEAD', '--exit-code'], directory: adapter);
    await _run('git', ['apply', '--check', patch], directory: adapter);
    await _run('git', ['apply', patch], directory: adapter);
  }
  final expectedPatch = File(patch).readAsStringSync().trim();
  final actualPatch = await _output('git', [
    'diff',
    'HEAD',
    '--binary',
  ], directory: adapter);
  if (actualPatch != expectedPatch) {
    throw StateError('Unexpected local changes in the cached V8 JSI adapter.');
  }

  // The JSI revision is pinned with the V8 adapter inputs.
  final jsiSource = '$cache/jsi';
  await _checkout(
    jsiSource,
    'https://github.com/facebook/hermes.git',
    input['jsiRevision'] as String,
  );

  await _run('git', ['diff', 'HEAD', '--exit-code'], directory: jsiSource);

  File('$cache/.gclient').writeAsStringSync(
    'solutions = ${jsonEncode([
      {
        'name': 'v8',
        'url': 'https://chromium.googlesource.com/v8/v8.git',
        'managed': false,
        'custom_deps': {'v8/agents/shared': null, 'v8/test/test262/data': null, 'v8/test/mozilla/data': null, 'v8/test/benchmarks/data': null, 'v8/tools/win': null},
        'custom_vars': <String, Object?>{},
      },
    ]).replaceAll('false', 'False').replaceAll('null', 'None')}\n',
  );
  final environment = {
    'DEPOT_TOOLS_UPDATE': '0',
    'PATH': '$depot:${Platform.environment['PATH'] ?? ''}',
  };
  await _run(
    '$depot/gclient',
    [
      'sync',
      '--no-history',
      '--nohooks',
      '--revision',
      'v8@${input['revision']}',
    ],
    directory: cache,
    environment: environment,
  );
  await _checkout(
    source,
    'https://chromium.googlesource.com/v8/v8.git',
    input['revision'] as String,
  );
  final args = input['gnArgs'] as String;
  final gn = '$source/buildtools/mac/gn';
  await _run(
    gn,
    ['gen', 'out/flax', '--args=$args'],
    directory: source,
    environment: environment,
  );
  final jobs = int.tryParse(Platform.environment['FLAX_BUILD_JOBS'] ?? '2');
  if (jobs == null || jobs < 1) {
    throw ArgumentError('FLAX_BUILD_JOBS must be positive');
  }
  await _run(
    ninja,
    ['-C', 'out/flax', '-j', '$jobs', 'v8_monolith'],
    directory: source,
    environment: environment,
    timeout: const Duration(hours: 2),
  );

  final defines =
      (await _output(gn, [
            'desc',
            'out/flax',
            ':v8_headers',
            'defines',
          ], directory: source))
          .split('\n')
          .where((line) => line.startsWith('V8_') || line.startsWith('CPPGC_'));
  // GN's monolith omits Rust companion archives. Use the pinned upstream link
  // graph, including its allocator shim, rather than guessing Temporal's deps.
  final link = File('$source/out/flax/obj/mksnapshot.ninja').readAsStringSync();
  final rust = link
      .split(RegExp(r'\s+'))
      .where(
        (word) =>
            word.endsWith('.rlib') ||
            word.endsWith('/liballoc_error_handler_impl.a'),
      )
      .toSet();
  if (rust.isEmpty) throw StateError('Missing V8 Rust link inputs');
  final libraries = [
    '$source/out/flax/obj/libv8_monolith.a',
    ...rust.map((name) => '$source/out/flax/$name'),
    '$source/third_party/llvm-build/Release+Asserts/lib/clang/23/lib/darwin/libclang_rt.osx.a',
  ];
  for (final library in libraries) {
    if (!File(library).existsSync()) {
      throw StateError('Missing V8 archive: $library');
    }
  }
  final inputs = '$cache/link-inputs.cmake';
  File(inputs).writeAsStringSync(
    [
      'set(FLAX_JSI_SOURCE ${_quoted('$jsiSource/API/jsi')})',
      'set(FLAX_V8_SOURCE ${_quoted(source)})',
      'set(FLAX_V8_ADAPTER ${_quoted(adapter)})',
      'set(FLAX_V8_DEFINES ${defines.map(_quoted).join(' ')})',
      'set(FLAX_V8_LIBRARIES ${libraries.map(_quoted).join(' ')})',
    ].join('\n'),
  );
  final build = p.join(package.path, 'build/native');
  await _run('cmake', [
    '-S',
    '${package.path}/native',
    '-B',
    build,
    '-G',
    'Ninja',
    '-DFLAX_V8_INPUTS=$inputs',
    '-DFLAX_ABI_ROOT=${core.path}',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_CXX_COMPILER=$source/third_party/llvm-build/Release+Asserts/bin/clang++',
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
  ]);
  await _run('cmake', [
    '--build',
    build,
    '--target',
    'flax_v8_runtime_test',
    'flax_v8_lifecycle_test',
    '--parallel',
    '$jobs',
  ]);
  await _run('ctest', ['--test-dir', build, '--output-on-failure']);
  await _prepareAssets(package, core, input, build, cache);
}

Directory _packageRoot(String uri) {
  final library = Isolate.resolvePackageUriSync(Uri.parse(uri));
  if (library == null) throw StateError('Cannot resolve $uri');
  return File.fromUri(library).parent.parent;
}

Future<void> _prepareAssets(
  Directory package,
  Directory core,
  Map<String, Object?> input,
  String build,
  String cache,
) async {
  final source = File(p.join(build, 'lib/libflax_v8.dylib'));
  await _validateLibrary(source);
  final output = Directory(p.join(package.path, 'native/generated/macos_arm64'))
    ..createSync(recursive: true);
  final target = p.join(output.path, 'libflax_v8.dylib');
  source.copySync('$target.tmp').renameSync(target);
  final manifest = {
    'abiVersion': _abiVersion(core),
    'os': 'macos',
    'architecture': 'arm64',
    'minimumOSVersion': '15.0',
    'entrySymbol': 'flax_v8_get_api',
    'v8Revision': input['revision'],
    'adapterRevision': input['adapterRevision'],
    'jsiRevision': input['jsiRevision'],
    'jit': true,
    'jitVerification': {
      'environment': 'FLAX_VERIFY_V8_JIT',
      'marker': 'FLAX_V8_JIT: machine code generated',
    },
    'gnArgs': input['gnArgs'],
    'engineVersion': input['version'],
    'hostTools': input['hostTools'],
    'depotToolsRevision': input['depotToolsRevision'],
    'adapterPatchSha256':
        (await sha256
                .bind(
                  File(p.join(package.path, 'patches/v8-jsi.patch')).openRead(),
                )
                .first)
            .toString(),
    'sha256': (await sha256.bind(File(target).openRead()).first).toString(),
  };
  File(p.join(output.path, 'manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  final notices = Directory(p.join(output.path, 'notices'));
  if (notices.existsSync()) notices.deleteSync(recursive: true);
  for (final entry in {
    'v8': Directory(p.join(cache, 'v8')),
    'v8-jsi': Directory(p.join(cache, 'adapter')),
    'jsi': Directory(p.join(cache, 'jsi/API/jsi')),
  }.entries) {
    _copyNotices(entry.value, Directory(p.join(notices.path, entry.key)));
  }
  Directory(p.join(notices.path, 'jsi')).createSync(recursive: true);
  File(p.join(cache, 'jsi/LICENSE'))
      .copySync(p.join(notices.path, 'jsi/LICENSE'));
  _writeConsolidatedNotices(
    notices,
    File(p.join(package.path, 'THIRD_PARTY_NOTICES.txt')),
  );
  stdout.writeln('Prepared package-local V8 assets and upstream notices.');
}

int _abiVersion(Directory core) {
  final header = File(p.join(core.path, 'include/flax/runtime.h'))
      .readAsStringSync();
  return int.parse(
    RegExp(r'#define FLAX_ABI_VERSION (\d+)').firstMatch(header)!.group(1)!,
  );
}

Future<void> _validateLibrary(File library) async {
  final architecture = await Process.run('lipo', ['-archs', library.path]);
  if (architecture.exitCode != 0 ||
      architecture.stdout.toString().trim() != 'arm64') {
    throw StateError('Expected a macOS arm64 dynamic library.');
  }
  final dependencies = await Process.run('otool', ['-L', library.path]);
  if (dependencies.exitCode != 0) {
    throw StateError(dependencies.stderr.toString());
  }
  for (final line in dependencies.stdout.toString().split('\n').skip(1)) {
    final dependency = line.trim().split(' ').first;
    if (dependency.isEmpty ||
        dependency == '@rpath/libflax_v8.dylib' ||
        dependency.startsWith('/usr/lib/') ||
        dependency.startsWith('/System/Library/')) {
      continue;
    }
    throw StateError('Unbundled native dependency: $dependency');
  }
  final exports = await Process.run('nm', ['-gUj', library.path]);
  if (exports.exitCode != 0 ||
      exports.stdout.toString().trim() != '_flax_v8_get_api') {
    throw StateError('V8 must export only its versioned C bootstrap');
  }
}

void _copyNotices(Directory source, Directory target) {
  const sourceOrBinaryExtensions = {
    '.a',
    '.c',
    '.cc',
    '.cpp',
    '.dart',
    '.dylib',
    '.exe',
    '.h',
    '.hpp',
    '.js',
    '.mjs',
    '.o',
    '.py',
    '.sh',
    '.so',
    '.ts',
  };
  for (final entry
      in source
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()) {
    final name = p.basename(entry.path).toLowerCase();
    if (!(name.startsWith('license') ||
            name.startsWith('copying') ||
            name.startsWith('notice')) ||
        sourceOrBinaryExtensions.contains(p.extension(name))) {
      continue;
    }
    final destination = File(
      p.join(target.path, p.relative(entry.path, from: source.path)),
    );
    destination.parent.createSync(recursive: true);
    entry.copySync(destination.path);
  }
}

void _writeConsolidatedNotices(Directory source, File output) {
  final groups = <String, ({String content, List<String> paths})>{};
  final files = source.listSync(recursive: true).whereType<File>().toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  for (final file in files) {
    final bytes = file.readAsBytesSync();
    final digest = sha256.convert(bytes).toString();
    final relative = p.relative(file.path, from: source.path);
    final existing = groups[digest];
    if (existing == null) {
      groups[digest] = (
        content: utf8.decode(bytes, allowMalformed: true).trimRight(),
        paths: [relative],
      );
    } else {
      existing.paths.add(relative);
    }
  }
  final content = StringBuffer(
    'Generated from the pinned engine source. Duplicate license texts are grouped.\n',
  );
  for (final group in groups.values) {
    content
      ..writeln(
        '\n================================================================================',
      )
      ..writeln('Source files:')
      ..writeln(group.paths.map((path) => '  $path').join('\n'))
      ..writeln('\n${group.content}');
  }
  output.writeAsStringSync('${content.toString().trimRight()}\n');
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  String? directory,
  Map<String, String>? environment,
  Duration timeout = const Duration(hours: 2),
}) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      throw TimeoutException('Command timed out: $executable', timeout);
    },
  );
  if (code != 0) {
    throw ProcessException(executable, arguments, 'Command failed', code);
  }
}
