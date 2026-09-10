import 'dart:io';

import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  test('creates parents and atomically replaces one generated file', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'local-sync-generated-file-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final output = File('${temporary.path}/nested/model-contract.json');

    await GeneratedFile.replace(output.path, 'first\n');
    expect(await output.readAsString(), 'first\n');

    await GeneratedFile.replace(output.path, 'second\n');
    expect(await output.readAsString(), 'second\n');
    expect(
      await output.parent
          .list()
          .map((entity) => entity.path)
          .where((path) => path != output.path)
          .toList(),
      isEmpty,
    );
  });

  test(
    'leaves the previous file intact when replacement cannot start',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'local-sync-generated-file-',
      );
      addTearDown(() async {
        await Process.run('chmod', ['700', temporary.path]);
        await temporary.delete(recursive: true);
      });
      final output = File('${temporary.path}/model-contract.json');
      await output.writeAsString('existing\n');
      await Process.run('chmod', ['500', temporary.path]);

      await expectLater(
        () => GeneratedFile.replace(output.path, 'replacement\n'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await output.readAsString(), 'existing\n');
    },
  );
}
