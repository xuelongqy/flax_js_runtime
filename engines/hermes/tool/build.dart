import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../tool/src/sdk.dart' as sdk;
import '../../../tool/src/target.dart';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final target = parseTarget(args)..requireBuildHost();
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
      await _run('git', [
        'apply',
        '--unsafe-paths',
        p.join(package.path, 'patches', patch['file'] as String),
      ], directory: source.path);
    }
    stamp.writeAsStringSync(sourceStamp);
  }
  final build = p.join(package.path, 'build', 'native', target.id);
  final flags = <String>[];
  if (target.isApple) {
    final iosSdk = target.appleSdk == null
        ? null
        : await sdk.command('xcrun', [
            '--sdk',
            target.appleSdk!,
            '--show-sdk-path',
          ], capture: true);
    flags.addAll([
      '-DCMAKE_OSX_ARCHITECTURES=${target.architecture == 'x64' ? 'x86_64' : 'arm64'}',
      '-DCMAKE_OSX_DEPLOYMENT_TARGET=${target.minimumVersion}',
      '-DHERMES_APPLE_TARGET_PLATFORM=${target.appleSdk ?? ''}',
      if (target.os == 'ios') '-DCMAKE_SYSTEM_NAME=iOS',
      if (iosSdk != null) '-DCMAKE_OSX_SYSROOT=$iosSdk',
    ]);
  }
  if (target.os == 'android') {
    final ndk = Platform.environment['ANDROID_NDK_HOME'];
    if (ndk == null) throw StateError('ANDROID_NDK_HOME is required');
    flags.addAll([
      '-DCMAKE_TOOLCHAIN_FILE=$ndk/build/cmake/android.toolchain.cmake',
      '-DANDROID_ABI=${target.androidAbi}',
      '-DANDROID_PLATFORM=android-24',
      '-DHERMES_IS_ANDROID=ON',
    ]);
  }
  if (target.isLinuxArm64Cross) {
    flags.addAll([
      '-DCMAKE_SYSTEM_NAME=Linux',
      '-DCMAKE_SYSTEM_PROCESSOR=aarch64',
      '-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc',
      '-DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++',
    ]);
  }
  if (target.isMobile || target.isLinuxArm64Cross) {
    final hostBuild = p.join(package.path, 'build', 'host-hermesc');
    final import = File(p.join(hostBuild, 'ImportHostCompilers.cmake'));
    if (!import.existsSync()) {
      await _run('cmake', [
        '-S',
        source.path,
        '-B',
        hostBuild,
        '-G',
        'Ninja',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DHERMES_ENABLE_TEST_SUITE=OFF',
        '-DHERMES_ENABLE_INTL=OFF',
        '-DHERMES_UNICODE_LITE=ON',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
      ]);
      await _run('cmake', [
        '--build',
        hostBuild,
        '--target',
        'hermesc',
        'shermes',
        '--parallel',
        '${sdk.buildJobs()}',
      ]);
    }
    if (!import.existsSync())
      throw StateError('Missing host Hermes compiler export');
    flags.add('-DIMPORT_HOST_COMPILERS=${import.path}');
  }
  await _run('cmake', [
    '-S',
    p.join(package.path, 'native'),
    '-B',
    build,
    '-G',
    'Ninja',
    '-DFLAX_HERMES_SOURCE=${source.path}',
    '-DCMAKE_BUILD_TYPE=Release',
    ...flags,
    '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
  ]);
  final jobs = sdk.buildJobs();
  await _run('cmake', [
    '--build',
    build,
    '--target',
    target.isMobile || target.isLinuxArm64Cross
        ? 'hermesvm'
        : 'flax_hermes_sdk_test',
    '--parallel',
    '$jobs',
  ]);
  if (!target.isMobile && !target.isLinuxArm64Cross) {
    await _run('ctest', ['--test-dir', build, '--output-on-failure']);
  }
  await _prepareAssets(root, source, input, build, target);
}

Future<void> _prepareAssets(
  Directory root,
  Directory upstreamSource,
  Map<String, Object?> input,
  String build,
  SdkTarget target,
) async {
  final stage = sdk.newStage(root, 'hermes', target);
  final library = File(
    p.join(
      build,
      'hermes',
      'lib',
      target.os == 'windows'
          ? 'hermesvm.dll'
          : 'libhermesvm${target.extension}',
    ),
  );
  if (!library.existsSync()) {
    throw StateError('Hermes shared library is missing: ${library.path}');
  }
  final libraries = await sdk.stageLibraries(root, stage, [library], target);
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
  sdk.writeCmakeConfig(stage, 'hermes', libraries, sdkTarget: target);
  await sdk.finishSdk(root, stage, 'hermes', libraries, {
    'revision': (input['upstream'] as Map<String, Object?>)['revision'],
    'version': (input['upstream'] as Map<String, Object?>)['version'],
    'patches': (input['upstream'] as Map<String, Object?>)['patches'],
    'jit': false,
    'unicodeLite': target.os == 'linux' || target.os == 'android',
  }, target);
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
