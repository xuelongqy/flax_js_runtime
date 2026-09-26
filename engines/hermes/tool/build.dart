import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
    throw UnsupportedError('Native runtime verification requires macOS arm64.');
  }
  final package = Directory.fromUri(Platform.script.resolve('../'));
  final core = Directory.fromUri(Platform.script.resolve('../../../abi/'));
  final input = jsonDecode(
    File(p.join(package.path, 'engine.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final upstream = input['upstream'] as Map<String, Object?>;
  final revision = upstream['revision'] as String;
  final cache = Directory(p.join(package.path, '.cache/native'))
    ..createSync(recursive: true);
  final archive = File(p.join(cache.path, 'source.tar.gz'));
  if (!archive.existsSync()) {
    final partial = File('${archive.path}.part');
    await _run('curl', [
      '--fail',
      '--location',
      '--retry',
      '2',
      '--output',
      partial.path,
      upstream['archive'] as String,
    ]);
    await _requireSha256(partial, upstream['sha256'] as String, 'Hermes archive');
    partial.renameSync(archive.path);
  }
  await _requireSha256(
    archive,
    upstream['sha256'] as String,
    'Cached Hermes archive',
  );
  final source = Directory(p.join(cache.path, 'hermes-$revision'));
  final patches = (upstream['patches'] as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final patch in patches) {
    await _requireSha256(
      File(p.join(package.path, 'patches', patch['file'] as String)),
      patch['sha256'] as String,
      'Hermes patch',
    );
  }
  final sourceStamp = '${input['sha256']}:${jsonEncode(patches)}';
  final stamp = File(p.join(source.path, '.flax-extracted'));
  if (!stamp.existsSync() || stamp.readAsStringSync() != sourceStamp) {
    if (source.existsSync()) source.deleteSync(recursive: true);
    await _run('tar', ['-xzf', archive.path, '-C', cache.path]);
    for (final patch in patches) {
      await _run('patch', [
        '-p1',
        '--batch',
        '--forward',
        '-i',
        p.join(package.path, 'patches', patch['file'] as String),
      ], directory: source.path);
    }
    stamp.writeAsStringSync(sourceStamp);
  }
  final build = p.join(package.path, 'build/native');
  await _run('cmake', [
    '-S',
    p.join(package.path, 'native'),
    '-B',
    build,
    '-G',
    'Ninja',
    '-DFLAX_HERMES_SOURCE=${source.path}',
    '-DFLAX_ABI_ROOT=${core.path}',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
  ]);
  final jobs = int.tryParse(Platform.environment['FLAX_BUILD_JOBS'] ?? '2');
  if (jobs == null || jobs < 1) {
    throw ArgumentError('FLAX_BUILD_JOBS must be a positive integer');
  }
  await _run('cmake', [
    '--build',
    build,
    '--target',
    'flax_runtime_test',
    '--parallel',
    '$jobs',
  ]);
  await _run('ctest', ['--test-dir', build, '--output-on-failure']);
  await _prepareAssets(package, core, source, input, build);
}

Directory _packageRoot(String uri) {
  final library = Isolate.resolvePackageUriSync(Uri.parse(uri));
  if (library == null) throw StateError('Cannot resolve $uri');
  return File.fromUri(library).parent.parent;
}

Future<void> _requireSha256(File file, String expected, String label) async {
  if ((await sha256.bind(file.openRead()).first).toString() != expected) {
    throw StateError('$label checksum mismatch; refusing to continue.');
  }
}

Future<void> _prepareAssets(
  Directory package,
  Directory core,
  Directory upstreamSource,
  Map<String, Object?> input,
  String build,
) async {
  final source = File(p.join(build, 'lib/libflax_hermes.dylib'));
  await _validateLibrary(source);
  final output = Directory(p.join(package.path, 'native/generated/macos_arm64'))
    ..createSync(recursive: true);
  final target = p.join(output.path, 'libflax_hermes.dylib');
  source.copySync('$target.tmp').renameSync(target);
  final abi = _abiVersion(core);
  final manifest = {
    'abiVersion': abi,
    'os': 'macos',
    'architecture': 'arm64',
    'minimumOSVersion': '15.0',
    'entrySymbol': 'flax_hermes_get_api',
    'hermesRevision': input['revision'],
    'patches': upstream['patches'],
    'sha256': (await sha256.bind(File(target).openRead()).first).toString(),
  };
  File(p.join(output.path, 'manifest.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  final notices = Directory(p.join(output.path, 'notices'));
  if (notices.existsSync()) notices.deleteSync(recursive: true);
  _copyNotices(upstreamSource, notices);
  _writeConsolidatedNotices(
    notices,
    File(p.join(package.path, 'THIRD_PARTY_NOTICES.txt')),
  );
  stdout.writeln('Prepared package-local Hermes assets and upstream notices.');
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
        dependency == '@rpath/libflax_hermes.dylib' ||
        dependency.startsWith('/usr/lib/') ||
        dependency.startsWith('/System/Library/')) {
      continue;
    }
    throw StateError('Unbundled native dependency: $dependency');
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
