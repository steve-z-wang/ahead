import 'dart:async';
import 'dart:convert';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:local_sync_database_sqlite/local_sync_database_sqlite.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const checkpoint = UplinkCheckpoint(scope: 'test', syncId: 7);
  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late SqlMutationStore<TestId> operations;
  late ModelMutationWriter<TestId> writer;
  late MutationQueue queue;
  late LocalSyncMutations inbox;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: testModelStatements,
    );
    main = SqlCanonicalStore(
      database: fixture.scope,
      descriptor: testDescriptor,
    );
    final before = BeforeImageStore(
      database: fixture.scope,
      main: testDescriptor,
      before: testBeforeDescriptor,
    );
    operations = SqlMutationStore(database: fixture.scope, schema: testSchema);
    writer = ModelMutationWriter(operations, before: before, main: main);
    queue = MutationQueue(
      fixture.scope,
      registry: ModelRegistry([
        TypedModelRegistryEntry<TestId>(
          schema: testSchema,
          canonical: main,
          before: before,
          mutations: operations,
        ),
      ]),
    );
    await queue.initialize(clientId);
    inbox = LocalSyncMutations(
      fixture.scope,
      reads: DatabaseReadOnlySql(fixture.database),
    );
  });
  tearDown(() => fixture.close());

  Future<int> create(TestId id, {String name = 'CreateTest'}) async {
    final ordinal = await fixture.queueRecord(name: name);
    await writer.create(
      id,
      {'name': 'Local work', 'note': null},
      mutationOrdinal: ordinal,
      slotName: 'item',
      wire: true,
    );
    return ordinal;
  }

  Future<UplinkBatch> freeze(List<int> ordinals) async => queue.freeze(
    expectedSequence: (await queue.snapshot()).nextBatchSequence,
    mutationOrdinals: ordinals,
  );

  Future<void> answer(UplinkBatch batch, Map<int, String> reasons) =>
      queue.record(
        BatchExecutionResult(
          batchSequence: batch.batchSequence,
          requiredCheckpoints: const [checkpoint],
          legacyPrincipalCheckpoint: checkpoint,
          rejections: [
            for (final entry in reasons.entries)
              UplinkMutationRejection(mutationId: entry.key, code: entry.value),
          ],
        ),
      );

  test(
    'transaction rejection read and acknowledgment roll back together',
    () async {
      final ordinal = await create(idOne);
      await answer(await freeze([ordinal]), {ordinal: 'test.refused'});
      final item = (await inbox.watchRejections().first).single;
      final context = TransactionFateContext();
      final capability = TransactionMutationsInbox(
        fixture.scope,
        context: context,
      );
      await expectLater(
        fixture.scope.transaction((_) async {
          expect(
            (await capability.getRejection(item.id))!.code,
            'test.refused',
          );
          await capability.acknowledgeRejection(item.id);
          expect(await capability.getRejection(item.id), isNull);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect((await inbox.watchRejections().first).single.id, item.id);
      await fixture.scope.transaction((_) async {
        await context.runMutation(
          () => context.bindMutation(99, () async {
            await expectLater(
              capability.getRejection(item.id),
              throwsStateError,
            );
            await expectLater(
              capability.acknowledgeRejection(item.id),
              throwsStateError,
            );
          }),
        );
        await capability.acknowledgeRejection(item.id);
        await capability.acknowledgeRejection(item.id);
      });
      context.close();
      await expectLater(capability.getRejection(item.id), throwsStateError);
      await expectLater(
        capability.acknowledgeRejection(item.id),
        throwsStateError,
      );
      expect(await inbox.watchRejections().first, isEmpty);
    },
  );

  test(
    'retains every explicit reason and all slots/companions after rollback',
    () async {
      final first = await create(idOne);
      await writer.create(
        idTwo,
        {'name': 'Companion', 'note': null},
        mutationOrdinal: first,
        wire: false,
      );
      final second = await create(testId(2), name: 'AnotherAct');
      await answer(await freeze([first, second]), {
        second: 'future.reason',
        first: 'test.not_allowed',
      });

      final results = await inbox.watchRejections().first;
      expect(results.map((r) => r.mutationOrdinal), [first, second]);
      expect(results.map((r) => r.code), ['test.not_allowed', 'future.reason']);
      expect(results.map((r) => r.mutationName), ['CreateTest', 'AnotherAct']);
      final saved = results.first.operations;
      expect(saved, hasLength(2));
      expect(saved.map((o) => o.position), [0, 1]);
      expect(saved.map((o) => o.slotName), ['item', null]);
      expect(saved.map((o) => o.isUplink), [true, false]);
      expect(saved.first.model, 'Test');
      expect(saved.first.operation, MutationOperation.create);
      expect(saved.first.identity, {'id': idOne.value.toString()});
      expect(saved.first.values, {'name': 'Local work', 'note': null});
      expect(await main.get(idOne), isNull);
      expect(await main.get(idTwo), isNull);
      expect(await operations.readAll(), isEmpty);
      expect(() => results.clear(), throwsUnsupportedError);
      expect(() => saved.clear(), throwsUnsupportedError);
      expect(
        () => saved.first.values['name'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => saved.first.identity.clear(), throwsUnsupportedError);
    },
  );

  test(
    'cascaded dependents roll back without fabricated server refusals',
    () async {
      final root = await create(idOne);
      final child = await create(idTwo);
      await insertStoredMutationPrerequisites(fixture.scope, child, [
        StoredMutationPrerequisite(
          mutationOrdinal: child,
          prerequisiteOrdinal: root,
        ),
      ]);
      await answer(await freeze([root]), {root: 'root.refused'});
      expect(await main.get(idTwo), isNull);
      expect(
        (await inbox.watchRejections().first).map((r) => r.mutationOrdinal),
        [root],
      );
    },
  );

  test(
    'retains scope companions before the rejected parent cascades them',
    () async {
      final ordinal = await create(idOne);
      final scopes = ScopeStore(fixture.scope);
      await scopes.assignPending('Custom:room', true, mutationOrdinal: ordinal);
      await scopes.assignPending(
        'Custom:room',
        false,
        mutationOrdinal: ordinal,
      );
      await answer(await freeze([ordinal]), {ordinal: 'refused'});
      final retained = await fixture.database.query(
        DatabaseQuery(sql: 'SELECT * FROM mutation_rejections'),
      );
      expect(retained.columns, contains('scopes_json'));
      final result = (await inbox.watchRejections().first).single;
      expect(result.scopes.map((s) => s.desired), [true, false]);
      expect(result.scopes.map((s) => s.scope), ['Custom:room', 'Custom:room']);
      expect(() => result.scopes.clear(), throwsUnsupportedError);
      expect(jsonDecode(retained.rows.single['scopes_json']! as String), [
        {'position': 0, 'scope': 'Custom:room', 'desired': true},
        {'position': 1, 'scope': 'Custom:room', 'desired': false},
      ]);
    },
  );

  test(
    'acknowledgment only removes its result and repeated calls are no-ops',
    () async {
      final first = await create(idOne);
      final second = await create(idTwo);
      await answer(await freeze([first, second]), {first: 'a', second: 'b'});
      final results = await inbox.watchRejections().first;
      final pending = await create(testId(2));
      await Future.wait([
        inbox.acknowledgeRejection(results.first.id),
        inbox.acknowledgeRejection(results.first.id),
      ]);
      expect((await inbox.watchRejections().first).single.id, results.last.id);
      expect(
        (await queue.snapshot()).mutations.single.mutation.ordinal,
        pending,
      );
      expect((await main.get(testId(2)))?.fields['name'], 'Local work');
      expect(await main.get(idOne), isNull);
    },
  );

  test(
    'one subscription observes repeated empty and non-empty cycles',
    () async {
      final values = StreamIterator(inbox.watchRejections());
      addTearDown(values.cancel);
      expect(await values.moveNext(), isTrue);
      expect(values.current, isEmpty);
      for (var index = 0; index < 2; index++) {
        final ordinal = await create(testId(index));
        await answer(await freeze([ordinal]), {ordinal: 'refused'});
        expect(
          await values.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(values.current.single.mutationOrdinal, ordinal);
        await inbox.acknowledgeRejection(values.current.single.id);
        expect(
          await values.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(values.current, isEmpty);
      }
    },
  );

  test(
    'restart preserves result identity and acknowledgment stays durable',
    () async {
      final ordinal = await create(idOne);
      await answer(await freeze([ordinal]), {ordinal: 'refused'});
      final original = (await inbox.watchRejections().first).single;
      await fixture.database.close();
      final driver = SqliteDatabaseDriver.file(
        path: '${fixture.directory.path}/local-sync.sqlite',
        migrations: [
          SqliteDatabaseMigration(
            version: 1,
            statements: [
              ...localSyncInfrastructureStatements,
              ...testModelStatements,
            ],
          ),
        ],
      );
      final reopened = await driver.open();
      final after = LocalSyncMutations(
        LocalDatabaseScope(reopened),
        reads: DatabaseReadOnlySql(reopened),
      );
      final retained = (await after.watchRejections().first).single;
      expect(retained.id, original.id);
      expect(retained.id.hashCode, original.id.hashCode);
      expect(
        retained.operations.single.values,
        original.operations.single.values,
      );
      await after.acknowledgeRejection(retained.id);
      await reopened.close();
      final again = await driver.open();
      addTearDown(again.close);
      expect(
        await LocalSyncMutations(
          LocalDatabaseScope(again),
          reads: DatabaseReadOnlySql(again),
        ).watchRejections().first,
        isEmpty,
      );
    },
  );

  for (final boundary in ['store', 'rollback']) {
    test(
      '$boundary failure rolls back result, queue, checkpoint and optimism together',
      () async {
        final ordinal = await create(idOne);
        final batch = await freeze([ordinal]);
        final event = boundary == 'store'
            ? 'INSERT ON mutation_rejections'
            : 'DELETE ON pending_mutations';
        await fixture.database.execute(
          DatabaseStatement(
            sql:
                '''
        CREATE TRIGGER fail_result BEFORE $event
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END
      ''',
          ),
        );
        await expectLater(
          answer(batch, {ordinal: 'refused'}),
          throwsA(isA<DatabaseException>()),
        );
        expect(await inbox.watchRejections().first, isEmpty);
        expect((await main.get(idOne))?.fields['name'], 'Local work');
        expect(
          (await queue.snapshot()).mutations.single.phase,
          MutationPhase.frozen,
        );
        final checkpoints = await fixture.database.query(
          DatabaseQuery(sql: 'SELECT * FROM uplink_batch_checkpoints'),
        );
        expect(checkpoints.isEmpty, isTrue);
        await fixture.database.execute(
          DatabaseStatement(sql: 'DROP TRIGGER fail_result'),
        );
        await answer(batch, {ordinal: 'refused'});
        expect((await inbox.watchRejections().first).single.code, 'refused');
      },
    );
  }

  test(
    'invalid response creates no partial results and acceptance creates none',
    () async {
      final ordinal = await create(idOne);
      final batch = await freeze([ordinal]);
      await expectLater(
        answer(batch, {ordinal: 'valid', 999: 'invalid'}),
        throwsStateError,
      );
      expect(await inbox.watchRejections().first, isEmpty);
      expect(await main.get(idOne), isNotNull);
      await answer(batch, {});
      expect(await inbox.watchRejections().first, isEmpty);
    },
  );

  test(
    'legacy wire ordinals resolve to the original named local record',
    () async {
      final ordinal = await create(idOne);
      await fixture.database.execute(
        DatabaseStatement(
          sql:
              'UPDATE pending_mutations SET legacy_wire_ordinal = 81 WHERE ordinal = ?',
          variables: [ordinal],
        ),
      );
      await answer(await freeze([ordinal]), {81: 'legacy.refused'});
      final result = (await inbox.watchRejections().first).single;
      expect(result.mutationOrdinal, ordinal);
      expect(result.mutationName, 'CreateTest');
      expect(result.operations.single.values['name'], 'Local work');
    },
  );

  test(
    'a foreign client handle cannot acknowledge the same local ordinal',
    () async {
      final ordinal = await create(idOne);
      await answer(await freeze([ordinal]), {ordinal: 'refused'});
      final original = (await inbox.watchRejections().first).single;
      final row = (await fixture.database.query(
        DatabaseQuery(sql: 'SELECT * FROM mutation_rejections'),
      )).rows.single;
      expect(row['id'], '$clientId:$ordinal');
      final other = await TestLocalDatabase.open();
      addTearDown(other.close);
      await other.database.execute(
        DatabaseStatement(
          sql: '''INSERT INTO mutation_rejections
              (id, mutation_ordinal, name, code, operations_json, scopes_json)
              VALUES (?, ?, ?, ?, ?, ?)''',
          variables: [
            'other-client:$ordinal',
            ordinal,
            row['name'],
            row['code'],
            row['operations_json'],
            row['scopes_json'],
          ],
        ),
      );
      final otherInbox = LocalSyncMutations(
        other.scope,
        reads: DatabaseReadOnlySql(other.database),
      );
      final foreign = (await otherInbox.watchRejections().first).single;
      expect(foreign.id, isNot(original.id));
      await otherInbox.acknowledgeRejection(original.id);
      await inbox.acknowledgeRejection(foreign.id);
      expect((await inbox.watchRejections().first).single.id, original.id);
      expect((await otherInbox.watchRejections().first).single.id, foreign.id);
    },
  );

  test(
    'later acceptance and stale response replay do not erase retained results',
    () async {
      final ordinal = await create(idOne);
      final batch = await freeze([ordinal]);
      await answer(batch, {ordinal: 'refused'});
      final original = (await inbox.watchRejections().first).single;
      await expectLater(answer(batch, {ordinal: 'refused'}), throwsStateError);
      final next = await create(idTwo);
      await answer(await freeze([next]), {});
      expect((await inbox.watchRejections().first).single.id, original.id);
    },
  );

  test(
    'historical values remain readable without consulting the current Model schema',
    () async {
      final ordinal = await create(idOne);
      await answer(await freeze([ordinal]), {ordinal: 'refused'});
      // A retained result can describe a now-retired Model and nested old fields.
      await fixture.database.execute(
        DatabaseStatement(
          sql: 'UPDATE mutation_rejections SET operations_json = ?',
          variables: [
            jsonEncode([
              {
                'position': 0,
                'slot': 'old',
                'model': 'RetiredModel',
                'identity': {'left': 'a', 'right': 2},
                'operation': 'update',
                'values': {
                  'oldField': [
                    {'flag': true},
                    null,
                  ],
                },
                'wire': true,
              },
            ]),
          ],
        ),
      );
      final old =
          (await inbox.watchRejections().first).single.operations.single;
      expect(old.model, 'RetiredModel');
      expect(old.identity, {'left': 'a', 'right': 2});
      expect(old.operation, MutationOperation.update);
      final nested = old.values['oldField']! as List;
      expect(() => nested.add('no'), throwsUnsupportedError);
      expect(
        () => (nested.first as Map)['flag'] = false,
        throwsUnsupportedError,
      );
    },
  );
}
