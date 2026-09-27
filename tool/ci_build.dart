import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/sdk.dart' as sdk;
import 'src/target.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1 || !args.single.startsWith('--targets=')) {
    throw ArgumentError('Usage: dart run tool/ci_build.dart --targets=id,id');
  }
  final ids = args.single.substring('--targets='.length).split(',');
  if (ids.isEmpty || ids.toSet().length != ids.length) {
    throw ArgumentError('Duplicate or empty SDK target');
  }
  Directory('dist').createSync(recursive: true);
  final failures = <String>[];
  for (final id in ids) {
    final target = sdkTargets[id];
    if (target == null) throw ArgumentError('Unknown SDK target: $id');
    target.requireBuildHost();
    final checksums = StringBuffer();
    for (final engine in const ['hermes', 'v8']) {
      try {
        await _dart([
          'run',
          'tool/build.dart',
          '--engine=$engine',
          '--target=$id',
        ]);
        await _dart([
          'run',
          'tool/package.dart',
          '--engine=$engine',
          '--target=$id',
        ]);
        await _dart([
          'run',
          'tool/check_sdk.dart',
          engine,
          'build/sdk/$engine-$id',
          if (target.isMobile || target.isLinuxArm64Cross) '--compile-only',
        ]);
        final version = sdk.readJson('runtime.json')['runtimeVersion'];
        final archive = File(
          'dist/flax-engine-sdk-$version-$engine-$id.tar.gz',
        );
        if (!archive.existsSync())
          throw StateError('Missing candidate: ${archive.path}');
        final digest = await sdk.digestFile(archive);
        checksums.writeln('$digest  ${p.basename(archive.path)}');
        stdout.writeln(
          'CANDIDATE $engine/$id sha256=$digest '
          '${target.isMobile || target.isLinuxArm64Cross ? 'compile-only' : 'executed'}',
        );
        Directory(p.join('build', 'sdk', '$engine-$id'))
            .deleteSync(recursive: true);
        if (engine == 'v8') {
          final out = Directory(
            p.join(
              'engines',
              'v8',
              '.cache',
              'native',
              'v8',
              'out',
              'flax-sdk-$id',
            ),
          );
          if (out.existsSync()) out.deleteSync(recursive: true);
        } else {
          final out = Directory(
            p.join('engines', 'hermes', 'build', 'native', id),
          );
          if (out.existsSync()) out.deleteSync(recursive: true);
        }
      } catch (error) {
        stderr.writeln('CANDIDATE FAILED $engine/$id: $error');
        failures.add('$engine/$id');
      }
    }
    File('dist/SHA256SUMS-$id.txt').writeAsStringSync(checksums.toString());
  }
  if (failures.isNotEmpty) {
    throw StateError('Failed SDK candidates: ${failures.join(', ')}');
  }
}

Future<void> _dart(List<String> arguments) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    arguments,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0)
    throw ProcessException(
      Platform.resolvedExecutable,
      arguments,
      'Candidate step failed',
      code,
    );
}
