import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'error.dart';

const _refuseStockCore =
    'Android build stops instead of using the unmodified core.';

List<File> listBridgeFiles(String coreDir) {
  final root = Directory(coreDir);
  if (!root.existsSync()) {
    throw BuildException(
      'FlClash core directory is missing: $coreDir. $_refuseStockCore',
    );
  }
  final files = <File>[];
  void walk(Directory dir, {required bool top}) {
    final entries = dir.listSync(followLinks: false).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (top && (name == 'Clash.Meta' || name == 'shanlian')) continue;
      if (entity is Directory) {
        walk(entity, top: false);
      } else if (entity is File) {
        files.add(entity);
      }
    }
  }

  walk(root, top: true);
  return files;
}

String bridgeContentFingerprint(String coreDir) {
  final lines = <String>[];
  for (final file in listBridgeFiles(coreDir)) {
    final rel = p.relative(file.path, from: coreDir).replaceAll('\\', '/');
    final digest = sha256.convert(file.readAsBytesSync());
    lines.add('$rel $digest');
  }
  lines.sort();
  return sha256.convert(utf8.encode(lines.join('\n'))).toString();
}

class PreparedShanlianCore {
  final String moduleDir;
  final String mihomoDir;
  final String shanlianVersion;
  final String mihomoCommit;
  final String patchSha256;

  const PreparedShanlianCore({
    required this.moduleDir,
    required this.mihomoDir,
    required this.shanlianVersion,
    required this.mihomoCommit,
    required this.patchSha256,
  });

  String ldflags(String baseLdflags) {
    return '$baseLdflags -X github.com/metacubex/mihomo/constant.Version=$shanlianVersion';
  }
}

class ShanlianManifest {
  final String mihomoCommit;
  final String patchName;
  final String patchSha256;
  final String markerFile;
  final String markerText;
  final String versionSuffix;

  const ShanlianManifest({
    required this.mihomoCommit,
    required this.patchName,
    required this.patchSha256,
    required this.markerFile,
    required this.markerText,
    required this.versionSuffix,
  });

  static ShanlianManifest load(String packageDir) {
    final file = File(p.join(packageDir, 'manifest.json'));
    if (!file.existsSync()) {
      throw BuildException(
        'Shanlian manifest is missing: ${file.path}. $_refuseStockCore',
      );
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw BuildException('Shanlian manifest is not an object. $_refuseStockCore');
    }
    String requireString(String key) {
      final value = decoded[key];
      if (value is! String || value.isEmpty) {
        throw BuildException(
          'Shanlian manifest field "$key" is missing. $_refuseStockCore',
        );
      }
      return value;
    }

    final commit = requireString('mihomo_commit');
    final digest = requireString('patch_sha256');
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      throw BuildException(
        'Shanlian manifest mihomo_commit is not a 40-character SHA. $_refuseStockCore',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw BuildException(
        'Shanlian manifest patch_sha256 is not a 64-character SHA-256. $_refuseStockCore',
      );
    }
    return ShanlianManifest(
      mihomoCommit: commit,
      patchName: requireString('patch'),
      patchSha256: digest,
      markerFile: requireString('applied_marker_file'),
      markerText: requireString('applied_marker'),
      versionSuffix: requireString('version_suffix'),
    );
  }
}

class ShanlianCorePrepare {
  final String projectRoot;
  final String? packageDir;
  final String? cacheRoot;
  final String? mihomoSource;
  final Future<void> Function()? afterCopy;

  static final Map<String, Future<void>> _tails = {};

  ShanlianCorePrepare({
    required this.projectRoot,
    this.packageDir,
    this.cacheRoot,
    this.mihomoSource,
    this.afterCopy,
  });

  String get _packageDir =>
      packageDir ?? p.join(projectRoot, 'core', 'shanlian');
  String get _cacheRoot =>
      cacheRoot ?? p.join(projectRoot, 'build', 'shanlian-core');
  String get _source =>
      mihomoSource ?? p.join(projectRoot, 'core', 'Clash.Meta');

  Future<PreparedShanlianCore> prepare() {
    return _serialize(_cacheRoot, _prepareLocked);
  }

