import 'dart:io';

import 'package:path/path.dart' as path;

final class GeneratedFile {
  const GeneratedFile._();

  static Future<void> replace(String outputPath, String contents) async {
    final output = File(path.absolute(outputPath));
    final parent = output.parent;
    await parent.create(recursive: true);
    final suffix = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final temporary = File(
      path.join(parent.path, '.${path.basename(output.path)}.tmp-$suffix'),
    );
    final backup = File(
      path.join(parent.path, '.${path.basename(output.path)}.old-$suffix'),
    );

    try {
      await temporary.writeAsString(contents, flush: true);
      final hadOutput = await output.exists();
      if (hadOutput) await output.rename(backup.path);
      try {
        await temporary.rename(output.path);
      } catch (_) {
        if (hadOutput && await backup.exists()) {
          await backup.rename(output.path);
        }
        rethrow;
      }
      if (await backup.exists()) await backup.delete();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
