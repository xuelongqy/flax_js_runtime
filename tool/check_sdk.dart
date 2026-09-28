import 'dart:io';

import 'package:path/path.dart' as p;

import 'src/sdk.dart';
import 'src/target.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2 || !const ['hermes', 'v8'].contains(args[0])) {
    throw ArgumentError(
      'Usage: dart run tool/check_sdk.dart <hermes|v8> <sdk-directory> '
      '[--adb-serial=ID|--simulator=UDID|--compile-only]',
    );
  }
  final root = Directory.fromUri(Platform.script.resolve('../'));
  final engine = args[0];
  final source = Directory(p.absolute(args[1]));
  await verifySdk(source);
  final manifest = readJson(p.join(source.path, 'manifest.json'));
  if (manifest['engine'] != engine) throw StateError('Wrong SDK engine');
  final target = sdkTargets[manifest['target']];
  if (target == null) throw StateError('Unknown SDK target');
  final expectedJit = target.os != 'ios';
  final metadata = manifest['metadata'];
  if (engine == 'v8' && (metadata is! Map || metadata['jit'] != expectedJit)) {
    throw StateError('Incorrect V8 JIT configuration for ${target.id}');
  }
  final adbSerial = _option(args, '--adb-serial=');
  final simulator = _option(args, '--simulator=');
  final compileOnly = args.contains('--compile-only');
  if (target.isMobile &&
      !compileOnly &&
      (target.os == 'android'
          ? adbSerial == null
          : target.appleSdk == 'iphoneos' || simulator == null)) {
    throw StateError('${target.id} requires a device or --compile-only');
  }
  final temp = Directory.systemTemp.createTempSync('flax-sdk-consumer-');
  try {
    final sdk = Directory(p.join(temp.path, 'sdk'));
    copyTree(source, sdk);
    File(p.join(root.path, 'engines', engine, 'native', 'sdk_test.cpp'))
        .copySync(p.join(temp.path, 'main.cpp'));
    File(p.join(temp.path, 'CMakeLists.txt')).writeAsStringSync('''
cmake_minimum_required(VERSION 3.24)
project(sdk_consumer LANGUAGES CXX)
find_package(FlaxEngineSDK CONFIG REQUIRED PATHS "\${CMAKE_CURRENT_SOURCE_DIR}/sdk/cmake" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
add_executable(sdk_consumer main.cpp)
target_link_libraries(sdk_consumer PRIVATE FlaxEngineSDK::$engine)
${engine == 'v8' ? 'target_compile_definitions(sdk_consumer PRIVATE FLAX_SDK_EXPECT_JIT=${expectedJit ? 1 : 0})' : ''}
set_target_properties(sdk_consumer PROPERTIES BUILD_WITH_INSTALL_RPATH YES
  INSTALL_RPATH "${target.isApple ? '@loader_path' : r'$ORIGIN'}/../sdk/lib")
''');
    final flags = <String>[];
    if (target.isApple) {
      final iosSdk = target.appleSdk == null
          ? null
          : await command('xcrun', [
              '--sdk',
              target.appleSdk!,
              '--show-sdk-path',
            ], capture: true);
      flags.addAll([
        '-DCMAKE_OSX_ARCHITECTURES=${target.architecture == 'x64' ? 'x86_64' : 'arm64'}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${target.minimumVersion}',
        if (target.appleSdk != null) '-DCMAKE_SYSTEM_NAME=iOS',
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
      ]);
    }
    if (target.isLinuxArm64Cross) {
      flags.addAll([
        '-DCMAKE_SYSTEM_NAME=Linux',
        '-DCMAKE_SYSTEM_PROCESSOR=aarch64',
        if (engine == 'v8')
          '-DCMAKE_CXX_COMPILER_TARGET=aarch64-linux-gnu'
        else
          '-DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++',
      ]);
    }
    if (engine == 'v8' && target.os == 'linux') {
      flags.add(
        '-DCMAKE_CXX_COMPILER=${Platform.environment['CXX'] ?? 'clang++-23'}',
      );
    }
    await command('cmake', [
      '-S',
      temp.path,
      '-B',
      '${temp.path}/bin',
      '-G',
      'Ninja',
      '-DCMAKE_BUILD_TYPE=Release',
      ...flags,
    ]);
    await command('cmake', ['--build', '${temp.path}/bin']);
    if (target.os == 'windows') {
      copyTree(
        Directory(p.join(sdk.path, 'lib')),
        Directory(p.join(temp.path, 'bin')),
        include: (file) => p.extension(file.path).toLowerCase() == '.dll',
      );
    }
    final relocated = Directory('${temp.path}-relocated');
    temp.renameSync(relocated.path);
    try {
      await verifySdk(Directory('${relocated.path}/sdk'));
      final executable = File(
        p.join(
          relocated.path,
          'bin',
          target.os == 'windows' ? 'sdk_consumer.exe' : 'sdk_consumer',
        ),
      );
      if (!compileOnly) {
        if (target.os == 'android') {
          await _runAndroid(executable, relocated, target, adbSerial!);
        } else if (target.os == 'ios') {
          await command('xcrun', [
            'simctl',
            'spawn',
            simulator!,
            executable.path,
          ]);
        } else {
          await command(executable.path, []);
        }
      }
    } finally {
      relocated.deleteSync(recursive: true);
    }
    stdout.writeln(
      '$engine ${target.id} SDK passed relocated '
      '${compileOnly ? 'compilation only' : 'execution'}.',
    );
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

String? _option(List<String> args, String prefix) {
  final matches = args.where((arg) => arg.startsWith(prefix)).toList();
  if (matches.length > 1) throw ArgumentError('Duplicate $prefix');
  return matches.isEmpty ? null : matches.single.substring(prefix.length);
}

Future<void> _runAndroid(
  File executable,
  Directory relocated,
  SdkTarget target,
  String serial,
) async {
  final abis = await command('adb', [
    '-s',
    serial,
    'shell',
    'getprop',
    'ro.product.cpu.abilist',
  ], capture: true);
  if (!abis.split(',').contains(target.androidAbi)) {
    throw StateError('$serial cannot run ${target.androidAbi}');
  }
  final remote = '/data/local/tmp/flax-sdk-${target.id}';
  await command('adb', ['-s', serial, 'shell', 'rm', '-rf', remote]);
  await command('adb', ['-s', serial, 'push', relocated.path, remote]);
  await command('adb', [
    '-s',
    serial,
    'shell',
    'cd $remote && chmod 755 bin/sdk_consumer && '
        'LD_LIBRARY_PATH=$remote/sdk/lib bin/sdk_consumer',
  ]);
}
