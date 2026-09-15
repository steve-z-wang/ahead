import 'dart:convert';
import 'dart:io';
import 'package:ahead/ahead.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prerequisite failure stays optimistic and explicit retry unlocks the push',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ahead-dart-prerequisite-',
      );
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      schema['prerequisites'] = [
        {
          'name': 'Upload',
          'fields': [
            {'name': 'key', 'type': 'String'},
          ],
        },
      ];
      schema['requirements'] = [
        {
          'model': 'Entry',
          'field': 'note',
          'name': 'Upload',
          'arguments': {'key': 'self'},
        },
      ];
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      try {
        await client.transaction(
          (tx) => tx.direct({
            'model': 'Entry',
            'op': 'create',
            'identity': {'id': 'e'},
            'values': {'text': 'A'},
          }),
        );
        await client.mutate({
          'name': 'Edit',
          'operations': [
            {
              'model': 'Entry',
              'op': 'update',
              'identity': {'id': 'e'},
              'values': {'note': 'asset'},
            },
          ],
        });
        var calls = 0;
        final handlers = <String, Future<void> Function(Map<String, dynamic>)>{
          'Upload': (args) async {
            expect(args['key'], 'asset');
            if (++calls == 1) throw StateError('offline');
          },
        };
        await client.runPrerequisites(handlers);
        expect((await client.read('Entry', {'id': 'e'}))?['note'], 'asset');
        expect(
          await client.freeze(),
          isNull,
          reason: 'a failed prerequisite blocks the push',
        );
        final task = (await client.pendingTasks()).single;
        expect(task['state'], 'failed');
        expect(task['name'], 'Upload');
        await client.setReadiness(task['key'] as String, 'pending');
        await client.runPrerequisites(handlers);
        expect(calls, 2);
        expect(await client.freeze(), isNotNull);
        expect(await client.pendingTasks(), isEmpty);
        await expectLater(
          client.runPrerequisites({}),
          completes,
          reason: 'nothing pending needs no handler',
        );
      } finally {
        await client.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
