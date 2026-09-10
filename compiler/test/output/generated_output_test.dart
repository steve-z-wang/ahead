import 'dart:io';

import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory output;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('local-sync-output-');
    output = Directory('${temporary.path}/generated')..createSync();
    File('${output.path}/stale.dart').writeAsStringSync('stale');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('formats output and removes stale generated files', () async {
    await GeneratedOutput.replace(output.path, {
      'nested/value.dart': 'final value=<String>["x"];',
    });

    expect(File('${output.path}/stale.dart').existsSync(), isFalse);
    expect(
      File('${output.path}/nested/value.dart').readAsStringSync(),
      'final value = <String>["x"];\n',
    );
  });

  test('formats for the Dart 3.10 consumer language version', () {
    final formatted = GeneratedOutput.prepare({
      'value.dart': '''
Future<void> create({
  required Object requestId,
  required Object userId,
  required Object decision,
  required Object requiredAt,
  required Object decidedAt,
  required Object withdrawnAt,
}) => writer.create(
  SpaceVisibilityConsentId(requestId: requestId, userId: userId),
  {
    'decision': decision,
    'requiredAt': requiredAt,
    'decidedAt': decidedAt,
    'withdrawnAt': withdrawnAt,
  },
);
''',
    })['value.dart']!;

    expect(formatted, contains('=> writer\n    .create('));
  });

  test('rejects unsafe paths without changing existing output', () async {
    await expectLater(
      () => GeneratedOutput.replace(output.path, {
        '../outside.dart': 'final value = 1;',
      }),
      throwsArgumentError,
    );

    expect(File('${output.path}/stale.dart').readAsStringSync(), 'stale');
    expect(File('${temporary.path}/outside.dart').existsSync(), isFalse);
  });

  test('invalid Dart leaves existing output intact', () async {
    await expectLater(
      () => GeneratedOutput.replace(output.path, {'bad.dart': 'final = ;'}),
      throwsA(anything),
    );

    expect(File('${output.path}/stale.dart').readAsStringSync(), 'stale');
  });
}
