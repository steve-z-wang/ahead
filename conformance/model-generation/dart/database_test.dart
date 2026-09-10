import 'dart:io';

import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('local_sync_test_');
    path = '${directory.path}/nested/local-sync.sqlite';
  });

  tearDown(() => directory.delete(recursive: true));

  test('test database disposal is safe under concurrent cleanup', () async {
    final fixture = await TestDatabase.create();

    await Future.wait([fixture.dispose(), fixture.dispose()]);
  });

  test(
    'creates parent directories and preserves committed state on reopen',
    () async {
      final id = UserId(uuid(1));
      final noteId = LocalNoteId(uuid(2));
      var localSync = await LocalSync.open(
        driver: localSyncDatabaseDriver(path: path),
        clientId: testClientId,
        transport: successLocalSyncTransport,
        prerequisites: readyPrerequisites(),
      );
      await activateTestScopes(localSync);
      await localSync.transaction(
        (outerTx) => outerTx.mutate.registerUser(
          (tx) async => (user: User.create(id: id.value, handle: 'persistent')),
        ),
      );
      await localSync.transaction(
        (tx) => tx.models.localNote.create(
          id: noteId.value,
          text: 'local persistent',
          status: LocalNoteStatus.archived,
        ),
      );
      await localSync.close();

      localSync = await LocalSync.open(
        driver: localSyncDatabaseDriver(path: path),
        clientId: testClientId,
        transport: successLocalSyncTransport,
        prerequisites: readyPrerequisites(),
      );
      await activateTestScopes(localSync);
      expect((await localSync.models.user.get(id))?.handle, 'persistent');
      expect(
        (await localSync.models.localNote.get(noteId))?.text,
        'local persistent',
      );
      await localSync.close();

      await expectLater(
        LocalSync.open(
          driver: localSyncDatabaseDriver(path: path),
          clientId: '4f41c5a7-cef8-460a-8089-417fbc90b895',
          transport: successLocalSyncTransport,
          prerequisites: readyPrerequisites(),
        ),
        throwsStateError,
      );

      final database = sqlite.sqlite3.open(path);
      addTearDown(database.close);
      final tables = database
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row['name'] as String)
          .toSet();
      expect(tables, contains('pending_mutation_operations'));
      expect(tables, contains('pending_mutation_prerequisites'));
      expect(tables, contains('pending_mutation_sequences'));
      expect(tables, contains('model_user'));
      expect(tables, contains('model_local_note'));
      expect(tables.where((name) => !name.startsWith('model_')).toSet(), {
        '_migrations',
        'downlink_scope_rows',
        'downlink_scope_state',
        // One named act, one record; the operations beneath it are the
        // letters it is spelled with (CAP-439).
        'pending_mutations',
        'mutation_rejections',
        'pending_mutation_operations',
        'pending_mutation_prerequisites',
        'pending_mutation_scopes',
        'pending_mutation_sequences',
        'readiness_states',
        'uplink_batches',
        'uplink_batch_checkpoints',
        'uplink_client_state',
        'sqlite_sequence',
      });
      expect(
        database
            .select('PRAGMA table_info(pending_mutation_operations)')
            .map((row) => row['name']),
        contains('slot_name'),
      );
      expect(
        database
            .select('PRAGMA table_info(pending_mutation_sequences)')
            .map((row) => row['name']),
        ['mutation_ordinal', 'predecessor_ordinal'],
      );
      expect(
        database
            .select('PRAGMA table_info(pending_mutation_prerequisites)')
            .map((row) => row['name']),
        ['mutation_ordinal', 'prerequisite_ordinal'],
      );
      expect(
        database.select(
          'SELECT scope, last_applied_sync_id '
          'FROM downlink_scope_state',
        ),
        [
          {'scope': testScope, 'last_applied_sync_id': 0},
        ],
      );
    },
  );

  test('unknown database version fails without rewriting its data', () async {
    await Directory('${directory.path}/nested').create(recursive: true);
    final database = sqlite.sqlite3.open(path);
    database.execute('CREATE TABLE sentinel (value TEXT NOT NULL)');
    database.execute("INSERT INTO sentinel VALUES ('keep')");
    database.execute(
      'CREATE TABLE _migrations('
      'id INTEGER PRIMARY KEY, down_migrations TEXT)',
    );
    database.execute('INSERT INTO _migrations VALUES (2, NULL)');
    database.close();

    await expectLater(
      LocalSync.open(
        driver: localSyncDatabaseDriver(path: path),
        clientId: testClientId,
        transport: successLocalSyncTransport,
        prerequisites: readyPrerequisites(),
      ),
      throwsA(anything),
    );

    final reopened = sqlite.sqlite3.open(path);
    addTearDown(reopened.close);
    expect(reopened.select('SELECT max(id) FROM _migrations').single[0], 2);
    expect(
      reopened.select('SELECT value FROM sentinel').single['value'],
      'keep',
    );
  });
}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
