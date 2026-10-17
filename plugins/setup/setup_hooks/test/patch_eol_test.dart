import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('a fresh autocrlf checkout keeps the patch LF bytes', () {
    final root = _flclashRoot();
    final source = File(p.join(root, 'core', 'shanlian', 'flclash-anytls-auth.patch'));
    final attributes = File(p.join(root, '.gitattributes'));
    final original = source.readAsBytesSync();
    expect(original.contains(13), isFalse);
    expect(
      attributes.readAsStringSync(),
      contains('core/shanlian/flclash-anytls-auth.patch text eol=lf'),
    );

    final work = Directory.systemTemp.createTempSync('patch-eol-');
    try {
      final repo = Directory(p.join(work.path, 'repo'));
      final patch = File(p.join(repo.path, 'core', 'shanlian', 'flclash-anytls-auth.patch'));
      patch.parent.createSync(recursive: true);
      patch.writeAsBytesSync(original);
      File(p.join(repo.path, '.gitattributes')).writeAsStringSync(
        'core/shanlian/flclash-anytls-auth.patch text eol=lf\n',
      );
      _git(repo.path, ['init']);
      _git(repo.path, ['add', '.gitattributes', 'core/shanlian/flclash-anytls-auth.patch']);
      _git(repo.path, [
        '-c',
        'user.email=dev@example.com',
        '-c',
        'user.name=dev',
        'commit',
        '-m',
        'patch',
      ]);

      final checkout = p.join(work.path, 'checkout');
      final cloned = Process.runSync(
        'git',
        ['-c', 'core.autocrlf=true', 'clone', repo.path, checkout],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
      expect(cloned.exitCode, 0, reason: cloned.stderr as String);
      final checkedOut = File(p.join(checkout, 'core', 'shanlian', 'flclash-anytls-auth.patch'))
          .readAsBytesSync();
      expect(checkedOut, original);
      expect(sha256.convert(checkedOut).toString(), sha256.convert(original).toString());
    } finally {
      work.deleteSync(recursive: true);
    }
  });
}

String _flclashRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'core', 'shanlian', 'manifest.json')).existsSync() &&
        File(p.join(dir.path, '.gitattributes')).existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) {
      throw StateError('FlClash root was not found from ${Directory.current.path}');
    }
    dir = dir.parent;
  }
}

void _git(String workingDirectory, List<String> args) {
  final result = Process.runSync(
    'git',
    ['-C', workingDirectory, ...args],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (result.exitCode != 0) {
    throw Exception('git ${args.join(' ')} failed: ${result.stderr}');
  }
}
