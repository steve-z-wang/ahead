import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';

void main() {
  test(
    'late receipt settles against existing cursors without applying another page',
    () async {
      final harness = await Harness.open(cursor: 102);
      addTearDown(harness.close);
      await harness.seedBatch(12, requiredSyncId: 102, mutations: [41, 42]);
      await harness.seedBatch(13, requiredSyncId: 103, mutations: [43]);
      await harness.store.settleAccepted();
      expect(await harness.batches(), {13: 103});
      expect(await harness.mutations(), {
        13: [43],
      });
      expect(await harness.cursor(), 102);
      await harness.store.settleAccepted();
      expect(await harness.batches(), {13: 103});
    },
  );

  test(
    'initializes a scope at zero once and retains an advanced cursor',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      const scope = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

      await setTestScopes(harness.fixture.scope, [scope]);
      expect(await harness.store.readLastAppliedSyncId(scope), 0);
      await harness.database.execute(
        DatabaseStatement(
          sql:
              'UPDATE downlink_scope_state SET last_applied_sync_id = 17 '
              'WHERE scope = ?',
          variables: [scope],
        ),
      );

      await setTestScopes(harness.fixture.scope, [scope]);

      expect(await harness.store.readLastAppliedSyncId(scope), 17);
    },
  );

  test(
    'commits each change and durably skips one failed canonical upsert',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      await harness.seedBatch(12, requiredSyncId: 102, mutations: [41, 42]);

      final result = await harness.store.apply(
        page(103, [
          change(101, 'upsert', id: testId(1), name: 'First'),
          change(102, 'upsert', id: testId(2), name: 'Broken'),
          change(103, 'upsert', id: testId(3), name: 'Last'),
        ]),
        afterSyncId: 100,
      );

      expect(result.failures, hasLength(1));
      expect(result.failures.single.syncId, 102);
      expect(result.failures.single.model, 'Test');
      expect(result.failures.single.operation, 'upsert');
      expect(await harness.records(), {
        testId(1): {'name': 'First'},
        testId(3): {'name': 'Last'},
      });
      expect(await harness.cursor(), 103);
      expect(await harness.batches(), isEmpty);
      expect(await harness.mutations(), isEmpty);
    },
  );

  test('full-state upsert replaces an existing row', () async {
    final harness = await Harness.open(cursor: 100);
    addTearDown(harness.close);
    await harness.canonical.upsert(testId(1), {'name': 'Old'});

    final result = await harness.store.apply(
      page(102, [
        change(101, 'upsert', id: testId(1), name: 'Replacement'),
        change(102, 'upsert', id: testId(1), name: 'New'),
      ]),
      afterSyncId: 100,
    );

    expect(result.failures, isEmpty);
    expect((await harness.canonical.get(testId(1)))?.fields, {'name': 'New'});
    expect(await harness.cursor(), 102);
  });

  test(
    'hook sees canonical pre-images and equal replay applications',
    () async {
      final seen = <CanonicalDownlinkChange>[];
      final harness = await Harness.open(
        cursor: 100,
        onApplied: (changes) async => seen.addAll(changes),
      );
      addTearDown(harness.close);
      await harness.canonical.upsert(testId(1), {'name': 'Old'});

      await harness.store.apply(
        page(102, [
          change(101, 'upsert', id: testId(1), name: 'New'),
          change(102, 'upsert', id: testId(1), name: 'New'),
        ]),
        afterSyncId: 100,
      );

      expect(seen, hasLength(2));
      final first = seen.first as CanonicalDownlinkUpsert;
      final replay = seen.last as CanonicalDownlinkUpsert;
      expect(first.previous?.fields, {'name': 'Old'});
      expect(first.row.fields, {'name': 'New'});
      expect(replay.previous?.fields, {'name': 'New'});
      expect(replay.row.fields, {'name': 'New'});
      expect(first.scope, userScope);
      expect(first.syncId, 101);
    },
  );

  test(
    'a delete releases only its scope until the last claim leaves',
    () async {
      final seen = <CanonicalDownlinkChange>[];
      final harness = await Harness.open(
        cursor: 100,
        onApplied: (changes) async => seen.addAll(changes),
      );
      addTearDown(harness.close);
      const bookA = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const bookB = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      await setTestScopes(harness.fixture.scope, [bookA, bookB]);

      await harness.store.apply(
        scopedPage(bookA, 0, 1, [
          change(1, 'upsert', id: testId(1), name: 'In A'),
        ]),
        afterSyncId: 0,
      );
      await harness.store.apply(
        scopedPage(bookB, 0, 1, [
          change(1, 'upsert', id: testId(1), name: 'Moved to B'),
        ]),
        afterSyncId: 0,
      );
      await harness.store.apply(
        scopedPage(bookA, 1, 2, [change(2, 'delete', id: testId(1), name: '')]),
        afterSyncId: 1,
      );

      expect((await harness.canonical.get(testId(1)))?.fields, {
        'name': 'Moved to B',
      });
      expect(seen.whereType<CanonicalDownlinkDelete>(), isEmpty);

      await harness.store.apply(
        scopedPage(bookB, 1, 2, [change(2, 'delete', id: testId(1), name: '')]),
        afterSyncId: 1,
      );
      expect(await harness.canonical.get(testId(1)), isNull);
      final removed = seen.whereType<CanonicalDownlinkDelete>().single;
      expect(removed.row.fields, {'name': 'Moved to B'});
      expect(removed.scope, bookB);
      expect(removed.syncId, 2);
    },
  );

  test(
    'hook failure rolls back its effects and retries the same cursor',
    () async {
      var fail = true;
      late TestLocalDatabase fixture;
      final harness = await Harness.open(
        cursor: 100,
        onApplied: (changes) async {
          await ScopeStore(
            fixture.scope,
          ).assignDirect('Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
          if (fail) throw StateError('hook failed');
        },
        captureFixture: (value) => fixture = value,
      );
      addTearDown(harness.close);
      final applied = page(101, [
        change(101, 'upsert', id: testId(1), name: 'Family'),
      ]);

      await expectLater(
        harness.store.apply(applied, afterSyncId: 100),
        throwsStateError,
      );
      expect(await harness.records(), isEmpty);
      expect(await harness.cursor(), 100);
      expect(await ScopeStore(fixture.scope).effectiveDesiredScopes(), [
        userScope,
      ]);

      fail = false;
      final retried = await harness.store.apply(applied, afterSyncId: 100);
      expect(retried.failures, isEmpty);
      expect(await harness.records(), hasLength(1));
      expect(await harness.cursor(), 101);
      expect(await ScopeStore(fixture.scope).effectiveDesiredScopes(), [
        'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userScope,
      ]);
    },
  );

  test(
    'a later scope upsert restores a row after the prior claim leaves',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      const bookA = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const bookB = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      await setTestScopes(harness.fixture.scope, [bookA, bookB]);

      await harness.store.apply(
        scopedPage(bookA, 0, 1, [
          change(1, 'upsert', id: testId(1), name: 'In A'),
        ]),
        afterSyncId: 0,
      );
      await harness.store.apply(
        scopedPage(bookA, 1, 2, [change(2, 'delete', id: testId(1), name: '')]),
        afterSyncId: 1,
      );
      expect(await harness.canonical.get(testId(1)), isNull);

      await harness.store.apply(
        scopedPage(bookB, 0, 1, [
          change(1, 'upsert', id: testId(1), name: 'Moved to B'),
        ]),
        afterSyncId: 0,
      );

      expect((await harness.canonical.get(testId(1)))?.fields, {
        'name': 'Moved to B',
      });
      expect(await harness.store.readLastAppliedSyncId(bookA), 2);
      expect(await harness.store.readLastAppliedSyncId(bookB), 1);
    },
  );

  test('an empty advancing page settles every reached batch', () async {
    final harness = await Harness.open(cursor: 100);
    addTearDown(harness.close);
    await harness.seedBatch(11, requiredSyncId: 100);
    await harness.seedBatch(12, requiredSyncId: 105, mutations: [42]);
    await harness.seedBatch(13, requiredSyncId: 106, mutations: [43]);

    final result = await harness.store.apply(
      page(105, const []),
      afterSyncId: 100,
    );

    expect(result.failures, isEmpty);
    expect(await harness.cursor(), 105);
    expect(await harness.batches(), {13: 106});
    expect(await harness.mutations(), {
      13: [43],
    });
  });

  test(
    'outer failure rolls canonical, settlement, and cursor back together',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      await harness.seedBatch(12, requiredSyncId: 101, mutations: [41]);
      await harness.database.execute(
        DatabaseStatement(
          sql: '''
            CREATE TRIGGER fail_downlink_cursor
            BEFORE UPDATE ON downlink_scope_state
            BEGIN
              SELECT RAISE(ABORT, 'cursor write failed');
            END
          ''',
        ),
      );

      await expectLater(
        harness.store.apply(
          page(101, [change(101, 'upsert', id: testId(1), name: 'Family')]),
          afterSyncId: 100,
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await harness.records(), isEmpty);
      expect(
        await harness.database.query(
          DatabaseQuery(sql: 'SELECT * FROM downlink_scope_rows'),
        ),
        isEmpty,
      );
      expect(await harness.cursor(), 100);
      expect(await harness.batches(), {12: 101});
      expect(await harness.mutations(), {
        12: [41],
      });
    },
  );

  test('rejects a stale expected cursor before applying anything', () async {
    final harness = await Harness.open(cursor: 99);
    addTearDown(harness.close);

    await expectLater(
      harness.store.apply(
        page(101, [change(101, 'upsert', id: testId(1), name: 'Family')]),
        afterSyncId: 100,
      ),
      throwsA(isA<DownlinkPageException>()),
    );

    expect(await harness.records(), isEmpty);
    expect(await harness.cursor(), 99);
  });

  test(
    'keeps cursors independent and rejects an inactive page scope',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      const bookScope = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      await setTestScopes(harness.fixture.scope, [
        userScope,
        bookScope,
        bookScope,
      ]);

      await harness.store.apply(page(101, const []), afterSyncId: 100);

      expect(await harness.store.readLastAppliedSyncId(userScope), 101);
      expect(await harness.store.readLastAppliedSyncId(bookScope), 0);
      const inactive = 'Book:cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      await expectLater(
        harness.store.apply(
          DownlinkPage(
            scope: inactive,
            fromSyncId: 0,
            throughSyncId: 1,
            changes: const [],
          ),
          afterSyncId: 0,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'settles only a batch whose required Scope and cursor both match',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      const bookScope = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      await setTestScopes(harness.fixture.scope, [bookScope]);
      await harness.seedBatch(11, requiredSyncId: 105);
      await harness.seedBatch(
        12,
        requiredScope: bookScope,
        requiredSyncId: 105,
      );

      await harness.store.apply(page(105, const []), afterSyncId: 100);

      expect(await harness.batches(), {12: 105});
    },
  );

  test(
    'settles a batch only after every scoped checkpoint is reached',
    () async {
      final harness = await Harness.open(cursor: 100);
      addTearDown(harness.close);
      const bookA = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const bookB = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      await setTestScopes(harness.fixture.scope, [bookA, bookB]);
      await harness.seedBatch(
        11,
        requiredSyncId: 101,
        checkpoints: [
          UplinkCheckpoint(scope: userScope, syncId: 101),
          UplinkCheckpoint(scope: bookA, syncId: 4),
          UplinkCheckpoint(scope: bookB, syncId: 7),
        ],
        mutations: [41],
      );
      await harness.seedBatch(
        12,
        requiredSyncId: 101,
        checkpoints: [UplinkCheckpoint(scope: bookA, syncId: 4)],
        mutations: [42],
      );

      await harness.store.apply(page(101, const []), afterSyncId: 100);
      expect(await harness.batches(), {11: 101, 12: 101});

      // Batch 12 is now ready, but cannot overtake batch 11, which still
      // waits on Book B.
      await harness.store.apply(
        emptyPage(bookA, from: 0, through: 4),
        afterSyncId: 0,
      );
      expect(await harness.batches(), {11: 101, 12: 101});

      await harness.store.apply(
        emptyPage(bookB, from: 0, through: 7),
        afterSyncId: 0,
      );
      expect(await harness.batches(), isEmpty);
      expect(await harness.mutations(), isEmpty);
    },
  );
}

