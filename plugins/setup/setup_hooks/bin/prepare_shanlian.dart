import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:setup_hooks/src/shanlian_prepare.dart';

Future<void> main(List<String> args) async {
  final rootFlag = args.indexOf('--root-dir');
  if (rootFlag == -1 || rootFlag + 1 >= args.length) {
    stderr.writeln('usage: dart run bin/prepare_shanlian.dart --root-dir <FlClash>');
    exitCode = 64;
    return;
  }
  final root = p.normalize(args[rootFlag + 1]);
  final prepared = await ShanlianCorePrepare(projectRoot: root).prepare();
  final marker = File(
    p.join(prepared.mihomoDir, 'transport', 'anytls', 'client.go'),
  );
  if (!marker.existsSync() ||
      !marker.readAsStringSync().contains('func (c *Client) authentication')) {
    stderr.writeln(
      'Prepared Mihomo is missing the shanlian authentication marker. '
      'Android build stops instead of using the unmodified core.',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln('MODULE_DIR=${prepared.moduleDir}');
  stdout.writeln('VERSION=${prepared.shanlianVersion}');
}
