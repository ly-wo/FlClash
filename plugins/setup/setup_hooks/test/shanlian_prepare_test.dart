import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/error.dart';
import 'package:setup_hooks/src/shanlian_prepare.dart';
import 'package:test/test.dart';

void main() {
  group('shanlian core preparation', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('shanlian-prepare-');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('prepares an isolated copy and reuses it', () async {
      final sourceStatus = _initFixture(root);
      final prepare = ShanlianCorePrepare(projectRoot: root.path);
      final first = await prepare.prepare();
      File(p.join(first.mihomoDir, 'extra.txt')).writeAsStringSync('keep');

      final second = await prepare.prepare();

      expect(second.moduleDir, first.moduleDir);
      expect(File(p.join(first.mihomoDir, 'extra.txt')).existsSync(), isTrue);
      expect(File(p.join(first.mihomoDir, 'hello.txt')).readAsStringSync(),
          contains('patched-marker'));
      expect(File(p.join(first.mihomoDir, 'local-only.txt')).existsSync(),
          isFalse);
      expect(
        File(p.join(root.path, 'core', 'Clash.Meta', 'hello.txt'))
            .readAsStringSync(),
        contains('dirty-worktree'),
      );
      expect(
        File(p.join(root.path, 'core', 'go.mod')).readAsStringSync(),
        contains('=> ./Clash.Meta'),
      );
      expect(
        File(p.join(first.moduleDir, 'go.mod')).readAsStringSync(),
        contains('=> ../mihomo'),
      );
      expect(first.shanlianVersion, '9.9.9-shanlian');
      expect(File(p.join(first.mihomoDir, 'constant', 'version.go')).readAsStringSync(),
          contains('1.10.0'));
      expect(first.ldflags('-w -s'),
          contains('constant.Version=9.9.9-shanlian'));
      expect(_status(p.join(root.path, 'core', 'Clash.Meta')), sourceStatus);
    });

    test('rebuilds when an uncommitted bridge file changes', () async {
      _initFixture(root);
      final prepare = ShanlianCorePrepare(projectRoot: root.path);
      final first = await prepare.prepare();
      final mainFile = File(p.join(root.path, 'core', 'main.go'));
      final original = mainFile.readAsStringSync();
      File(p.join(first.moduleDir, 'sentinel.txt')).writeAsStringSync('old');

      mainFile.writeAsStringSync('$original// uncommitted bridge change\n');
      final second = await prepare.prepare();

      expect(second.moduleDir, isNot(first.moduleDir));
      expect(
        File(p.join(second.moduleDir, 'main.go')).readAsStringSync(),
        contains('uncommitted bridge change'),
      );
      expect(File(p.join(second.moduleDir, 'sentinel.txt')).existsSync(), isFalse);
      expect(File(p.join(first.moduleDir, 'sentinel.txt')).existsSync(), isTrue);

      mainFile.writeAsStringSync(original);
      final third = await prepare.prepare();
      expect(third.moduleDir, first.moduleDir);
      expect(File(p.join(third.moduleDir, 'sentinel.txt')).readAsStringSync(), 'old');
      expect(File(p.join(third.moduleDir, 'main.go')).readAsStringSync(), original);
    });

    test('rebuilds when the prepared marker is missing', () async {
      _initFixture(root);
      final prepare = ShanlianCorePrepare(projectRoot: root.path);
      final first = await prepare.prepare();
      File(p.join(first.mihomoDir, 'extra.txt')).writeAsStringSync('gone');
      File(p.join(first.mihomoDir, 'hello.txt')).writeAsStringSync('broken');

      final second = await prepare.prepare();

      expect(File(p.join(second.mihomoDir, 'extra.txt')).existsSync(), isFalse);
      expect(File(p.join(second.mihomoDir, 'hello.txt')).readAsStringSync(),
          contains('patched-marker'));
    });

    test('parallel prepare copies once', () async {
      _initFixture(root);
      var copies = 0;
      final prepare = ShanlianCorePrepare(
        projectRoot: root.path,
        afterCopy: () async {
          copies += 1;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        },
      );

      final results = await Future.wait([prepare.prepare(), prepare.prepare()]);

      expect(copies, 1);
      expect(results[0].moduleDir, results[1].moduleDir);
    });

    test('appends the suffix to the configured core version', () async {
      _initFixture(root);
      File(p.join(root.path, 'build_config.yaml')).writeAsStringSync(
        'core_version: v1.19.32\n',
      );

      final prepared = await ShanlianCorePrepare(projectRoot: root.path).prepare();

      expect(prepared.shanlianVersion, 'v1.19.32-shanlian');
      expect(prepared.ldflags('-w -s'),
          contains('constant.Version=v1.19.32-shanlian'));

      File(p.join(root.path, 'build_config.yaml')).writeAsStringSync(
        'core_version: v1.19.32-shanlian\n',
      );
      final preserved = await ShanlianCorePrepare(projectRoot: root.path).prepare();
      expect(preserved.shanlianVersion, 'v1.19.32-shanlian');
    });

    test('rejects a patch digest mismatch without changing the source', () async {
      final status = _initFixture(root);
      File(p.join(root.path, 'core', 'shanlian', 'manifest.json'))
          .writeAsStringSync(_manifest('0' * 64));

      await expectLater(
        ShanlianCorePrepare(projectRoot: root.path).prepare(),
        throwsA(isA<BuildException>()),
      );
      expect(_status(p.join(root.path, 'core', 'Clash.Meta')), status);
      final cache = Directory(p.join(root.path, 'build', 'shanlian-core'));
      if (cache.existsSync()) {
        expect(
          cache
              .listSync()
              .where((entity) => p.basename(entity.path) != 'prepare.lock'),
          isEmpty,
        );
      }
    });

    test('rejects the wrong Mihomo baseline', () async {
      _initFixture(root);
      final manifest = File(p.join(root.path, 'core', 'shanlian', 'manifest.json'));
      manifest.writeAsStringSync(
        manifest.readAsStringSync().replaceAll(
              RegExp(r'"mihomo_commit": "[0-9a-f]{40}"'),
              '"mihomo_commit": "${'a' * 40}"',
            ),
      );

      await expectLater(
        ShanlianCorePrepare(projectRoot: root.path).prepare(),
        throwsA(predicate((error) =>
            error is BuildException &&
            error.toString().contains('baseline mismatch'))),
      );
    });

    test('rejects a missing patch and a patch that does not apply', () async {
      _initFixture(root);
      final patch = File(p.join(root.path, 'core', 'shanlian', 'fixture.patch'));
      patch.deleteSync();
      await expectLater(
        ShanlianCorePrepare(projectRoot: root.path).prepare(),
        throwsA(isA<BuildException>()),
      );

      _initFixture(root, reset: true);
      const badPatch = '''
diff --git a/missing.txt b/missing.txt
--- a/missing.txt
+++ b/missing.txt
@@ -1 +1 @@
-absent
+present
''';
      patch.writeAsStringSync(badPatch);
      final manifest = File(p.join(root.path, 'core', 'shanlian', 'manifest.json'));
      manifest.writeAsStringSync(manifest.readAsStringSync().replaceAll(
            RegExp(r'"patch_sha256": "[0-9a-f]{64}"'),
            '"patch_sha256": "${crypto.sha256.convert(patch.readAsBytesSync())}"',
          ));
      await expectLater(
        ShanlianCorePrepare(projectRoot: root.path).prepare(),
        throwsA(isA<BuildException>()),
      );
      expect(
        File(p.join(root.path, 'core', 'Clash.Meta', 'hello.txt'))
            .readAsStringSync(),
        contains('dirty-worktree'),
      );
    });
  });
}