const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
const userScope = 'User:$clientId';

String testUuid(int value) =>
    '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}';
TestId testId(int value) => TestId(UUID.withValidation(testUuid(value)));

DownlinkPage page(int throughSyncId, List<AddressedModelChange> changes) =>
    DownlinkPage(
      scope: userScope,
      fromSyncId: 100,
      throughSyncId: throughSyncId,
      changes: changes,
    );

DownlinkPage emptyPage(
  String scope, {
  required int from,
  required int through,
}) => DownlinkPage(
  scope: scope,
  fromSyncId: from,
  throughSyncId: through,
  changes: const [],
);

DownlinkPage scopedPage(
  String scope,
  int fromSyncId,
  int throughSyncId,
  List<AddressedModelChange> changes,
) => DownlinkPage(
  scope: scope,
  fromSyncId: fromSyncId,
  throughSyncId: throughSyncId,
  changes: changes,
);

AddressedModelChange change(
  int syncId,
  String operation, {
  required TestId id,
  required String name,
}) => AddressedModelChange(
  syncId: syncId,
  raw: {
    'syncId': syncId,
    'model': 'Test',
    'operation': operation,
    'id': {'id': id.id.uuid},
    if (operation != 'delete') 'data': {'name': name},
  },
);

final testSchema = ModelSchema<TestId>(
  name: 'Test',
  identity: const ['id'],
  fields: const [
    ModelFieldSchema(name: 'id', type: LocalScalarType.uuid, nullable: false),
    ModelFieldSchema(
      name: 'name',
      type: LocalScalarType.string,
      nullable: false,
    ),
  ],
  uniqueConstraints: const [],
  relations: const [],
  createId: (parts) => TestId(parts['id']! as UUID),
);

