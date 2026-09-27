import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../tool/src/sdk.dart' as sdk;
import '../../../tool/src/target.dart';

Future<void> _checkout(String path, String url, String revision) async {
  final git = Directory(p.join(path, '.git'));
  if (!git.existsSync()) {
    Directory(path).createSync(recursive: true);
    await sdk.command('git', ['init', path]);
    await sdk.command('git', ['remote', 'add', 'origin', url], directory: path);
    await sdk.command('git', [
      'fetch',
      '--depth',
      '1',
      'origin',
      revision,
    ], directory: path);
    await sdk.command('git', [
      'checkout',
      '--detach',
      revision,
    ], directory: path);
  }
  final actual = await sdk.command(
    'git',
    ['rev-parse', 'HEAD'],
    directory: path,
    capture: true,
  );
  if (actual != revision)
    throw StateError('Cached V8 revision is $actual, expected $revision');
  await sdk.command('git', ['diff', 'HEAD', '--exit-code'], directory: path);
}

Future<void> main(List<String> args) async {
  final target = parseTarget(args)..requireBuildHost();
  final package = Directory.fromUri(Platform.script.resolve('../'));
  final root = Directory.fromUri(Platform.script.resolve('../../../'));
  final input = sdk.readJson(p.join(package.path, 'engine.json'));
  const ninja = 'ninja';
  final expectedTools = Map<String, Object?>.from(input['hostTools'] as Map);
  final actualTools = <String, String>{
    'cmake': (await sdk.command('cmake', [
      '--version',
    ], capture: true)).split('\n').first.split(' ').last,
    'ninja': await sdk.command('ninja', ['--version'], capture: true),
    if (target.isApple)
      'xcode': (await sdk.command('xcodebuild', [
        '-version',
      ], capture: true)).split('\n').first.split(' ').last,
    if (target.os == 'macos')
      'macosSdk': await sdk.command('xcrun', [
        '--show-sdk-version',
      ], capture: true),
  };
  for (final entry in actualTools.entries) {
    if (target.id == 'macos-arm64' &&
        entry.value != expectedTools[entry.key] &&
        Platform.environment['FLAX_V8_ALLOW_UNPINNED_HOST_TOOLS'] != '1') {
      throw StateError(
        'V8 requires ${entry.key} ${expectedTools[entry.key]}, found ${entry.value}',
      );
    }
  }
  final cache = sdk.sourceCache(package).path;
  final source = p.join(cache, 'v8');
  final depot = p.join(cache, 'depot_tools');
  await _checkout(
    source,
    'https://chromium.googlesource.com/v8/v8.git',
    input['revision'] as String,
  );
  await _checkout(
    depot,
    'https://chromium.googlesource.com/chromium/tools/depot_tools.git',
    input['depotToolsRevision'] as String,
  );
  final targetOs = target.os == 'android' || target.os == 'ios'
      ? "target_os = ['${target.os}']\n"
      : '';
  File(p.join(cache, '.gclient')).writeAsStringSync(
    'solutions = ${jsonEncode([
      {
        'name': 'v8',
        'url': 'https://chromium.googlesource.com/v8/v8.git',
        'managed': false,
        'custom_deps': {'v8/agents/shared': null, 'v8/test/test262/data': null, 'v8/test/mozilla/data': null, 'v8/test/benchmarks/data': null, if (target.os != 'windows') 'v8/tools/win': null},
        'custom_vars': <String, Object?>{},
      },
    ]).replaceAll('false', 'False').replaceAll('null', 'None')}\n$targetOs',
  );
  final env = {
    'DEPOT_TOOLS_UPDATE': '0',
    'PATH':
        '$depot${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
  };
  await sdk.command(
    p.join(depot, Platform.isWindows ? 'gclient.bat' : 'gclient'),
    ['sync', '--no-history', '--revision', 'v8@${input['revision']}'],
    directory: cache,
    environment: env,
  );
  await _checkout(
    source,
    'https://chromium.googlesource.com/v8/v8.git',
    input['revision'] as String,
  );
  final patches = (input['patches'] as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final patch in patches) {
    final file = File(p.join(package.path, 'patches', patch['file'] as String));
    await sdk.requireDigest(file, patch['sha256'] as String);
    final alreadyApplied = await Process.run('git', [
      'apply',
      '--reverse',
      '--check',
      file.path,
    ], workingDirectory: p.join(source, 'build'));
    if (alreadyApplied.exitCode == 0) continue;
    await sdk.command('git', [
      'apply',
      '--check',
      file.path,
    ], directory: p.join(source, 'build'));
    await sdk.command('git', [
      'apply',
      file.path,
    ], directory: p.join(source, 'build'));
  }
  var gnArgs = _gnArgs(target);
  final localSdk = Platform.environment['FLAX_V8_MAC_SDK_PATH'];
  if (localSdk != null) {
    if (Platform.environment['FLAX_V8_ALLOW_UNPINNED_HOST_TOOLS'] != '1' ||
        !Directory(localSdk).existsSync()) {
      throw StateError(
        'FLAX_V8_MAC_SDK_PATH requires an existing SDK and local toolchain override',
      );
    }
    gnArgs += 'mac_sdk_path = ${jsonEncode(localSdk)}\n';
  }
  final gn = p.join(
    source,
    'buildtools',
    Platform.isMacOS
        ? 'mac'
        : Platform.isWindows
        ? 'win'
        : 'linux64',
    Platform.isWindows ? 'gn.exe' : 'gn',
  );
  final outName = 'out/flax-sdk-${target.id}';
  await sdk.command(
    gn,
    ['gen', outName, '--args=$gnArgs'],
    directory: source,
    environment: env,
  );
  await sdk.command(
    ninja,
    [
      '-C',
      outName,
      '-j',
      '${sdk.buildJobs()}',
      target.os == 'ios' ? 'v8_monolith' : 'v8',
      if (target.os != 'ios') 'v8_libplatform',
    ],
    directory: source,
    environment: env,
  );
  final defines =
      (await sdk.command(
            gn,
            ['desc', outName, ':v8_headers', 'defines'],
            directory: source,
            capture: true,
          ))
          .split('\n')
          .where((line) => line.startsWith('V8_') || line.startsWith('CPPGC_'))
          .toList()
        ..add('USING_V8_SHARED=1');
  final out = Directory(p.join(source, outName));
  if (target.os == 'ios') {
    await _linkIosMonolith(out, target);
  }
  final libraries =
      out
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith(target.extension))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (!libraries.any(
        (f) =>
            p.basename(f.path) ==
            (target.os == 'windows' ? 'v8.dll' : 'libv8${target.extension}'),
      ) ||
      target.os != 'ios' &&
          !libraries.any(
            (f) => p.basename(f.path).contains('v8_libplatform'),
          )) {
    throw StateError(
      'V8 component build did not produce both required shared libraries',
    );
  }
  final stage = sdk.newStage(root, 'v8', target);
  final staged = await sdk.stageLibraries(stage, libraries, target);
  sdk.copyHeaders(
    Directory(p.join(source, 'include')),
    Directory(p.join(stage.path, 'include')),
  );
  sdk.copyNotices(Directory(source), Directory(p.join(stage.path, 'notices')));
  sdk.writeCmakeConfig(
    stage,
    'v8',
    staged,
    sdkTarget: target,
    defines: defines,
    cxxStandard: 20,
  );
  await sdk.finishSdk(root, stage, 'v8', staged, {
    'revision': input['revision'],
    'version': input['version'],
    'gnArgs': gnArgs,
    'hostTools': actualTools,
    'patches': patches,
    'jit': target.os != 'ios',
  }, target);
}

