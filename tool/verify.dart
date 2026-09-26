import 'dart:convert';
import 'dart:io';

Never fail(String message) => throw StateError(message);

void main() {
  final runtime = jsonDecode(File('runtime.json').readAsStringSync()) as Map<String, dynamic>;
  if (runtime['schemaVersion'] != 1) fail('Unsupported runtime schema');
  final abi = runtime['abiVersion'];
  if (abi is! int || abi < 1) fail('Invalid ABI version');
  final engines = runtime['engines'] as Map<String, dynamic>;
  for (final entry in engines.entries) {
    final item = entry.value as Map<String, dynamic>;
    final descriptor = File(item['descriptor'] as String);
    if (!descriptor.existsSync()) fail('Missing descriptor: ${descriptor.path}');
    final value = jsonDecode(descriptor.readAsStringSync()) as Map<String, dynamic>;
    if (value['id'] != entry.key || value['status'] != item['status']) fail('Descriptor mismatch: ${entry.key}');
    if (value['status'] == 'stable' && (value['platforms'] as List).isEmpty) fail('Stable engine has no platform: ${entry.key}');
  }
  if (!File('schema/artifact.schema.json').existsSync()) fail('Missing artifact schema');
  stdout.writeln('Verified ${engines.length} engine descriptors for ABI $abi.');
}
