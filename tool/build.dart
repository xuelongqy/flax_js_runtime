import 'dart:io';

Future<void> main(List<String> args) async {
  final engine = _engine(args);
  final script = 'engines/$engine/tool/build.dart';
  if (!File(script).existsSync())
    throw StateError('Engine $engine has no build implementation');
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    script,
  ], mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  if (code != 0) exitCode = code;
}

String _engine(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--engine=')) return arg.substring('--engine='.length);
  }
  return 'hermes';
}