final testDescriptor = ModelDatabaseDescriptor<TestId>(
  schema: testSchema,
  tableName: 'model_test',
  columns: const {'id': 'id', 'name': 'name'},
);

final testBeforeDescriptor = ModelDatabaseDescriptor<TestId>(
  schema: testSchema,
  tableName: 'model_test_before',
  columns: const {'id': 'id', 'name': 'name'},
);

final class Harness {
  Harness._(this.fixture, this.canonical, this.store);

  final TestLocalDatabase fixture;
  final SqlCanonicalStore<TestId> canonical;
  final DownlinkPageProcessor store;

  Database get database => fixture.database;

  static Future<Harness> open({
    required int cursor,
    CanonicalDownlinkHook? onApplied,
    void Function(TestLocalDatabase fixture)? captureFixture,
  }) async {
    final fixture = await TestLocalDatabase.open(
      modelStatements: [
        DatabaseStatement(
          sql: '''
            CREATE TABLE model_test (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL
            )
          ''',
        ),
        DatabaseStatement(
          sql: '''
            CREATE TABLE model_test_before (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL
            )
          ''',
        ),
      ],
    );
    final canonical = SqlCanonicalStore<TestId>(
      database: fixture.scope,
      descriptor: testDescriptor,
    );
    captureFixture?.call(fixture);
    final failingCanonical = _FailingCanonicalStore(canonical);
    final registry = ModelRegistry([
      TypedModelRegistryEntry(
        schema: testSchema,
        canonical: failingCanonical,
        before: BeforeImageStore(
          database: fixture.scope,
          main: testDescriptor,
          before: testBeforeDescriptor,
        ),
        mutations: SqlMutationStore(
          database: fixture.scope,
          schema: testSchema,
        ),
      ),
    ]);
    await MutationQueue(fixture.scope, registry: registry).initialize(clientId);
    final store = DownlinkPageProcessor(
      database: fixture.scope,
      registry: registry,
      decoder: ModelChangeDecoder(registry),
      onApplied: onApplied,
    );
    await setTestScopes(fixture.scope, [userScope]);
    if (cursor != 0) {
      await fixture.database.execute(
        DatabaseStatement(
          sql:
              'UPDATE downlink_scope_state SET last_applied_sync_id = ? '
              'WHERE scope = ?',
          variables: [cursor, userScope],
        ),
      );
    }
    return Harness._(fixture, canonical, store);
  }