String _initFixture(Directory root, {bool reset = false}) {
  final meta = Directory(p.join(root.path, 'core', 'Clash.Meta'));
  if (reset && meta.existsSync()) {
    meta.deleteSync(recursive: true);
  }
  Directory(p.join(meta.path, 'constant')).createSync(recursive: true);
  File(p.join(meta.path, 'hello.txt')).writeAsStringSync('original\n');
  File(p.join(meta.path, 'constant', 'version.go')).writeAsStringSync(
    'package constant\n\nvar (\n\tVersion = "1.10.0"\n)\n',
  );
  File(p.join(root.path, 'build_config.yaml')).writeAsStringSync(
    'core_version: 9.9.9\n',
  );
  File(p.join(meta.path, 'go.mod')).writeAsStringSync('module example.com/fixture\n\ngo 1.21\n');
  _git(meta.path, ['init']);
  _git(meta.path, ['add', 'hello.txt', 'constant/version.go', 'go.mod']);
  _git(meta.path, [
    '-c',
    'user.email=dev@example.com',
    '-c',
    'user.name=dev',
    'commit',
    '-m',
    'init',
  ]);
  final head = _git(meta.path, ['rev-parse', 'HEAD']).trim();
  File(p.join(meta.path, 'hello.txt')).writeAsStringSync('dirty-worktree\n');
  File(p.join(meta.path, 'local-only.txt')).writeAsStringSync('untracked\n');

  final package = Directory(p.join(root.path, 'core', 'shanlian'))
    ..createSync(recursive: true);
  final patch = File(p.join(package.path, 'fixture.patch'));
  patch.writeAsStringSync('''
diff --git a/hello.txt b/hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-original
+patched-marker
''');
  File(p.join(package.path, 'manifest.json')).writeAsStringSync(_manifest(
    _sha256(patch),
    commit: head,
  ));
  File(p.join(root.path, 'core', 'go.mod')).writeAsStringSync(
    'module core\n\ngo 1.21\n\nreplace github.com/metacubex/mihomo => ./Clash.Meta\n',
  );
  File(p.join(root.path, 'core', 'go.sum')).writeAsStringSync('');
  File(p.join(root.path, 'core', 'main.go')).writeAsStringSync('package main\n');
  return _status(meta.path);
}

String _manifest(String digest, {String commit = ''}) {
  final resolved = commit.isEmpty ? 'b' * 40 : commit;
  return '''
{
  "schema": 1,
  "mihomo_commit": "$resolved",
  "patch": "fixture.patch",
  "patch_sha256": "$digest",
  "applied_marker_file": "hello.txt",
  "applied_marker": "patched-marker",
  "version_suffix": "shanlian"
}
''';
}

String _sha256(File file) =>
    crypto.sha256.convert(file.readAsBytesSync()).toString();

String _git(String workingDirectory, List<String> args) {
  final result = Process.runSync(
    'git',
    ['-C', workingDirectory, ...args],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (result.exitCode != 0) {
    throw Exception('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

String _status(String workingDirectory) {
  return _git(workingDirectory, ['status', '--porcelain']);
}