String _gnArgs(SdkTarget target) {
  final os = switch (target.os) {
    'macos' => 'mac',
    'windows' => 'win',
    _ => target.os,
  };
  final cpu = target.architecture == 'arm32' ? 'arm' : target.architecture;
  final ios = target.os == 'ios';
  return '''is_debug = false
target_os = "$os"
target_cpu = "$cpu"
v8_target_cpu = "$cpu"
is_component_build = ${!ios}
v8_monolithic = $ios
v8_monolithic_for_shared_library = $ios
v8_jitless = $ios
${ios ? 'v8_enable_turbofan = false\nv8_enable_webassembly = false' : ''}
v8_use_external_startup_data = false
v8_enable_i18n_support = false
use_custom_libcxx = false
v8_enable_sandbox = false
v8_enable_pointer_compression = false
symbol_level = 0
treat_warnings_as_errors = false
use_remoteexec = false
${target.os == 'macos' ? 'mac_deployment_target = "${target.minimumVersion}"' : ''}
${ios ? 'target_environment = "${target.appleSdk == 'iphoneos' ? 'device' : 'simulator'}"\nios_deployment_target = "${target.minimumVersion}"' : ''}
''';
}

Future<void> _linkIosMonolith(Directory out, SdkTarget target) async {
  final archive = File(p.join(out.path, 'libv8_monolith.a'));
  if (!archive.existsSync()) throw StateError('Missing iOS V8 monolith');
  final result = p.join(out.path, 'libv8.dylib');
  final sdkPath = await sdk.command('xcrun', [
    '--sdk',
    target.appleSdk!,
    '--show-sdk-path',
  ], capture: true);
  await sdk.command('xcrun', [
    '--sdk',
    target.appleSdk!,
    'clang++',
    '-dynamiclib',
    '-arch',
    target.architecture == 'x64' ? 'x86_64' : 'arm64',
    '-isysroot',
    sdkPath,
    target.appleSdk == 'iphoneos'
        ? '-miphoneos-version-min=${target.minimumVersion}'
        : '-mios-simulator-version-min=${target.minimumVersion}',
    '-Wl,-force_load,${archive.path}',
    '-Wl,-install_name,@rpath/libv8.dylib',
    '-o',
    result,
  ]);
}
