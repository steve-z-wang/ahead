import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';
  const bookScope = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  late TestLocalDatabase fixture;
  late MutationQueue outbox;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: testModelStatements,
    );
    outbox = MutationQueue(
      fixture.scope,
      registry: ModelRegistry([
        TypedModelRegistryEntry<TestId>(
          schema: testSchema,
          canonical: SqlCanonicalStore(
            database: fixture.scope,
            descriptor: testDescriptor,
          ),
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
      ]),
    );
  });

  tearDown(() => fixture.close());

  test('initializes sequence zero and rejects another client', () async {
    await outbox.initialize(clientId);
    await outbox.initialize(clientId);

    final state = await _clientState(fixture);
    expect(state?['client_id'], clientId);
    expect(state?['last_assigned_batch_sequence'], 0);
    await expectLater(
      outbox.initialize('550e8400-e29b-41d4-a716-446655440000'),
      throwsStateError,
    );
  });

  test('rejects an invalid client id without creating state', () async {
    await expectLater(
      outbox.initialize('not-a-uuid'),
      throwsA(isA<UplinkDataException>()),
    );
    expect(await _clientState(fixture), isNull);
  });

  test('binds legacy checkpoints only when one scope is unambiguous', () async {
    await fixture.database.execute(
      DatabaseStatement(
        sql:
            'INSERT INTO uplink_batches '
            '(sequence, legacy_required_sync_id) VALUES (7, 900), (8, 901)',
      ),
    );
    await expectLater(
      outbox.bindLegacyCheckpointScope([userScope, bookScope]),
      throwsStateError,
    );
    expect(
      (await _batches(fixture)).map((row) => row['legacy_required_sync_id']),
      [900, 901],
    );

    await outbox.bindLegacyCheckpointScope([userScope]);

    final rebound = await _batches(fixture);
    expect(
      rebound.map((row) => row['required_scope']),
      everyElement(userScope),
    );
    expect(rebound.map((row) => row['required_sync_id']), [900, 901]);
    expect(
      rebound.map((row) => row['legacy_required_sync_id']),
      everyElement(isNull),
    );
    expect(await _checkpoints(fixture), [
      {'batch_sequence': 7, 'scope': userScope, 'required_sync_id': 900},
      {'batch_sequence': 8, 'scope': userScope, 'required_sync_id': 901},
    ]);
  });

  test('watch emits initial state and committed sendable changes', () async {
    await outbox.initialize(clientId);
    final values = outbox.watchSendable().take(2).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await _seedMutation(fixture, 3);

    await expectLater(values, completion([false, true]));
  });

  test('a readiness change that leaves the counts equal still emits', () async {
    await outbox.initialize(clientId);
    await _seedMutation(fixture, 1);
    await fixture.database.execute(
      DatabaseStatement(
        sql: "INSERT INTO readiness_states (key, state) VALUES ('a', 'ready')",
      ),
    );
    final emissions = <bool>[];
    final subscription = outbox.watchSendable().listen(emissions.add);
    while (emissions.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final seen = emissions.length;

    // One commit prunes key a's mark while key b is vouched — the READY
    // COUNT does not move, but a waiting act gated on b is sendable now and
    // this may be the last write for a long time. The channel must emit; a
    // count-shaped distinct would swallow exactly this wake (the stall
    // CAP-513's cross-device cover test caught).
    await fixture.scope.transaction((_) async {
      await fixture.scope.current.execute(
        DatabaseStatement(sql: "DELETE FROM readiness_states WHERE key = 'a'"),
      );
      await fixture.scope.current.execute(
        DatabaseStatement(
          sql:
              "INSERT INTO readiness_states (key, state) VALUES ('b', 'ready')",
        ),
      );
    });

    var waited = 0;
    while (emissions.length == seen && waited < 2000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      waited += 5;
    }
    await subscription.cancel();
    expect(
      emissions.length,
      greaterThan(seen),
      reason: 'the coalesced prune+vouch commit must still wake the worker',
    );
  });

  test('candidate is the first limited prefix with next sequence', () async {
    await outbox.initialize(clientId);
    for (final ordinal in [3, 1, 2, 4]) {
      await _seedMutation(fixture, ordinal);
    }

    final candidate = await outbox.scheduledCandidate(limit: 3);

    expect(candidate?.clientId, clientId);
    expect(candidate?.batchSequence, 1);
    expect(candidate?.records.keys, [1, 2, 3]);
  });

  test('creates atomically, resumes Sending, and prevents another', () async {
    await outbox.initialize(clientId);
    await _seedMutation(fixture, 1);
    await _seedMutation(fixture, 2);

    final batch = await outbox.freeze(
      expectedSequence: 1,
      mutationOrdinals: const [1, 2],
    );

    expect(batch.batchSequence, 1);
    expect((await _clientState(fixture))?['last_assigned_batch_sequence'], 1);
    expect((await outbox.readInFlightBatch())?.mutations.length, 2);
    await _seedMutation(fixture, 3);
    await expectLater(
      outbox.freeze(expectedSequence: 2, mutationOrdinals: const [3]),
      throwsStateError,
    );
  });

  test('rejects a stale candidate without persistent changes', () async {
    await outbox.initialize(clientId);
    await _seedMutation(fixture, 1);

    await expectLater(
      outbox.freeze(expectedSequence: 2, mutationOrdinals: const [1]),
      throwsStateError,
    );

    expect(await _batches(fixture), isEmpty);
    expect((await _mutations(fixture)).single['batch_sequence'], isNull);
    expect((await _clientState(fixture))?['last_assigned_batch_sequence'], 0);
  });

  test('response deletes explicit rejections and retains batch', () async {
    await outbox.initialize(clientId);
    await _seedMutation(fixture, 1);
    await _seedMutation(fixture, 2);
    await outbox.freeze(expectedSequence: 1, mutationOrdinals: const [1, 2]);

    await outbox.recordResponse(
      batchSequence: 1,
      requiredCheckpoints: [
        UplinkCheckpoint(scope: userScope, syncId: 101),
        UplinkCheckpoint(scope: bookScope, syncId: 202),
      ],
      legacyPrincipalCheckpoint: UplinkCheckpoint(
        scope: userScope,
        syncId: 101,
      ),
      rejections: const [
        UplinkMutationRejection(mutationId: 2, code: 'space.denied'),
      ],
    );

    expect((await _mutations(fixture)).map((row) => row['ordinal']), [1]);
    final stored = (await _batches(fixture)).single;
    expect(stored['required_scope'], userScope);
    expect(stored['required_sync_id'], 101);
    expect(await _checkpoints(fixture), [
      {'batch_sequence': 1, 'scope': bookScope, 'required_sync_id': 202},
      {'batch_sequence': 1, 'scope': userScope, 'required_sync_id': 101},
    ]);
    expect(await outbox.readInFlightBatch(), isNull);
  });

  test('invalid response is atomic and all-rejected batch remains', () async {
    await outbox.initialize(clientId);
    await _seedMutation(fixture, 1);
    await outbox.freeze(expectedSequence: 1, mutationOrdinals: const [1]);

    await expectLater(
      outbox.recordResponse(
        batchSequence: 1,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 10)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 10,
        ),
        rejections: const [
          UplinkMutationRejection(mutationId: 99, code: 'unknown'),
        ],
      ),
      throwsStateError,
    );
    expect(await _mutations(fixture), hasLength(1));
    final unchanged = (await _batches(fixture)).single;
    expect(unchanged['required_scope'], isNull);
    expect(unchanged['required_sync_id'], isNull);

    await outbox.recordResponse(
      batchSequence: 1,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 10)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 10),
      rejections: const [
        UplinkMutationRejection(mutationId: 1, code: 'denied'),
      ],
    );
    expect(await _mutations(fixture), isEmpty);
    expect((await _batches(fixture)).single['required_sync_id'], 10);
  });
}

