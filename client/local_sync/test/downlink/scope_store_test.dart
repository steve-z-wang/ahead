import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late ScopeStore store;

  setUp(() async {
    database = await TestLocalDatabase.open();
    store = ScopeStore(database.scope);
  });

  tearDown(() => database.close());

  test('direct set inserts cursor zero and is idempotent', () async {
    await database.scope.transaction((_) => store.assignDirect(bookA, true));
    await database.scope.transaction((_) => store.assignDirect(bookA, true));

    expect(await scopeState(database, bookA), (cursor: 0, desired: true));
    expect(await store.effectiveDesiredScopes(), [bookA]);
  });

  test(
    'direct remove preserves the cursor and absent remove is empty',
    () async {
      await database.scope.transaction((_) => store.assignDirect(bookA, false));
      expect(await scopeState(database, bookA), isNull);

      await database.scope.transaction((_) async {
        await store.assignDirect(bookA, true);
        await database.scope.current.execute(
          DatabaseStatement(
            sql:
                'UPDATE downlink_scope_state '
                'SET last_applied_sync_id = 17 WHERE scope = ?',
            variables: [bookA],
          ),
        );
        await store.assignDirect(bookA, false);
      });

      expect(await scopeState(database, bookA), (cursor: 17, desired: false));
      expect(await store.effectiveDesiredScopes(), isEmpty);
    },
  );

  test('pending set overlays a false base row', () async {
    final ordinal = await database.queueRecord();
    await database.scope.transaction(
      (_) => store.assignPending(bookA, true, mutationOrdinal: ordinal),
    );

    expect(await scopeState(database, bookA), (cursor: 0, desired: false));
    expect(await pendingScopes(database), [(ordinal, 0, bookA, true)]);
    expect(await store.effectiveDesiredScopes(), [bookA]);
  });

  test('pending remove on an absent scope stores nothing', () async {
    final ordinal = await database.queueRecord();
    await database.scope.transaction(
      (_) => store.assignPending(bookA, false, mutationOrdinal: ordinal),
    );

    expect(await scopeState(database, bookA), isNull);
    expect(await pendingScopes(database), isEmpty);
  });

  test('latest pending assignment wins by ordinal then position', () async {
    await database.scope.transaction((_) => store.assignDirect(bookA, true));
    final first = await database.queueRecord(name: 'First');
    final second = await database.queueRecord(name: 'Second');

    await database.scope.transaction((_) async {
      await store.assignPending(bookA, false, mutationOrdinal: first);
      await store.assignPending(bookA, true, mutationOrdinal: first);
      await store.assignPending(bookA, false, mutationOrdinal: second);
    });

    expect(await store.effectiveDesiredScopes(), isEmpty);
  });

  test('a later direct assignment updates base beneath pending work', () async {
    final ordinal = await database.queueRecord();
    await database.scope.transaction((_) async {
      await store.assignPending(bookA, true, mutationOrdinal: ordinal);
      await store.assignDirect(bookA, false);
    });

    expect(await scopeState(database, bookA), (cursor: 0, desired: false));
    expect(await store.effectiveDesiredScopes(), [bookA]);
  });

  test('rejection exposes base and leaves later overlay standing', () async {
    await database.scope.transaction((_) => store.assignDirect(bookA, true));
    final rejected = await database.queueRecord(name: 'Rejected');
    final survivor = await database.queueRecord(name: 'Survivor');
    await database.scope.transaction((_) async {
      await store.assignPending(bookA, false, mutationOrdinal: rejected);
      await store.assignPending(bookA, true, mutationOrdinal: survivor);
      await database.scope.current.execute(
        DatabaseStatement(
          sql: 'DELETE FROM pending_mutations WHERE ordinal = ?',
          variables: [rejected],
        ),
      );
    });

    expect(await pendingScopes(database), [(survivor, 0, bookA, true)]);
    expect(await store.effectiveDesiredScopes(), [bookA]);
  });

  test('acceptance advances base before deleting accepted overlay', () async {
    final accepted = await database.queueRecord(name: 'Accepted');
    await database.scope.transaction((_) async {
      await store.assignPending(bookA, true, mutationOrdinal: accepted);
      await store.settleAccepted([accepted]);
      await database.scope.current.execute(
        DatabaseStatement(
          sql: 'DELETE FROM pending_mutations WHERE ordinal = ?',
          variables: [accepted],
        ),
      );
    });

    expect(await scopeState(database, bookA), (cursor: 0, desired: true));
    expect(await pendingScopes(database), isEmpty);
    expect(await store.effectiveDesiredScopes(), [bookA]);
  });

  test('accepting earlier work does not settle a later overlay', () async {
    final earlier = await database.queueRecord(name: 'Earlier');
    final later = await database.queueRecord(name: 'Later');
    await database.scope.transaction((_) async {
      await store.assignPending(bookA, true, mutationOrdinal: earlier);
      await store.assignPending(bookA, false, mutationOrdinal: later);
      await store.settleAccepted([earlier]);
      await database.scope.current.execute(
        DatabaseStatement(
          sql: 'DELETE FROM pending_mutations WHERE ordinal = ?',
          variables: [earlier],
        ),
      );
    });

    expect(await scopeState(database, bookA), (cursor: 0, desired: true));
    expect(await pendingScopes(database), [(later, 0, bookA, false)]);
    expect(await store.effectiveDesiredScopes(), isEmpty);
  });

  test('same-scope pending work records an ordering edge', () async {
    final earlier = await database.queueRecord(name: 'Earlier');
    final later = await database.queueRecord(name: 'Later');
    await database.scope.transaction((_) async {
      await store.assignPending(bookA, true, mutationOrdinal: earlier);
      await store.assignPending(bookA, false, mutationOrdinal: later);
    });

    final edges = await database.scope.current.query(
      DatabaseQuery(
        sql:
            'SELECT mutation_ordinal, predecessor_ordinal '
            'FROM pending_mutation_sequences',
      ),
    );
    expect(
      edges.rows.map(
        (row) => (
          row['mutation_ordinal']! as int,
          row['predecessor_ordinal']! as int,
        ),
      ),
      [(later, earlier)],
    );
  });
}

const bookA = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

Future<({int cursor, bool desired})?> scopeState(
  TestLocalDatabase database,
  String scope,
) async {
  final row = (await database.scope.current.query(
    DatabaseQuery(
      sql:
          'SELECT last_applied_sync_id, desired '
          'FROM downlink_scope_state WHERE scope = ?',
      variables: [scope],
    ),
  )).singleOrNull;
  return row == null
      ? null
      : (
          cursor: row['last_applied_sync_id']! as int,
          desired: row['desired'] == 1,
        );
}

Future<List<(int, int, String, bool)>> pendingScopes(
  TestLocalDatabase database,
) async {
  final rows = await database.scope.current.query(
    DatabaseQuery(
      sql:
          'SELECT mutation_ordinal, position, scope, desired '
          'FROM pending_mutation_scopes '
          'ORDER BY mutation_ordinal, position',
    ),
  );
  return [
    for (final row in rows.rows)
      (
        row['mutation_ordinal']! as int,
        row['position']! as int,
        row['scope']! as String,
        row['desired'] == 1,
      ),
  ];
}
