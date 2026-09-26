import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final engine = args.firstWhere((arg) => arg.startsWith('--engine='), orElse: () => '--engine=hermes').split('=').last;
  final runtime = jsonDecode(File('runtime.json').readAsStringSync()) as Map<String, dynamic>;
  final version = runtime['runtimeVersion'] as String;
  final source = Directory('engines/$engine/native/generated/macos_arm64');
  if (!source.existsSync()) throw StateError('Build $engine before packaging it');
  final oldManifest = jsonDecode(File(p.join(source.path, 'manifest.json')).readAsStringSync()) as Map<String, dynamic>;
  final library = source.listSync().whereType<File>().singleWhere((file) => p.extension(file.path) == '.dylib');
  final digest = (await sha256.bind(library.openRead()).first).toString();
  final stage = Directory('dist/$engine-macos-arm64');
  if (stage.existsSync()) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  library.copySync(p.join(stage.path, p.basename(library.path)));
  final notices = Directory(p.join(source.path, 'notices'));
  if (notices.existsSync()) await _copyDirectory(notices, Directory(p.join(stage.path, 'notices')));
  File(p.join(stage.path, 'manifest.json')).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'runtimeVersion': version,
    'abiVersion': runtime['abiVersion'],
    'engine': engine,
    'os': 'macos',
    'architecture': 'arm64',
    'minimumOSVersion': oldManifest['minimumOSVersion'],
    'entrySymbol': oldManifest['entrySymbol'],
    'library': p.basename(library.path),
    'sha256': digest,
    'capabilities': (jsonDecode(File('engines/$engine/engine.json').readAsStringSync()) as Map<String,dynamic>)['capabilities'],
    'engineMetadata': oldManifest,
  })}\n');
  final output = 'dist/flax-js-runtime-$version-$engine-macos-arm64.tar.gz';
  final result = await Process.run('tar', ['-czf', output, '-C', stage.path, '.']);
  if (result.exitCode != 0) throw ProcessException('tar', [], result.stderr.toString(), result.exitCode);
  stdout.writeln(output);
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  target.createSync(recursive: true);
  for (final entity in source.listSync()) {
    final out = p.join(target.path, p.basename(entity.path));
    if (entity is File) entity.copySync(out);
    if (entity is Directory) await _copyDirectory(entity, Directory(out));
  }
}
