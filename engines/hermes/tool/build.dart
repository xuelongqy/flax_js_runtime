import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../../../tool/src/sdk.dart' as sdk;

import 'package:path/path.dart' as p;

Future<void> main() async {
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
    throw UnsupportedError('Native runtime verification requires macOS arm64.');
  }
  final package = Directory.fromUri(Platform.script.resolve('../'));
  final root = Directory.fromUri(Platform.script.resolve('../../../'));
  final input = jsonDecode(
    File(p.join(package.path, 'engine.json')).readAsStringSync(),
  ) as Map<String, Object?>;
  final upstream = input['upstream'] as Map<String, Object?>;
  final revision = upstream['revision'] as String;
  final cache = sdk.sourceCache(package);
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
    await sdk.requireDigest(partial, upstream['sha256'] as String);
    partial.renameSync(archive.path);
  }
  await sdk.requireDigest(archive, upstream['sha256'] as String);
  final source = Directory(p.join(cache.path, 'hermes-$revision'));
  final patches = (upstream['patches'] as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final patch in patches) {
    await sdk.requireDigest(
      File(p.join(package.path, 'patches', patch['file'] as String)),
      patch['sha256'] as String,
    );
  }
  final sourceStamp = '${upstream['sha256']}:${jsonEncode(patches)}';
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
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_OSX_ARCHITECTURES=arm64',
    '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
  ]);
  final jobs = sdk.buildJobs();
  await _run('cmake', [
    '--build',
    build,
    '--target',
    'flax_hermes_sdk_test',
    '--parallel',
    '$jobs',
  ]);
  await _run('ctest', ['--test-dir', build, '--output-on-failure']);
  await _prepareAssets(root, source, input, build);
}

Future<void> _prepareAssets(
  Directory root,
  Directory upstreamSource,
  Map<String, Object?> input,
  String build,
) async {
  final stage = sdk.newStage(root, 'hermes');
  final library = File(p.join(build, 'hermes', 'lib', 'libhermesvm.dylib'));
  final libraries = await sdk.stageLibraries(stage, [library]);
  sdk.copyHeaders(
    Directory(p.join(upstreamSource.path, 'public')),
    Directory(p.join(stage.path, 'include')),
  );
  sdk.copyHeaders(
    Directory(p.join(upstreamSource.path, 'API', 'hermes')),
    Directory(p.join(stage.path, 'include', 'hermes')),
  );
  sdk.copyHeaders(
    Directory(p.join(upstreamSource.path, 'API', 'jsi')),
    Directory(p.join(stage.path, 'include')),
  );
  sdk.copyNotices(upstreamSource, Directory(p.join(stage.path, 'notices')));
  sdk.writeCmakeConfig(stage, 'hermes', libraries);
  await sdk.finishSdk(root, stage, 'hermes', libraries, {
    'revision': (input['upstream'] as Map<String, Object?>)['revision'],
    'patches': (input['upstream'] as Map<String, Object?>)['patches'],
    'jit': false,
  });
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
