import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/sdk.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || !const ['hermes', 'v8'].contains(args[0])) {
    throw ArgumentError(
      'Usage: dart run tool/check_sdk.dart <hermes|v8> <sdk-directory>',
    );
  }
  final root = Directory.fromUri(Platform.script.resolve('../'));
  final engine = args[0];
  final source = Directory(p.absolute(args[1]));
  await verifySdk(source);
  final temp = Directory.systemTemp.createTempSync('flax-sdk-consumer-');
  try {
    final sdk = Directory(p.join(temp.path, 'sdk'));
    copyTree(source, sdk);
    File(p.join(root.path, 'engines', engine, 'native', 'sdk_test.cpp'))
        .copySync(p.join(temp.path, 'main.cpp'));
    File(p.join(temp.path, 'CMakeLists.txt')).writeAsStringSync('''
cmake_minimum_required(VERSION 3.24)
project(sdk_consumer LANGUAGES CXX)
find_package(FlaxEngineSDK CONFIG REQUIRED PATHS "\${CMAKE_CURRENT_SOURCE_DIR}/sdk/cmake" NO_DEFAULT_PATH)
add_executable(sdk_consumer main.cpp)
target_link_libraries(sdk_consumer PRIVATE FlaxEngineSDK::$engine)
set_target_properties(sdk_consumer PROPERTIES BUILD_WITH_INSTALL_RPATH YES INSTALL_RPATH "@loader_path/../sdk/lib")
''');
    await command('cmake', [
      '-S',
      temp.path,
      '-B',
      '${temp.path}/bin',
      '-G',
      'Ninja',
      '-DCMAKE_BUILD_TYPE=Release',
      '-DCMAKE_OSX_ARCHITECTURES=arm64',
      '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
    ]);
    await command('cmake', ['--build', '${temp.path}/bin']);
    await command('${temp.path}/bin/sdk_consumer', []);
    final relocated = Directory('${temp.path}-relocated');
    temp.renameSync(relocated.path);
    try {
      await command('${relocated.path}/bin/sdk_consumer', []);
      await verifySdk(Directory('${relocated.path}/sdk'));
    } finally {
      relocated.deleteSync(recursive: true);
    }
    stdout.writeln('$engine SDK passed independent and relocated consumption.');
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}
