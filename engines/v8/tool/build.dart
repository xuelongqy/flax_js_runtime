import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../tool/src/sdk.dart' as sdk;

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

Future<void> main() async {
  if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
    throw UnsupportedError('V8 SDK currently requires macOS arm64');
  }
  final package = Directory.fromUri(Platform.script.resolve('../'));
  final root = Directory.fromUri(Platform.script.resolve('../../../'));
  final input = sdk.readJson(p.join(package.path, 'engine.json'));
  final ninja = await sdk.command('which', ['ninja'], capture: true);
  final expectedTools = Map<String, Object?>.from(input['hostTools'] as Map);
  final actualTools = <String, String>{
    'cmake': (await sdk.command('cmake', [
      '--version',
    ], capture: true)).split('\n').first.split(' ').last,
    'ninja': await sdk.command('ninja', ['--version'], capture: true),
    'xcode': (await sdk.command('xcodebuild', [
      '-version',
    ], capture: true)).split('\n').first.split(' ').last,
    'macosSdk': await sdk.command('xcrun', [
      '--show-sdk-version',
    ], capture: true),
  };
  for (final entry in actualTools.entries) {
    if (entry.value != expectedTools[entry.key] &&
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
  File(p.join(cache, '.gclient')).writeAsStringSync(
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
  final env = {
    'DEPOT_TOOLS_UPDATE': '0',
    'PATH': '$depot:${Platform.environment['PATH'] ?? ''}',
  };
  await sdk.command(
    p.join(depot, 'gclient'),
    [
      'sync',
      '--no-history',
      '--nohooks',
      '--revision',
      'v8@${input['revision']}',
    ],
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
  var args = (input['gnArgs'] as String)
      .replaceFirst('v8_monolithic = true', 'v8_monolithic = false')
      .replaceFirst(
        'v8_monolithic_for_shared_library = true',
        'v8_monolithic_for_shared_library = false',
      )
      .replaceFirst('is_component_build = false', 'is_component_build = true');
  final localSdk = Platform.environment['FLAX_V8_MAC_SDK_PATH'];
  if (localSdk != null) {
    if (Platform.environment['FLAX_V8_ALLOW_UNPINNED_HOST_TOOLS'] != '1' ||
        !Directory(localSdk).existsSync()) {
      throw StateError(
        'FLAX_V8_MAC_SDK_PATH requires an existing SDK and local toolchain override',
      );
    }
    args += 'mac_sdk_path = ${jsonEncode(localSdk)}\n';
  }
  final gn = p.join(source, 'buildtools', 'mac', 'gn');
  await sdk.command(
    gn,
    ['gen', 'out/flax-sdk', '--args=$args'],
    directory: source,
    environment: env,
  );
  await sdk.command(
    ninja,
    ['-C', 'out/flax-sdk', '-j', '${sdk.buildJobs()}', 'v8', 'v8_libplatform'],
    directory: source,
    environment: env,
  );
  final defines =
      (await sdk.command(
            gn,
            ['desc', 'out/flax-sdk', ':v8_headers', 'defines'],
            directory: source,
            capture: true,
          ))
          .split('\n')
          .where((line) => line.startsWith('V8_') || line.startsWith('CPPGC_'))
          .toList()
        ..add('USING_V8_SHARED=1');
  final out = Directory(p.join(source, 'out', 'flax-sdk'));
  final libraries =
      out
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dylib'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (!libraries.any((f) => p.basename(f.path) == 'libv8.dylib') ||
      !libraries.any((f) => p.basename(f.path) == 'libv8_libplatform.dylib')) {
    throw StateError(
      'V8 component build did not produce both required shared libraries',
    );
  }
  final stage = sdk.newStage(root, 'v8');
  final staged = await sdk.stageLibraries(stage, libraries);
  sdk.copyHeaders(
    Directory(p.join(source, 'include')),
    Directory(p.join(stage.path, 'include')),
  );
  sdk.copyNotices(Directory(source), Directory(p.join(stage.path, 'notices')));
  sdk.writeCmakeConfig(stage, 'v8', staged, defines: defines, cxxStandard: 20);
  await sdk.finishSdk(root, stage, 'v8', staged, {
    'revision': input['revision'],
    'version': input['version'],
    'gnArgs': args,
    'hostTools': actualTools,
    'patches': patches,
    'jit': true,
  });
}
