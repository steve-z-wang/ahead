import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

final class GeneratedOutput {
  const GeneratedOutput._();

  static Future<void> replace(
    String outputPath,
    Map<String, String> sources,
  ) async {
    final formatted = prepare(sources);

    final output = Directory(path.absolute(outputPath));
    final parent = output.parent;
    await parent.create(recursive: true);
    final suffix = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final temporary = Directory(
      path.join(parent.path, '.${path.basename(output.path)}.tmp-$suffix'),
    );
    final backup = Directory(
      path.join(parent.path, '.${path.basename(output.path)}.old-$suffix'),
    );

    await temporary.create();
    try {
      for (final entry in formatted.entries) {
        final file = File(path.join(temporary.path, entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value, flush: true);
      }

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
      if (await backup.exists()) await backup.delete(recursive: true);
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  static Map<String, String> prepare(Map<String, String> sources) {
    final formatter = DartFormatter(
      // Every generated LocalSync Dart package currently declares ^3.10.3.
      // Formatting at the formatter library's newest understood version can
      // produce a different layout from `dart format` in those consumers.
      languageVersion: Version(3, 10, 0),
    );
    final formatted = <String, String>{};
    for (final entry in sources.entries) {
      _validatePath(entry.key);
      formatted[entry.key] = entry.key.endsWith('.dart')
          ? formatter.format(entry.value)
          : entry.value;
    }
    return Map.unmodifiable(formatted);
  }

  static void _validatePath(String relativePath) {
    final normalized = path.posix.normalize(relativePath);
    if (relativePath.isEmpty ||
        relativePath.contains('\\') ||
        path.posix.isAbsolute(relativePath) ||
        normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized != relativePath) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'must be a normalized relative generated path',
      );
    }
  }
}