  Future<void> seedBatch(
    int sequence, {
    String? requiredScope,
    required int requiredSyncId,
    List<UplinkCheckpoint>? checkpoints,
    List<int> mutations = const [],
  }) async {
    final legacyScope = requiredScope ?? userScope;
    await database.execute(
      DatabaseStatement(
        sql:
            'INSERT INTO uplink_batches '
            '(sequence, required_scope, required_sync_id) VALUES (?, ?, ?)',
        variables: [sequence, legacyScope, requiredSyncId],
      ),
    );
    for (final checkpoint
        in checkpoints ??
            [UplinkCheckpoint(scope: legacyScope, syncId: requiredSyncId)]) {
      await database.execute(
        DatabaseStatement(
          sql:
              'INSERT INTO uplink_batch_checkpoints '
              '(batch_sequence, scope, '
              'required_sync_id) VALUES (?, ?, ?)',
          variables: [sequence, checkpoint.scope, checkpoint.syncId],
        ),
      );
    }
    for (final ordinal in mutations) {
      // Every operation names the act it spells (CAP-444); these are
      // one-operation acts.
      await database.execute(
        DatabaseStatement(
          sql: '''
            INSERT INTO pending_mutations
              (ordinal, name, batch_sequence, legacy_fifo)
            VALUES (?, 'TestMutation', ?, 0)
          ''',
          variables: [ordinal, sequence],
        ),
      );
      await database.execute(
        DatabaseStatement(
          sql: '''
            INSERT INTO pending_mutation_operations
              (mutation_ordinal, position, model, identity_json,
               operation, values_json, is_uplink)
            VALUES (?, 0, 'Test', ?, 'update', ?, 1)
          ''',
          variables: [ordinal, '{"id":"${testUuid(1)}"}', '{"name":"pending"}'],
        ),
      );
    }
  }

