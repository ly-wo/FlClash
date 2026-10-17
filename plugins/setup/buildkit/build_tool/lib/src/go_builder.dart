import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'environment.dart';
import 'error.dart';
import 'logging.dart';
import 'options.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('go_builder');

String _resolveCc(Target target) {
  final ndk = Environment.androidNdk;
  final prebuiltDir = Directory(
    p.join(ndk, 'toolchains', 'llvm', 'prebuilt'),
  );
  final entries = prebuiltDir
      .listSync()
      .where((e) => !p.basename(e.path).startsWith('.'))
      .toList();
  if (entries.isEmpty) {
    throw BuildException('No NDK prebuilt toolchain found in $prebuiltDir');
  }
  final compiler = Platform.isWindows ? '${target.ndkCcName}.cmd' : target.ndkCcName;
  return p.join(entries.first.path, 'bin', compiler);
}

String resolveCoreDirectory({
  required Target target,
  required String stockDir,
  String? moduleDir,
}) {
  if (target.isLib) {
    if (moduleDir == null || moduleDir.isEmpty) {
      throw BuildException(
        'Android lib build requires the prepared shanlian core. Refusing to compile the unmodified core.',
      );
    }
    return moduleDir;
  }
  return stockDir;
}

class GoBuilder {
  final String rootDir;
  final BuildConfig config;

  GoBuilder({required this.rootDir, required this.config});

  String get _corePath => p.join(rootDir, config.coreDir);
  String get _outputPath => p.join(rootDir, config.outputDir);

  Future<String> build(
    Target target, {
    String? moduleDir,
    String? goLdflags,
  }) async {
    // Desktop: output directly to libclash/{platform}/
    // Android: output to libclash/android/{abi}/
    final outDir = target.isLib
        ? p.join(_outputPath, target.platformDir, target.abi!)
        : p.join(_outputPath, target.platformDir);
    ensureDir(outDir);

    final fileName = target.isLib
        ? '${config.libName}${target.dynamicLibExtension}'
        : '${config.coreName}${target.executableExtension}';
    final outFile = p.join(outDir, fileName);
    final workDir = resolveCoreDirectory(
      target: target,
      stockDir: _corePath,
      moduleDir: moduleDir,
    );

    final env = <String, String>{
      'GOOS': target.goos,
      'GOARCH': target.goarch,
    };

    if (target.isLib) {
      env['CGO_ENABLED'] = '1';
      env['CC'] = _resolveCc(target);
      env['CFLAGS'] = '-O3 -Werror';
    } else {
      env['CGO_ENABLED'] = '0';
    }

    final flags = goLdflags ?? config.goLdflags;
    final args = [
      'build',
      if (target.isLib) '-mod=readonly',
      '-ldflags=$flags',
      '-tags=${config.tags}',
      if (target.isLib) '-buildmode=c-shared',
      '-o',
      outFile,
    ];

    _log.info(kDoubleSeparator);
    _log.info(
        'Building Go core: $target ${target.isLib ? "(CGO, c-shared)" : "(standalone)"}');
    _log.info(kSeparator);

    await runCommandStream('go', args,
        workingDirectory: workDir, environment: env);

    if (target.isLib && target.abi != null) {
      await _adjustAndroidOutput(
          outDir: p.join(_outputPath, target.platformDir),
          abiDir: target.abi!,
          archName: target.abi!,
          libPath: outFile,
          libName: fileName,
          coreDir: workDir);
    }

    _log.info('Built: $outFile');
    return outFile;
  }

  Future<List<String>> buildAll(
    List<Target> targets, {
    String? moduleDir,
    String? goLdflags,
  }) async {
    if (targets.any((target) => target.isLib) &&
        (moduleDir == null || moduleDir.isEmpty)) {
      throw BuildException(
        'Android lib build requires the prepared shanlian core. Refusing to compile the unmodified core.',
      );
    }
    final results = await Future.wait(targets.map(
      (target) => build(target, moduleDir: moduleDir, goLdflags: goLdflags),
    ));
    return results;
  }

  Future<void> _adjustAndroidOutput({
    required String outDir,
    required String abiDir,
    required String archName,
    required String libPath,
    required String libName,
    required String coreDir,
  }) async {
    final includesPath = p.join(outDir, 'includes', archName);
    final androidCoreMainPath =
        p.join(rootDir, 'android', 'core', 'src', 'main');
    final jniLibsPath = p.join(androidCoreMainPath, 'jniLibs', abiDir);
    final cppIncludesPath =
        p.join(androidCoreMainPath, 'cpp', 'includes', archName);

    ensureDir(jniLibsPath);
    ensureDir(includesPath);
    _clearDirectory(includesPath);
    ensureDir(cppIncludesPath);
    _clearDirectory(cppIncludesPath);

    _deleteIfExists(p.join(jniLibsPath, libName));
    File(libPath).copySync(p.join(jniLibsPath, libName));

    final abiDirPath = p.join(outDir, abiDir);
    final headerFiles = [
      ...Directory(abiDirPath).listSync(),
      ...Directory(coreDir).listSync(),
    ];
    for (final file in headerFiles) {
      if (!file.path.endsWith('.h')) continue;
      final fileName = p.basename(file.path);
      final source = File(file.path);
      source.copySync(p.join(includesPath, fileName));
      source.copySync(p.join(cppIncludesPath, fileName));
      if (file.path.startsWith(abiDirPath)) {
        source.deleteSync();
      }
    }

    for (final header in ['libclash.h', 'bride.h']) {
      final installed = File(p.join(cppIncludesPath, header));
      if (!installed.existsSync()) {
        throw BuildException(
          'Android core header $header is missing for $archName. Refusing to continue without the shanlian Go library.',
        );
      }
    }
    final jniLib = File(p.join(jniLibsPath, libName));
    if (!jniLib.existsSync()) {
      throw BuildException(
        'Android core library $libName is missing for $archName. Refusing to continue without the shanlian Go library.',
      );
    }
  }

  void _clearDirectory(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;

    for (final entity in dir.listSync()) {
      if (entity is File || entity is Link) {
        entity.deleteSync();
      } else if (entity is Directory) {
        entity.deleteSync(recursive: true);
      }
    }
  }

  void _deleteIfExists(String filePath) {
    final file = File(filePath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}
