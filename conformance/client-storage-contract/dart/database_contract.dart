import 'dart:async';
import 'dart:io';

import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

/// Opens a fresh handle on the fixture database kept in [directory].
///
/// The same directory is handed to every call within one case, so a factory
/// must address the same database file each time: the contract reopens it to
/// prove migration durability, and opens a second handle to prove snapshot
/// stability.
typedef OpenContractDatabase = Future<Database> Function(Directory directory);

/// The database port, proven against one adapter.
///
/// The adapter supplies only a name and an [open] factory. That factory must
/// apply, at version 1, a fixture schema equivalent to:
///
/// ```sql
/// CREATE TABLE fixture_items (
///   id INTEGER PRIMARY KEY AUTOINCREMENT,
///   name TEXT NOT NULL UNIQUE
/// );
/// CREATE TABLE fixture_others (id INTEGER PRIMARY KEY AUTOINCREMENT);
/// CREATE TABLE fixture_parents (id INTEGER PRIMARY KEY);
/// CREATE TABLE fixture_children (
///   id INTEGER PRIMARY KEY,
///   parent_id INTEGER NOT NULL REFERENCES fixture_parents(id) ON DELETE CASCADE
/// );
/// ```
///
/// Every assertion lives here. An adapter that needs one of its own has found
/// an implementation detail, and that belongs in its own package's tests.
void databaseContract({
  required String adapterName,
  required OpenContractDatabase open,
}) {
  group('$adapterName database contract', () {
    late Directory directory;
    late Database database;
    late List<Database> handles;

    Future<Database> openHandle() async {
      final handle = await open(directory);
      handles.add(handle);
      return handle;
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'local_sync_database_contract_',
      );
      handles = <Database>[];
      database = await openHandle();
    });

    tearDown(() async {
      // Close is idempotent, so a case that closed a handle itself — or failed
      // halfway through one — still leaves nothing open.
      for (final handle in handles) {
        await handle.close();
      }
      await directory.delete(recursive: true);
    });

    test('query and execute return materialized results', () async {
      final first = await database.execute(_insertItem('one'));
      await database.execute(_insertItem('two'));

      expect(first.affectedRows, 1);
      expect(first.lastInsertRowId, 1);

      final result = await database.query(_itemsQuery());
      expect(result.columns, ['id', 'name']);
      expect(result.length, 2);
      expect(result[0]['id'], 1);
      expect(result[1]['name'], 'two');
    });

    test('migrations are not reapplied when the database reopens', () async {
      await database.execute(_insertItem('persisted'));
      await database.close();

      database = await openHandle();

      final result = await database.query(_itemsQuery());
      expect(result.singleOrNull?['name'], 'persisted');
    });

    test('reopens repeatedly after reactive readers are closed', () async {
      for (var attempt = 0; attempt < 3; attempt += 1) {
        final iterator = StreamIterator(database.watch(_itemsQuery()));
        expect(await iterator.moveNext(), isTrue);
        await iterator.cancel();
        await database.close();
        database = await openHandle();
      }
    });

    test(
      'transaction commits, returns a value, and rolls back failures',
      () async {
        final value = await database.transaction((tx) async {
          await tx.execute(_insertItem('committed'));
          return 42;
        });
        expect(value, 42);

        await expectLater(
          database.transaction((tx) async {
            await tx.execute(_insertItem('rolled-back'));
            throw StateError('stop');
          }),
          throwsStateError,
        );

        final result = await database.query(_itemsQuery());
        expect(result.rows.map((row) => row['name']), ['committed']);
      },
    );

    test(
      'savepoint can roll back without aborting its outer transaction',
      () async {
        await database.transaction((tx) async {
          await tx.execute(_insertItem('outer-before'));
          try {
            await tx.savepoint((savepoint) async {
              await savepoint.execute(_insertItem('inner'));
              throw StateError('rollback savepoint');
            });
          } on StateError {
            // The outer transaction deliberately continues.
          }
          await tx.execute(_insertItem('outer-after'));
        });

        final result = await database.query(_itemsQuery());
        expect(result.rows.map((row) => row['name']), [
          'outer-before',
          'outer-after',
        ]);
      },
    );

    test(
      'transaction view is stable until a competing write can commit',
      () async {
        await database.execute(_insertItem('before'));
        final competitor = await openHandle();

        late Future<DatabaseExecutionResult> competingWrite;
        var competingWriteSettled = false;

        await database.transaction((tx) async {
          final beforeCompetition = await tx.query(_itemsQuery());
          expect(beforeCompetition.rows.map((row) => row['name']), ['before']);

          competingWrite = competitor.execute(_insertItem('competing'));
          // Observed, so a failure surfaces at the await below rather than as
          // an unhandled error, and never swallowed.
          unawaited(
            competingWrite.then(
              (_) => competingWriteSettled = true,
              onError: (_) => competingWriteSettled = true,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
          expect(
            competingWriteSettled,
            isFalse,
            reason:
                'a competing write must not land inside an open '
                'transaction',
          );

          final duringCompetition = await tx.query(_itemsQuery());
          expect(duringCompetition.rows.map((row) => row['name']), ['before']);
        });

        await competingWrite;

        final afterCompetition = await database.query(_itemsQuery());
        expect(afterCompetition.rows.map((row) => row['name']), [
          'before',
          'competing',
        ]);
      },
    );

    test('transaction handle expires with its callback', () async {
      late DatabaseTransaction escaped;
      await database.transaction((tx) async {
        escaped = tx;
      });

      await expectLater(
        escaped.query(_itemsQuery()),
        throwsA(_databaseError(DatabaseErrorKind.closed)),
      );
    });

    test(
      'watch emits initially and after a relevant committed write',
      () async {
        final iterator = StreamIterator(database.watch(_itemsQuery()));
        addTearDown(iterator.cancel);

        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current.isEmpty, isTrue);

        await database.execute(_insertItem('one'));

        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current.singleOrNull?['name'], 'one');
      },
    );

    test('watch ignores writes to unrelated tables', () async {
      var emissions = 0;
      final subscription = database.watch(_itemsQuery()).listen((_) {
        emissions++;
      });
      await _eventually(() => emissions == 1);

      await database.execute(_insertOther());
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(emissions, 1);
      await subscription.cancel();
    });

    test('watchTables emits for named tables without a signal query', () async {
      var emissions = 0;
      final subscription = database.watchTables({'fixture_items'}).listen((_) {
        emissions++;
      });
      addTearDown(subscription.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(emissions, 0);

      await database.execute(_insertOther());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(emissions, 0);

      await database.execute(_insertItem('watched'));
      await _eventually(() => emissions == 1);
    });

    test('watch reflects commit state and ignores rollback state', () async {
      var emissions = 0;
      var visibleRows = 0;
      final subscription = database.watch(_itemsQuery()).listen((result) {
        emissions++;
        visibleRows = result.length;
      });
      addTearDown(subscription.cancel);
      await _eventually(() => emissions == 1);

      await database.transaction((tx) async {
        await tx.execute(_insertItem('one'));
        await tx.execute(_insertItem('two'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emissions, 1);
      });
      await _eventually(() => visibleRows == 2);

      await expectLater(
        database.transaction((tx) async {
          await tx.execute(_insertItem('three'));
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(visibleRows, 2);
    });

    test('constraint failures use the common error model', () async {
      await database.execute(_insertItem('same'));

      await expectLater(
        database.execute(_insertItem('same')),
        throwsA(_databaseError(DatabaseErrorKind.constraint)),
      );
    });

    test('enables foreign keys on pooled connections', () async {
      await database.execute(
        DatabaseStatement(sql: 'INSERT INTO fixture_parents (id) VALUES (1)'),
      );
      await database.execute(
        DatabaseStatement(
          sql: 'INSERT INTO fixture_children (id, parent_id) VALUES (1, 1)',
        ),
      );
      await database.execute(
        DatabaseStatement(sql: 'DELETE FROM fixture_parents WHERE id = 1'),
      );

      final children = await database.query(
        DatabaseQuery(sql: 'SELECT id FROM fixture_children'),
      );
      expect(children, isEmpty);
    });

    test('close is idempotent and rejects later calls', () async {
      final iterator = StreamIterator(database.watch(_itemsQuery()));
      expect(await iterator.moveNext(), isTrue);
      await iterator.cancel();

      await database.close();
      await database.close();

      await expectLater(
        database.query(_itemsQuery()),
        throwsA(_databaseError(DatabaseErrorKind.closed)),
      );
    });
  });
}

DatabaseQuery _itemsQuery() =>
    DatabaseQuery(sql: 'SELECT id, name FROM fixture_items ORDER BY id');

DatabaseStatement _insertItem(String name) => DatabaseStatement(
  sql: 'INSERT INTO fixture_items (name) VALUES (?)',
  variables: [name],
);

DatabaseStatement _insertOther() =>
    DatabaseStatement(sql: 'INSERT INTO fixture_others DEFAULT VALUES');

Matcher _databaseError(DatabaseErrorKind kind) =>
    isA<DatabaseException>().having((error) => error.kind, 'kind', kind);

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not satisfied');
}
