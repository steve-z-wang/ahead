import 'dart:io';

import 'package:local_sync_database/local_sync_database.dart';
import 'package:local_sync_database_sqlite/local_sync_database_sqlite.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('local_sync_sqlite');
    path = '${directory.path}/test.db';
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  SqliteDatabaseMigration seedMigration() => SqliteDatabaseMigration(
    version: 1,
    statements: [
      DatabaseStatement(
        sql:
            'CREATE TABLE downlink_state ('
            '  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),'
            '  last_applied_sync_id INTEGER NOT NULL'
            ')',
      ),
      DatabaseStatement(
        sql: 'CREATE TABLE kept (id INTEGER PRIMARY KEY, value TEXT NOT NULL)',
      ),
      DatabaseStatement(sql: 'INSERT INTO downlink_state VALUES (1, 42)'),
      DatabaseStatement(sql: "INSERT INTO kept VALUES (1, 'offline')"),
    ],
  );

  SqliteDatabaseMigration replayMigration() => SqliteDatabaseMigration(
    version: 2,
    statements: const [],
    replayDownlink: true,
  );

  Future<Database> openWith(List<SqliteDatabaseMigration> migrations) =>
      SqliteDatabaseDriver.file(path: path, migrations: migrations).open();

  Future<int> readCursor(Database database) async {
    final result = await database.query(
      DatabaseQuery(
        sql:
            'SELECT last_applied_sync_id FROM downlink_state WHERE singleton = 1',
      ),
    );
    return result.rows.single['last_applied_sync_id']! as int;
  }

  test(
    'an applied replay migration rewinds the cursor and keeps rows',
    () async {
      final seeded = await openWith([seedMigration()]);
      expect(await readCursor(seeded), 42);
      await seeded.close();

      final replayed = await openWith([seedMigration(), replayMigration()]);
      expect(await readCursor(replayed), 0);
      final kept = await replayed.query(
        DatabaseQuery(sql: 'SELECT value FROM kept WHERE id = 1'),
      );
      expect(kept.rows.single['value'], 'offline');
      await replayed.close();
    },
  );

  test('an already-applied replay migration does not rewind again', () async {
    final replayed = await openWith([seedMigration(), replayMigration()]);
    await replayed.execute(
      DatabaseStatement(
        sql:
            'UPDATE downlink_state SET last_applied_sync_id = 17 '
            'WHERE singleton = 1',
      ),
    );
    await replayed.close();

    final reopened = await openWith([seedMigration(), replayMigration()]);
    expect(await readCursor(reopened), 17);
    await reopened.close();
  });

  test('a replay migration rewinds every scoped cursor', () async {
    final scopedSeed = SqliteDatabaseMigration(
      version: 1,
      statements: [
        DatabaseStatement(
          sql:
              'CREATE TABLE downlink_scope_state ('
              'scope TEXT NOT NULL, '
              'last_applied_sync_id INTEGER NOT NULL, '
              'PRIMARY KEY (scope))',
        ),
        DatabaseStatement(
          sql:
              "INSERT INTO downlink_scope_state VALUES "
              "('User:11111111-1111-4111-8111-111111111111', 42), "
              "('Book:22222222-2222-4222-8222-222222222222', 7)",
        ),
      ],
    );

    final replayed = await openWith([scopedSeed, replayMigration()]);
    final cursors = await replayed.query(
      DatabaseQuery(
        sql:
            'SELECT last_applied_sync_id FROM downlink_scope_state '
            'ORDER BY scope',
      ),
    );
    expect(
      [for (final row in cursors.rows) row['last_applied_sync_id']],
      [0, 0],
    );
    await replayed.close();
  });

  test(
    'a failing replay migration rolls back its writes and the rewind',
    () async {
      final replayed = await openWith([seedMigration(), replayMigration()]);
      await replayed.execute(
        DatabaseStatement(
          sql:
              'UPDATE downlink_state SET last_applied_sync_id = 17 '
              'WHERE singleton = 1',
        ),
      );
      await replayed.close();

      final broken = SqliteDatabaseMigration(
        version: 3,
        statements: [
          DatabaseStatement(sql: "INSERT INTO kept VALUES (2, 'doomed')"),
          DatabaseStatement(sql: 'THIS IS NOT SQL'),
        ],
        replayDownlink: true,
      );

      await expectLater(
        openWith([seedMigration(), replayMigration(), broken]),
        throwsA(isA<Object>()),
      );

      final reopened = await openWith([seedMigration(), replayMigration()]);
      expect(await readCursor(reopened), 17);
      final doomed = await reopened.query(
        DatabaseQuery(sql: 'SELECT COUNT(*) AS n FROM kept WHERE id = 2'),
      );
      expect(doomed.rows.single['n'], 0);
      await reopened.close();
    },
  );
}