  Future<int> cursor() async =>
      (await database.query(
            DatabaseQuery(
              sql:
                  'SELECT last_applied_sync_id FROM downlink_scope_state '
                  'WHERE scope = ?',
              variables: [userScope],
            ),
          )).rows.single['last_applied_sync_id']!
          as int;

  Future<Map<TestId, Map<String, Object?>>> records() async => {
    for (final record in await canonical.readAll()) record.id: record.fields,
  };

  Future<Map<int, int?>> batches() async => {
    for (final row in (await database.query(
      DatabaseQuery(
        sql:
            'SELECT sequence, required_sync_id FROM uplink_batches '
            'ORDER BY sequence',
      ),
    )).rows)
      row['sequence']! as int: row['required_sync_id'] as int?,
  };

  Future<Map<int, List<int>>> mutations() async {
    final result = <int, List<int>>{};
    for (final row in (await database.query(
      DatabaseQuery(
        sql:
            'SELECT ordinal, batch_sequence '
            'FROM pending_mutations ORDER BY ordinal',
      ),
    )).rows) {
      (result[row['batch_sequence']! as int] ??= []).add(
        row['ordinal']! as int,
      );
    }
    return result;
  }

  Future<void> close() => fixture.close();
}

final class _FailingCanonicalStore implements CanonicalStore<TestId> {
  const _FailingCanonicalStore(this.delegate);

  final CanonicalStore<TestId> delegate;

  @override
  Future<void> upsert(TestId id, Map<String, Object?> values) {
    if (values['name'] == 'Broken') {
      throw const LocalStorageException('broken upsert');
    }
    return delegate.upsert(id, values);
  }

  @override
  Future<void> create(TestId id, Map<String, Object?> values) =>
      delegate.create(id, values);
  @override
  Future<void> update(TestId id, Map<String, Object?> patch) =>
      delegate.update(id, patch);
  @override
  Future<void> delete(TestId id) => delegate.delete(id);
  @override
  Future<void> purge(TestId id) => delegate.purge(id);
  @override
  Future<ModelRecord<TestId>?> get(TestId id) => delegate.get(id);
  @override
  Future<List<ModelRecord<TestId>>> readAll() => delegate.readAll();
  @override
  Future<List<TestId>> identitiesMatching(Map<String, Object?> fieldValues) =>
      delegate.identitiesMatching(fieldValues);
}

final class TestId extends ModelId {
  const TestId(this.id);

  final UUID id;

  @override
  Map<String, Object> get components => {'id': id};

  @override
  bool operator ==(Object other) => other is TestId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
