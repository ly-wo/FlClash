import 'dart:io';

import 'package:setup_hooks/src/shanlian_prepare.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('prepares the locked FlClash Mihomo tree without touching it', () async {
    final root = _flclashRoot();
    final meta = p.join(root, 'core', 'Clash.Meta');
    final before = _git(meta, ['status', '--porcelain']);
    final original = File(p.join(meta, 'transport', 'anytls', 'client.go'))
        .readAsStringSync();
    expect(original.contains('func (c *Client) authentication'), isFalse);

    final prepared = await ShanlianCorePrepare(projectRoot: root).prepare();

    expect(prepared.mihomoCommit, '8380d0e7462f061a964323e9bf3129a236fcc5d5');
    expect(prepared.shanlianVersion, '1.10.0-shanlian');
    expect(
      File(p.join(prepared.mihomoDir, 'transport', 'anytls', 'client.go'))
          .readAsStringSync(),
      contains('func (c *Client) authentication'),
    );
    expect(
      File(p.join(meta, 'transport', 'anytls', 'client.go')).readAsStringSync(),
      original,
    );
    expect(_git(meta, ['status', '--porcelain']), before);
    expect(_git(root, ['diff', '--', 'core/go.mod']), isEmpty);
    expect(
      File(p.join(prepared.moduleDir, 'go.mod')).readAsStringSync(),
      contains('replace github.com/metacubex/mihomo => ../mihomo'),
    );

    final again = await ShanlianCorePrepare(projectRoot: root).prepare();
    expect(again.moduleDir, prepared.moduleDir);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String _flclashRoot() {
  var dir = Directory.current;
  while (true) {
    final manifest = File(p.join(dir.path, 'core', 'shanlian', 'manifest.json'));
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    if (manifest.existsSync() && pubspec.existsSync()) return dir.path;
    if (dir.parent.path == dir.path) {
      throw StateError('FlClash root was not found from ${Directory.current.path}');
    }
    dir = dir.parent;
  }
}

String _git(String workingDirectory, List<String> args) {
  final result = Process.runSync(
    'git',
    ['-C', workingDirectory, ...args],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (result.exitCode != 0) {
    throw Exception(result.stderr);
  }
  return (result.stdout as String).trim();
}
