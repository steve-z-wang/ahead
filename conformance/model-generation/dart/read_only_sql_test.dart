import 'dart:async';

import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import 'support.dart';

/// CAP-393 spec §8: the door that makes the materialized view reachable.
void main() {
  late LocalSync localSync;
  late TestDatabase database;
  late CapturingDriver driver;

  final userId = UserId(uuid(1));
  final spaceId = SpaceId(uuid(2));
  final noteId = LocalNoteId(uuid(3));

  setUp(() async {
    database = await TestDatabase.create();
    driver = CapturingDriver(database.driver);
    localSync = await LocalSync.open(
      driver: driver,
      clientId: testClientId,
      transport: SuccessLocalSyncTransport(),
      prerequisites: readyPrerequisites(),
    );
    await activateTestScopes(localSync);
    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await localSync.transaction(
      (tx) => tx.models.localNote.create(
        id: noteId.value,
        text: 'Device only',
        status: LocalNoteStatus.active,
      ),
    );
  });

  tearDown(() async {
    await localSync.close();
    await database.dispose();
  });

  test('reads the optimistic state the typed readers read', () async {
    await localSync.transaction(
      (outerTx) => outerTx.mutate.renameSpace(
        (tx) async => (
          space: tx.space.update(
            (await tx.models.space.get(spaceId))!,
            name: 'Renamed',
          ),
        ),
      ),
    );

    final rows = await localSync.readOnlySql.query(
      'SELECT name FROM model_space WHERE id = ?',
      [spaceId.value.uuid],
    );

    expect(rows.rows.single['name'], 'Renamed');
    expect((await localSync.models.space.get(spaceId))?.name, 'Renamed');
  });

  test('joins a synchronized Model to a local one', () async {
    // The single-database payoff: one query spanning replicated and
    // device-only rows, with no merge step anywhere.
    final rows = await localSync.readOnlySql.query('''
      SELECT model_space.name AS space_name, model_local_note.text AS note
      FROM model_space
      CROSS JOIN model_local_note
    ''');

    expect(rows.rows.single['space_name'], 'Family');
    expect(rows.rows.single['note'], 'Device only');
  });

  for (final statement in [
    "INSERT INTO model_space (id, owner_id, name, kind) VALUES ('x','y','z','group')",
    "UPDATE model_space SET name = 'Hacked'",
    'DELETE FROM model_space',
    'CREATE TABLE sneaky (id TEXT)',
    'DROP TABLE model_space',
  ]) {
    test('refuses to run: ${statement.split(' ').first}', () async {
      await expectLater(
        localSync.readOnlySql.query(statement),
        throwsA(isA<DatabaseException>()),
      );

      // ...and nothing moved.
      expect((await localSync.models.space.get(spaceId))?.name, 'Family');
    });
  }

  test('a concurrent reader sees committed rows only', () async {
    final written = Completer<void>();
    final release = Completer<void>();
    // Held open through the database port itself — the only way left to stand
    // inside an uncommitted write now that `mutate` opens and closes its own
    // transaction with nowhere for a caller to wait in the middle.
    final transaction = driver.database.transaction((transaction) async {
      await transaction.execute(
        DatabaseStatement(
          sql: 'UPDATE model_space SET name = ? WHERE id = ?',
          variables: ['Uncommitted', spaceId.value.uuid],
        ),
      );
      written.complete();
      await release.future;
    });
    await written.future;

    // Read from outside the write, as a screen would: the edit is real in the
    // main table but not yet committed, so it is not visible here.
    final during = await localSync.readOnlySql.query(
      'SELECT name FROM model_space WHERE id = ?',
      [spaceId.value.uuid],
    );
    expect(during.rows.single['name'], 'Family');

    release.complete();
    await transaction;

    final after = await localSync.readOnlySql.query(
      'SELECT name FROM model_space WHERE id = ?',
      [spaceId.value.uuid],
    );
    expect(after.rows.single['name'], 'Uncommitted');
    expect((await localSync.models.space.get(spaceId))?.name, 'Uncommitted');
  });

  test('watch emits initially and again on a named table', () async {
    final seen = <String?>[];
    final subscription = localSync.readOnlySql
        .watch(
          'SELECT name FROM model_space WHERE id = ?',
          variables: [spaceId.value.uuid],
          tables: const {'model_space'},
        )
        .listen((result) => seen.add(result.rows.single['name'] as String?));
    await _settle(seen, 1);

    await localSync.transaction(
      (outerTx) => outerTx.mutate.renameSpace(
        (tx) async => (
          space: tx.space.update(
            (await tx.models.space.get(spaceId))!,
            name: 'Renamed',
          ),
        ),
      ),
    );
    await _settle(seen, 2);

    expect(seen, ['Family', 'Renamed']);
    await subscription.cancel();
  });

  test('an unrelated table does not wake the query', () async {
    final seen = <int>[];
    final subscription = localSync.readOnlySql
        .watch(
          'SELECT COUNT(*) AS count FROM model_space',
          tables: const {'model_space'},
        )
        .listen((result) => seen.add(result.rows.single['count']! as int));
    await _settle(seen, 1);

    await localSync.transaction(
      (tx) => tx.models.localNote.update(id: noteId, text: 'Edited'),
    );
    await _quiet();

    expect(seen, [1]);
    await subscription.cancel();
  });

  test('a watched query names its tables', () {
    expect(
      () => localSync.readOnlySql.watch('SELECT 1', tables: const {}),
      throwsArgumentError,
    );
  });

  test('cancelling a watcher stops it reading', () async {
    final seen = <int>[];
    final subscription = localSync.readOnlySql
        .watch(
          'SELECT COUNT(*) AS count FROM model_space',
          tables: const {'model_space'},
        )
        .listen((result) => seen.add(result.rows.single['count']! as int));
    await _settle(seen, 1);
    await subscription.cancel();

    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: uuid(9),
            ownerId: userId.value,
            name: 'Another',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await _quiet();

    expect(seen, [1]);
  });

  test('closing LocalSync ends the watchers', () async {
    final done = Completer<void>();
    final subscription = localSync.readOnlySql
        .watch('SELECT name FROM model_space', tables: const {'model_space'})
        .listen((_) {}, onDone: done.complete, onError: (_) {});
    await _quiet();

    await localSync.close();
    // A watcher outliving its database would go on querying a closed handle.
    await done.future.timeout(const Duration(seconds: 5));

    await subscription.cancel();
  });
}

Future<void> _settle(List<Object?> values, int count) async {
  // Generous on purpose: the whole suite runs in parallel, and a watcher that
  // is merely slow under load must not read as a watcher that never fired.
  for (var attempt = 0; attempt < 2000 && values.length < count; attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _quiet() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

/// Keeps hold of the [Database] it opened, so a test can stand inside a write
/// transaction of its own. The port is the only writer left with a seam a
/// caller can wait in.
final class CapturingDriver implements DatabaseDriver {
  CapturingDriver(this._driver);

  final DatabaseDriver _driver;
  late final Database database;

  @override
  Future<Database> open() async => database = await _driver.open();
}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