/// One queued operation, and the one-operation act it spells: no queued write
/// is anonymous (CAP-444).
Future<void> _seedMutation(TestLocalDatabase fixture, int ordinal) async {
  final record = await fixture.queueRecord();
  await fixture.database.execute(
    DatabaseStatement(
      sql: '''
        INSERT INTO pending_mutation_operations
          (mutation_ordinal, position, model, identity_json, operation,
           values_json, is_uplink)
        VALUES (?, 0, 'Test', ?, 'update', ?, 1)
      ''',
      variables: [
        record,
        '{"id":"${testId(ordinal).value}"}',
        '{"name":"$ordinal"}',
      ],
    ),
  );
}

Future<DatabaseRow?> _clientState(TestLocalDatabase fixture) async =>
    (await fixture.database.query(
      DatabaseQuery(sql: 'SELECT * FROM uplink_client_state'),
    )).singleOrNull;

Future<List<DatabaseRow>> _batches(TestLocalDatabase fixture) async =>
    (await fixture.database.query(
      DatabaseQuery(sql: 'SELECT * FROM uplink_batches ORDER BY sequence'),
    )).rows;

Future<List<Map<String, Object?>>> _checkpoints(
  TestLocalDatabase fixture,
) async => [
  for (final row in (await fixture.database.query(
    DatabaseQuery(
      sql:
          'SELECT * FROM uplink_batch_checkpoints '
          'ORDER BY batch_sequence, scope',
    ),
  )).rows)
    {
      'batch_sequence': row['batch_sequence'],
      'scope': row['scope'],
      'required_sync_id': row['required_sync_id'],
    },
];

Future<List<DatabaseRow>> _mutations(TestLocalDatabase fixture) async =>
    (await fixture.database.query(
      DatabaseQuery(sql: 'SELECT * FROM pending_mutations ORDER BY ordinal'),
    )).rows;
