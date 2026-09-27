import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/sdk.dart' as sdk;

Future<void> main(List<String> args) async {
  final engine = args
      .where((arg) => arg.startsWith('--engine='))
      .map((arg) => arg.substring('--engine='.length))
      .single;
  if (!const ['hermes', 'v8'].contains(engine)) {
    throw ArgumentError('Expected --engine=hermes or --engine=v8');
  }
  final root = Directory.fromUri(Platform.script.resolve('../'));
  final stage = Directory(
    p.join(root.path, 'build', 'sdk', '$engine-${sdk.sdkTarget}'),
  );
  await sdk.verifySdk(stage);
  final version = sdk.readJson(
    p.join(root.path, 'runtime.json'),
  )['runtimeVersion'];
  final archive = File(
    p.join(
      root.path,
      'dist',
      'flax-engine-sdk-$version-$engine-${sdk.sdkTarget}.tar.gz',
    ),
  );
  archive.parent.createSync(recursive: true);
  await sdk.command('tar', ['-czf', archive.path, '-C', stage.path, '.']);
  stdout.writeln('${archive.path} sha256=${await sdk.digestFile(archive)}');
}
