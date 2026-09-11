import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:local_first_state/local_first_state.dart';
import 'package:test/test.dart';

void main() {
  test('default native loader is reserved for iOS process symbols', () async {
    if (Platform.isIOS) return;
    await expectLater(
      Client.open(path: 'unused', schema: const {}, owner: 'u'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('libraryPath'),
        ),
      ),
    );
  });
  test(
    'Dart callbacks read their writes, rollback and reopen through native Rust',
    () async {
      final dir = await Directory.systemTemp.createTemp('lfs-dart-test-');
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final path = '${dir.path}/db';
      var client = await Client.open(
        path: path,
        schema: schema,
        owner: 'u',
        libraryPath: Platform.environment['LFS_LIBRARY']!,
      );
      try {
        await client.transaction((tx) async {
          await tx.direct({
            'model': 'Entry',
            'op': 'create',
            'identity': {'id': 'e'},
            'values': {'text': 'hello'},
          });
          expect((await tx.read('Entry', {'id': 'e'}))!['text'], 'hello');
        });
        await expectLater(
          client.transaction((tx) async {
            await tx.direct({
              'model': 'Entry',
              'op': 'update',
              'identity': {'id': 'e'},
              'values': {'text': 'bad'},
            });
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect((await client.read('Entry', {'id': 'e'}))!['text'], 'hello');
        await expectLater(
          client.transaction((tx) async {
            tx.direct({
              'model': 'Entry',
              'op': 'update',
              'identity': {'id': 'e'},
              'values': {'text': 'forgotten'},
            });
          }),
          throwsStateError,
        );
        expect((await client.read('Entry', {'id': 'e'}))!['text'], 'hello');
        await expectLater(
          client.transaction((tx) async {
            try {
              await tx.direct({
                'model': 'Entry',
                'op': 'create',
                'identity': {'id': 'e'},
                'values': {'text': 'duplicate'},
              });
            } catch (_) {}
            ;
          }),
          throwsStateError,
        );
        await client.transaction((tx) async {
          try {
            await tx.savepoint(() async {
              await tx.direct({
                'model': 'Entry',
                'op': 'update',
                'identity': {'id': 'e'},
                'values': {'text': 'savepoint'},
              });
              throw StateError('rollback');
            });
          } catch (_) {}
          ;
        });
        expect((await client.read('Entry', {'id': 'e'}))!['text'], 'hello');
        await expectLater(
          client.transaction((tx) async {
            final gate = Completer<void>();
            Future<void>? child;
            try {
              await tx.savepoint(() async {
                await tx.direct({
                  'model': 'Entry',
                  'op': 'update',
                  'identity': {'id': 'e'},
                  'values': {'text': 'outer'},
                });
                child = tx
                    .savepoint<void>(() async {
                      await gate.future;
                      throw StateError('late child');
                    })
                    .catchError((Object _) {});
              });
            } catch (_) {}
            gate.complete();
            await child;
          }),
          throwsStateError,
        );
        expect((await client.read('Entry', {'id': 'e'}))!['text'], 'hello');
        await client.mutate({
          'name': 'Edit',
          'operations': [
            {
              'model': 'Entry',
              'op': 'update',
              'identity': {'id': 'e'},
              'values': {'text': 'offline'},
            },
          ],
        });
        final frozen = await client.freeze();
        await client.close();
        client = await Client.open(
          path: path,
          schema: schema,
          owner: 'u',
          libraryPath: Platform.environment['LFS_LIBRARY']!,
        );
        expect(await client.freeze(), frozen);
        expect((await client.read('Entry', {'id': 'e'}))!['text'], 'offline');
        await client.close();
        await expectLater(client.read('Entry', {'id': 'e'}), throwsStateError);
      } finally {
        await client.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
