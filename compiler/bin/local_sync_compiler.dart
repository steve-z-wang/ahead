import 'dart:io';

import 'package:local_sync_compiler/src/cli.dart';

Future<void> main(List<String> arguments) async {
  try {
    await runLocalSyncCompiler(arguments);
  } catch (error) {
    stderr.writeln(error);
    exitCode = 64;
  }
}
