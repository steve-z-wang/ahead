import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

/// Flow ② (CAP-393 spec §4): a rejection drops the edit from the queue and the
/// rows it touched are rebuilt inside the settlement transaction that already
/// exists.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';

  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late BeforeImageStore<TestId> before;
  late SqlMutationStore<TestId> mutations;
  late ModelMutationWriter<TestId> writer;
  late MutationQueue outbox;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: testModelStatements,
    );
    main = SqlCanonicalStore(
      database: fixture.scope,
      descriptor: testDescriptor,
    );
    before = BeforeImageStore(
      database: fixture.scope,
      main: testDescriptor,
      before: testBeforeDescriptor,
    );
    mutations = SqlMutationStore(database: fixture.scope, schema: testSchema);
    writer = ModelMutationWriter(mutations, before: before, main: main);
    outbox = MutationQueue(
      fixture.scope,
      registry: ModelRegistry([
        TypedModelRegistryEntry<TestId>(
          schema: testSchema,
          canonical: main,
          before: before,
          mutations: mutations,
        ),
      ]),
    );
    await outbox.initialize(clientId);
  });

  tearDown(() => fixture.close());

  // Each edit is its own named act, so the server can refuse one and leave the
  // others standing — which is the whole subject here.
  Future<void> create(TestId id, Map<String, Object?> values) async {
    await writer.create(
      id,
      values,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
  }

  Future<void> update(TestId id, Map<String, Object?> patch) async {
    await writer.update(
      id,
      patch,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
  }

  Future<void> remove(TestId id) async {
    await writer.delete(
      id,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
  }

  Future<int> send() async {
    final candidate = await outbox.scheduledCandidate(limit: 100);
    final batch = await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: candidate.records.keys.toList(),
    );
    return batch.batchSequence;
  }

  Future<void> prerequisite(int dependent, int earlier) =>
      fixture.scope.current.execute(
        DatabaseStatement(
          sql:
              'INSERT INTO pending_mutation_prerequisites '
              '(mutation_ordinal, prerequisite_ordinal) VALUES (?, ?)',
          variables: [dependent, earlier],
        ),
      );

  Future<void> sequence(int dependent, int earlier) =>
      fixture.scope.current.execute(
        DatabaseStatement(
          sql:
              'INSERT INTO pending_mutation_sequences '
              '(mutation_ordinal, predecessor_ordinal) VALUES (?, ?)',
          variables: [dependent, earlier],
        ),
      );

  Future<void> rejectOnly(int ordinal) async {
    final snapshot = await outbox.snapshot();
    final batch = await outbox.freeze(
      expectedSequence: snapshot.nextBatchSequence,
      mutationOrdinals: [ordinal],
    );
    await outbox.record(
      BatchExecutionResult(
        batchSequence: batch.batchSequence,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 7,
        ),
        rejections: [
          UplinkMutationRejection(mutationId: ordinal, code: 'refused'),
        ],
      ),
    );
  }

  test(
    'rollback retains the explicit rejection after deleting its act',
    () async {
      await create(idOne, {'name': 'Unsaved work', 'note': null});
      await rejectOnly(1);

      expect(await main.get(idOne), isNull);
      expect(await mutations.readAll(), isEmpty);
      final tables = await fixture.database.query(
        DatabaseQuery(
          sql: "SELECT name FROM sqlite_master WHERE type = 'table'",
        ),
      );
      expect(
        tables.rows.map((row) => row['name']),
        contains('mutation_rejections'),
        reason: 'a refusal must remain accessible after its queue row is gone',
      );
      final results = await fixture.database.query(
        DatabaseQuery(sql: 'SELECT name, code FROM mutation_rejections'),
      );
      expect(
        [
          for (final row in results.rows)
            {'name': row['name'], 'code': row['code']},
        ],
        [
          {'name': 'Act', 'code': 'refused'},
        ],
      );
    },
  );

  test('rejecting one of several edits replays the survivors', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});
    await update(idOne, {'name': 'First'});
    await update(idOne, {'note': 'second'});
    await update(idOne, {'name': 'Third'});
    final ordinals = (await mutations.read(
      idOne,
    )).map((mutation) => mutation.position.mutationOrdinal).toList();
    final batch = await send();

    await outbox.recordResponse(
      batchSequence: batch,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [
        UplinkMutationRejection(mutationId: ordinals[1], code: 'refused'),
      ],
    );

    // Truth, then the first and third edits — the rejected one leaves no
    // trace, and the survivors keep their order.
    expect((await main.get(idOne))?.fields, {'name': 'Third', 'note': null});
    expect(await mutations.read(idOne), hasLength(2));
    expect(await before.exists(idOne), isTrue);
  });

  test('rejecting the only edit copies truth back and drops it', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});
    await update(idOne, {'name': 'Optimistic'});
    final only = (await mutations.read(idOne)).single.position.mutationOrdinal;
    final batch = await send();

    await outbox.recordResponse(
      batchSequence: batch,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [UplinkMutationRejection(mutationId: only, code: 'refused')],
    );

    expect((await main.get(idOne))?.fields['name'], 'Truth');
    expect(await mutations.read(idOne), isEmpty);
    expect(await before.exists(idOne), isFalse);
  });

  test('rejecting a create leaves no row at all', () async {
    await create(idOne, {'name': 'Optimistic', 'note': null});
    final only = (await mutations.read(idOne)).single.position.mutationOrdinal;
    final batch = await send();

    await outbox.recordResponse(
      batchSequence: batch,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [UplinkMutationRejection(mutationId: only, code: 'refused')],
    );

    expect(await main.get(idOne), isNull);
    expect(await before.exists(idOne), isFalse);
  });

  test('rejecting a delete puts the row back', () async {
    await main.create(idOne, {'name': 'Truth', 'note': 'kept'});
    await remove(idOne);
    final only = (await mutations.read(idOne)).single.position.mutationOrdinal;
    final batch = await send();

    await outbox.recordResponse(
      batchSequence: batch,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [UplinkMutationRejection(mutationId: only, code: 'refused')],
    );

    expect((await main.get(idOne))?.fields, {'name': 'Truth', 'note': 'kept'});
    expect(await before.exists(idOne), isFalse);
  });

  test('an accepted batch disturbs nothing', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});
    await update(idOne, {'name': 'Optimistic'});
    final batch = await send();

    await outbox.recordResponse(
      batchSequence: batch,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: const [],
    );

    expect((await main.get(idOne))?.fields['name'], 'Optimistic');
    expect(await before.exists(idOne), isTrue);
  });

  test('an invalid response changes nothing at all', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});
    await update(idOne, {'name': 'Optimistic'});
    final batch = await send();

    await expectLater(
      outbox.recordResponse(
        batchSequence: batch,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 7,
        ),
        rejections: [
          const UplinkMutationRejection(mutationId: 9999, code: 'unknown'),
        ],
      ),
      throwsStateError,
    );

    expect((await main.get(idOne))?.fields['name'], 'Optimistic');
    expect(await mutations.read(idOne), hasLength(1));
    expect(await before.exists(idOne), isTrue);
  });

  test('rejections across two rows rebuild each of them', () async {
    await main.create(idOne, {'name': 'One', 'note': null});
    await main.create(idTwo, {'name': 'Two', 'note': null});
    await update(idOne, {'name': 'One edited'});
    await update(idTwo, {'name': 'Two edited'});
    final ordinals = [
      (await mutations.read(idOne)).single.position.mutationOrdinal,
      (await mutations.read(idTwo)).single.position.mutationOrdinal,
    ];
    final batch = await send();

    await outbox.recordResponse(
      batchSequence: batch,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [
        for (final ordinal in ordinals)
          UplinkMutationRejection(mutationId: ordinal, code: 'refused'),
      ],
    );

    expect((await main.get(idOne))?.fields['name'], 'One');
    expect((await main.get(idTwo))?.fields['name'], 'Two');
    expect(await before.exists(idOne), isFalse);
    expect(await before.exists(idTwo), isFalse);
  });

  test('rejection recursively removes lifecycle dependents', () async {
    final third = testId(2);
    await create(idOne, {'name': 'root', 'note': null});
    await create(idTwo, {'name': 'child', 'note': null});
    await create(third, {'name': 'grandchild', 'note': null});
    await prerequisite(2, 1);
    await prerequisite(3, 2);

    await rejectOnly(1);

    expect(await main.get(idOne), isNull);
    expect(await main.get(idTwo), isNull);
    expect(await main.get(third), isNull);
    expect(await mutations.readAll(), isEmpty);
  });

  test(
    'one failed prerequisite condemns a multi-prerequisite dependent',
    () async {
      final dependent = testId(2);
      await create(idOne, {'name': 'first root', 'note': null});
      await create(idTwo, {'name': 'second root', 'note': null});
      await create(dependent, {'name': 'dependent', 'note': null});
      await prerequisite(3, 1);
      await prerequisite(3, 2);

      await rejectOnly(1);

      expect(await main.get(idOne), isNull);
      expect(await main.get(idTwo), isNotNull);
      expect(await main.get(dependent), isNull);
      expect((await mutations.read(idTwo)), hasLength(1));
    },
  );

  test('a sequence-only dependent survives predecessor rejection', () async {
    await create(idOne, {'name': 'root', 'note': null});
    await create(idTwo, {'name': 'ordered only', 'note': null});
    await sequence(2, 1);

    await rejectOnly(1);

    expect(await main.get(idOne), isNull);
    expect((await main.get(idTwo))?.fields['name'], 'ordered only');
    expect((await mutations.read(idTwo)), hasLength(1));
  });

  test(
    'settling an accepted delete rebuilds a later queued recreate',
    () async {
      await create(idOne, {'name': 'first', 'note': null});
      await remove(idOne);
      await create(idOne, {'name': 'later', 'note': null});

      final candidate = await outbox.scheduledCandidate(limit: 2);
      final batch = await outbox.freeze(
        expectedSequence: candidate!.batchSequence,
        mutationOrdinals: candidate.records.keys.toList(),
      );
      await outbox.recordResponse(
        batchSequence: batch.batchSequence,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 7,
        ),
        rejections: const [
          UplinkMutationRejection(mutationId: 1, code: 'refused'),
        ],
      );

      final downlink = DownlinkPageProcessor(
        database: fixture.scope,
        registry: outbox.registry,
        decoder: ModelChangeDecoder(outbox.registry),
      );
      await setTestScopes(fixture.scope, [userScope]);
      final result = await downlink.apply(
        DownlinkPage(
          scope: userScope,
          fromSyncId: 0,
          throughSyncId: 7,
          changes: const [],
        ),
        afterSyncId: 0,
      );

      expect(result.failures, isEmpty);
      expect((await main.get(idOne))?.fields, {'name': 'later', 'note': null});
      expect(await mutations.read(idOne), hasLength(1));
    },
  );
}