  Future<PreparedShanlianCore> _prepareLocked() async {
    final manifest = ShanlianManifest.load(_packageDir);
    final patchFile = File(p.join(_packageDir, manifest.patchName));
    if (!patchFile.existsSync()) {
      throw BuildException(
        'Shanlian patch is missing: ${patchFile.path}. $_refuseStockCore',
      );
    }
    final actualSha = sha256.convert(patchFile.readAsBytesSync()).toString();
    if (actualSha != manifest.patchSha256) {
      throw BuildException(
        'Shanlian patch SHA-256 mismatch: expected ${manifest.patchSha256}, got $actualSha. $_refuseStockCore',
      );
    }

    final head = _git(['rev-parse', 'HEAD'], _source).trim();
    if (head != manifest.mihomoCommit) {
      throw BuildException(
        'Mihomo baseline mismatch: HEAD $head, manifest ${manifest.mihomoCommit}. $_refuseStockCore',
      );
    }

    final bridgeSha = bridgeContentFingerprint(p.join(projectRoot, 'core'));
    final cacheKey = sha256
        .convert(utf8.encode(
          '${manifest.mihomoCommit}\n${manifest.patchSha256}\n$bridgeSha',
        ))
        .toString()
        .substring(0, 20);
    final cacheDir = Directory(p.join(_cacheRoot, cacheKey));
    final mihomoDir = Directory(p.join(cacheDir.path, 'mihomo'));
    final moduleDir = Directory(p.join(cacheDir.path, 'core'));
    final readyFile = File(p.join(cacheDir.path, 'READY'));

    if (_cacheReady(readyFile, manifest, mihomoDir, moduleDir, bridgeSha)) {
      return _result(manifest, mihomoDir.path, moduleDir.path);
    }

    final lockFile = File(p.join(_cacheRoot, 'prepare.lock'));
    lockFile.parent.createSync(recursive: true);
    final lock = await lockFile.open(mode: FileMode.write);
    await lock.lock();
    try {
      if (_cacheReady(readyFile, manifest, mihomoDir, moduleDir, bridgeSha)) {
        return _result(manifest, mihomoDir.path, moduleDir.path);
      }
      if (cacheDir.existsSync()) {
        cacheDir.deleteSync(recursive: true);
      }
      cacheDir.createSync(recursive: true);
      try {
        await _archiveSource(mihomoDir);
        _applyPatch(mihomoDir.path, patchFile.path);
        _assertMarker(mihomoDir.path, manifest);
        _copyModule(moduleDir.path, mihomoDir.path);
        if (afterCopy != null) {
          await afterCopy!();
        }
        readyFile.writeAsStringSync(jsonEncode({
          'mihomo_commit': manifest.mihomoCommit,
          'patch_sha256': manifest.patchSha256,
          'bridge_sha256': bridgeSha,
        }));
      } catch (error) {
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
        if (error is BuildException) rethrow;
        throw BuildException(
          'Failed to prepare the shanlian Android core: $error. $_refuseStockCore',
        );
      }
      return _result(manifest, mihomoDir.path, moduleDir.path);
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  PreparedShanlianCore _result(
    ShanlianManifest manifest,
    String mihomoDir,
    String moduleDir,
  ) {
    return PreparedShanlianCore(
      moduleDir: moduleDir,
      mihomoDir: mihomoDir,
      shanlianVersion: _shanlianVersion(mihomoDir, manifest.versionSuffix),
      mihomoCommit: manifest.mihomoCommit,
      patchSha256: manifest.patchSha256,
    );
  }

  bool _cacheReady(
    File readyFile,
    ShanlianManifest manifest,
    Directory mihomoDir,
    Directory moduleDir,
    String bridgeSha,
  ) {
    if (!readyFile.existsSync() || !mihomoDir.existsSync() || !moduleDir.existsSync()) {
      return false;
    }
    try {
      final decoded = jsonDecode(readyFile.readAsStringSync());
      if (decoded is! Map ||
          decoded['mihomo_commit'] != manifest.mihomoCommit ||
          decoded['patch_sha256'] != manifest.patchSha256 ||
          decoded['bridge_sha256'] != bridgeSha) {
        return false;
      }
      final marker = File(p.join(mihomoDir.path, manifest.markerFile));
      if (!marker.existsSync() || !marker.readAsStringSync().contains(manifest.markerText)) {
        return false;
      }
      final goMod = File(p.join(moduleDir.path, 'go.mod'));
      final text = goMod.readAsStringSync();
      return text.contains('replace github.com/metacubex/mihomo => ../mihomo') &&
          !text.contains('=> ./Clash.Meta');
    } catch (_) {
      return false;
    }
  }

  Future<void> _archiveSource(Directory destination) async {
    destination.createSync(recursive: true);
    final tarFile = File(p.join(destination.parent.path, 'source.tar'));
    _git([
      '-c',
      'core.autocrlf=false',
      'archive',
      '--format=tar',
      '-o',
      tarFile.path,
      'HEAD',
    ], _source);
    final result = await Process.run(
      'tar',
      ['-xf', tarFile.path, '-C', destination.path],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (tarFile.existsSync()) {
      tarFile.deleteSync();
    }
    if (result.exitCode != 0) {
      throw BuildException(
        'Failed to extract the Mihomo archive: ${result.stderr}. $_refuseStockCore',
      );
    }
  }

  void _applyPatch(String mihomoDir, String patchPath) {
    final ceiling = p.dirname(mihomoDir);
    _git([
      '-c',
      'core.autocrlf=false',
      'apply',
      '--check',
      patchPath,
    ], mihomoDir, environment: {'GIT_CEILING_DIRECTORIES': ceiling});
    _git([
      '-c',
      'core.autocrlf=false',
      'apply',
      '--verbose',
      patchPath,
    ], mihomoDir, environment: {'GIT_CEILING_DIRECTORIES': ceiling});
  }

  void _assertMarker(String mihomoDir, ShanlianManifest manifest) {
    final marker = File(p.join(mihomoDir, manifest.markerFile));
    if (!marker.existsSync() || !marker.readAsStringSync().contains(manifest.markerText)) {
      throw BuildException(
        'Shanlian patch did not produce the expected marker ${manifest.markerFile}. $_refuseStockCore',
      );
    }
  }

  void _copyModule(String moduleDir, String mihomoDir) {
    final source = p.join(projectRoot, 'core');
    final files = listBridgeFiles(source);
    Directory(moduleDir).createSync(recursive: true);
    for (final file in files) {
      final rel = p.relative(file.path, from: source);
      final target = File(p.join(moduleDir, rel));
      target.parent.createSync(recursive: true);
      file.copySync(target.path);
    }
    final goMod = File(p.join(moduleDir, 'go.mod'));
    if (!goMod.existsSync()) {
      throw BuildException('core/go.mod is missing. $_refuseStockCore');
    }
    const needle = 'replace github.com/metacubex/mihomo => ./Clash.Meta';
    final text = goMod.readAsStringSync();
    if (!text.contains(needle)) {
      throw BuildException(
        'core/go.mod does not contain the expected Mihomo replace. $_refuseStockCore',
      );
    }
    goMod.writeAsStringSync(
      text.replaceFirst(needle, 'replace github.com/metacubex/mihomo => ../mihomo'),
    );
    if (!File(p.join(mihomoDir, 'go.mod')).existsSync()) {
      throw BuildException(
        'Prepared Mihomo module is missing go.mod. $_refuseStockCore',
      );
    }
  }

  String _shanlianVersion(String mihomoDir, String suffix) {
    final file = File(p.join(mihomoDir, 'constant', 'version.go'));
    if (!file.existsSync()) {
      throw BuildException(
        'Mihomo version file is missing: ${file.path}. $_refuseStockCore',
      );
    }
    final match = RegExp(r'Version\s*=\s*"([^"]+)"')
        .firstMatch(file.readAsStringSync());
    if (match == null) {
      throw BuildException(
        'Mihomo version string was not found. $_refuseStockCore',
      );
    }
    final version = match.group(1)!;
    if (version.contains(suffix)) return version;
    return '$version-$suffix';
  }

  String _git(
    List<String> args,
    String workingDirectory, {
    Map<String, String>? environment,
  }) {
    final result = Process.runSync(
      'git',
      ['-C', workingDirectory, ...args],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: environment,
    );
    final stderr = (result.stderr as String).trim();
    if (result.exitCode != 0 || stderr.contains('Skipped patch')) {
      throw BuildException(
        'git ${args.join(' ')} failed in $workingDirectory: $stderr $_refuseStockCore',
      );
    }
    return result.stdout as String;
  }

  static Future<T> _serialize<T>(
    String key,
    Future<T> Function() action,
  ) {
    final previous = _tails[key] ?? Future<void>.value();
    final gate = previous.catchError((Object _) {}).then((_) => action());
    _tails[key] = gate.then((_) {}, onError: (Object _) {});
    return gate;
  }
}
