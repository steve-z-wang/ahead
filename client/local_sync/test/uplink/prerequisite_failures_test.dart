import 'dart:async';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:local_sync_database_sqlite/local_sync_database_sqlite.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';
import '../support/fake_protocol_codec.dart';
import '../support/fake_uplink_transport.dart';

void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue queue;
  late ReadinessLedger ledger;
  late DatabaseReadOnlySql reads;
  late LocalSyncPrerequisites inbox;
  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    queue = MutationQueue(fixture.scope, registry: family.registry);
    ledger = ReadinessLedger(fixture.scope);
    reads = DatabaseReadOnlySql(fixture.database);
    inbox = LocalSyncPrerequisites(
      database: fixture.scope,
      registry: family.registry,
      reads: reads,
    );
    await queue.initialize(clientId);
    await family.space.create(spaceId, {'name': 'book'});
  });
  tearDown(() async {
    await reads.close();
    await fixture.close();
  });

  Future<void> capture(List<String> keys) => runtimes.mutate('CapturePage', [
    ModelCreateOperation(
      model: 'FamilyMoment',
      id: momentId,
      values: {'spaceId': spaceId.value, 'caption': 'local page'},
    ),
    for (var i = 0; i < keys.length; i++)
      ModelCreateOperation(
        model: 'FamilyPhoto',
        id: FamilyPhotoId(familyUuid(10 + i)),
        values: {'momentId': momentId.value, 'key': keys[i]},
      ),
  ]);

  test(
    'runner retries only after commit and can report a fresh failure',
    () async {
      await capture(['a']);
      await ledger.markFailed(remoteObject('a'));
      var attempts = 0;
      final transport = FakeUplinkTransport([
        encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
      ]);
      const codec = FakeProtocolCodec();
      final controller = UplinkController(
        settleAccepted: () async {},
        queue: queue,
        codec: codec,
        scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
        prerequisiteRunner: PrerequisiteRunner(
          ledger: ledger,
          handlers: PrerequisiteHandlerRegistry({
            'RemoteObject': (_) async {
              attempts++;
              return attempts == 1
                  ? PrerequisiteAttemptResult.failed
                  : PrerequisiteAttemptResult.ready;
            },
          }),
          retryDelay: (_) => Duration.zero,
        ),
        executor: BatchExecutor(
          codec: codec,
          transport: transport,
          retryPolicy: RetryPolicy(randomDouble: () => 0),
          sleep: (_) async {},
        ),
      );
      addTearDown(controller.close);
      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await expectLater(
        runtimes.transaction((tx) async {
          await tx.prerequisites.retry([remoteObject('a')]);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(attempts, 0);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(attempts, 0);
      expect(await ledger.read(remoteObject('a')), ReadinessState.failed);
      await runtimes.transaction((tx) async {
        await tx.prerequisites.retry([remoteObject('a')]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(attempts, 0);
      });
      await inbox
          .watchFailures()
          .firstWhere((items) => items.isNotEmpty)
          .timeout(const Duration(seconds: 2));
      expect(attempts, 1);
      expect(await family.moment.readMain(momentId), isNotNull);
      expect(transport.bodies, isEmpty);
      await inbox.retry([remoteObject('a')]);
      await _until(() => transport.bodies.isNotEmpty);
      expect(attempts, 2);
    },
  );

  test(
    'retry only resets failed referenced inputs and preserves optimism',
    () async {
      await capture(['failed', 'ready']);
      await ledger.markFailed(remoteObject('failed'));
      await ledger.markReady(remoteObject('ready'));
      await ledger.markFailed(remoteObject('orphan'));
      await inbox.retry([
        remoteObject('failed'),
        remoteObject('failed'),
        remoteObject('ready'),
        remoteObject('orphan'),
        remoteObject('missing'),
      ]);
      await inbox.retry([remoteObject('failed')]);
      expect(await ledger.read(remoteObject('failed')), ReadinessState.pending);
      expect(await ledger.read(remoteObject('ready')), ReadinessState.ready);
      expect(await ledger.read(remoteObject('orphan')), ReadinessState.failed);
      expect(await family.moment.readMain(momentId), isNotNull);
      expect((await queue.snapshot()).mutations, hasLength(1));
      expect(await inbox.watchFailures().first, isEmpty);
      await ledger.markFailed(remoteObject('failed'));
      expect(
        (await inbox.watchFailures().first).single.causes.single.invocation,
        remoteObject('failed'),
      );
    },
  );

  test('shared retry resets both acts together', () async {
    await capture(['shared']);
    await runtimes.mutate('AnotherAct', [
      ModelCreateOperation(
        model: 'FamilyPhoto',
        id: FamilyPhotoId(familyUuid(40)),
        values: {'momentId': momentId.value, 'key': 'shared'},
      ),
    ]);
    await ledger.markFailed(remoteObject('shared'));
    expect(await inbox.watchFailures().first, hasLength(2));
    await inbox.retry([remoteObject('shared')]);
    expect(await inbox.watchFailures().first, isEmpty);
    expect(
      (await queue.snapshot()).mutations.map((m) => m.readiness),
      everyElement(ReadinessState.pending),
    );
  });

  test(
    'failure carries complete immutable wire and companion snapshots',
    () async {
      await runtimes.apply(
        familyMutationRecord(
          name: 'CapturePage',
          operations: [
            ModelCreateOperation(
              model: 'FamilyPhoto',
              id: FamilyPhotoId(familyUuid(10)),
              values: {'momentId': momentId.value, 'key': 'a'},
            ),
          ],
        ),
        companions: (models) => models.moment.create(momentId, {
          'spaceId': spaceId.value,
          'caption': 'companion',
        }),
      );
      await ledger.markFailed(remoteObject('a'));
      final item = (await inbox.watchFailures().first).single;
      final List<LocalSyncOperationSnapshot> operations = item.operations;
      expect(operations.map((o) => o.position), [0, 1]);
      expect(operations.map((o) => o.isUplink), [false, true]);
      expect(operations.first.slotName, isNull);
      expect(operations.first.model, 'FamilyMoment');
      expect(operations.first.values['caption'], 'companion');
      expect(operations.last.identity, {'id': familyUuid(10).toString()});
      expect(operations.last.operation, MutationOperation.create);
      expect(() => operations.clear(), throwsUnsupportedError);
      expect(() => operations.first.values.clear(), throwsUnsupportedError);
      expect(() => operations.last.identity.clear(), throwsUnsupportedError);
    },
  );

  test(
    'retry and discard compose with replacement and outer rollback',
    () async {
      await capture(['a']);
      await ledger.markFailed(remoteObject('a'));
      final item = (await inbox.watchFailures().first).single;
      await expectLater(
        runtimes.transaction((tx) async {
          expect((await tx.prerequisites.getFailure(item.id))!.id, item.id);
          await tx.prerequisites.discard(item.id);
          expect(await tx.prerequisites.getFailure(item.id), isNull);
          await tx.mutate.apply(
            familyMutationRecord(
              name: 'Replacement',
              operations: [
                ModelCreateOperation(
                  model: 'FamilyPhoto',
                  id: FamilyPhotoId(familyUuid(40)),
                  values: {'momentId': momentId.value, 'key': 'a'},
                ),
              ],
            ),
          );
          await tx.prerequisites.retry([remoteObject('a')]);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect((await inbox.watchFailures().first).single.id, item.id);
      expect(await family.moment.readMain(momentId), isNotNull);
      expect(
        await family.photo.readMain(FamilyPhotoId(familyUuid(40))),
        isNull,
      );
      expect(await ledger.read(remoteObject('a')), ReadinessState.failed);
      await runtimes.transaction((tx) async {
        await tx.prerequisites.retry([remoteObject('a')]);
        expect(await tx.prerequisites.getFailure(item.id), isNull);
        await tx.prerequisites.discard(item.id); // stale handle
      });
      expect((await queue.snapshot()).mutations, hasLength(1));
    },
  );

  test(
    'transaction inbox rejects closed, named scope and sibling use',
    () async {
      await capture(['a']);
      await ledger.markFailed(remoteObject('a'));
      final id = (await inbox.watchFailures().first).single.id;
      late TransactionPrerequisites captured;
      await runtimes.transaction((tx) async {
        captured = tx.prerequisites;
        await tx.mutate.nothing(
          'Nothing',
          companions: (_) async {
            await expectLater(
              tx.prerequisites.getFailure(id),
              throwsStateError,
            );
            await expectLater(
              tx.prerequisites.retry([remoteObject('a')]),
              throwsStateError,
            );
            await expectLater(tx.prerequisites.discard(id), throwsStateError);
          },
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        final active = tx.mutate.nothing(
          'Nothing',
          companions: (_) async {
            entered.complete();
            await release.future;
          },
        );
        await entered.future;
        await expectLater(tx.prerequisites.getFailure(id), throwsStateError);
        release.complete();
        await active;
        final read = tx.prerequisites.getFailure(id);
        await expectLater(tx.prerequisites.getFailure(id), throwsStateError);
        await read;
      });
      await expectLater(captured.getFailure(id), throwsStateError);
      await expectLater(captured.retry([remoteObject('a')]), throwsStateError);
      await expectLater(captured.discard(id), throwsStateError);
    },
  );

  test(
    'one named act contains distinct failed causes and every binding',
    () async {
      await capture(['a', 'a', 'b', 'pending']);
      await ledger.markFailed(remoteObject('a'));
      await ledger.markFailed(remoteObject('b'));
      await ledger.markFailed(remoteObject('orphan'));
      final item = (await inbox.watchFailures().first).single;
      expect(item.mutationName, 'CapturePage');
      expect(item.mutationOrdinal, 1);
      expect(item.causes.map((cause) => cause.invocation), [
        remoteObject('a'),
        remoteObject('b'),
      ]);
      final bindings = item.causes.first.bindings;
      expect(bindings.map((b) => b.operationPosition), [1, 2]);
      expect(bindings.map((b) => b.model), everyElement('FamilyPhoto'));
      expect(bindings.map((b) => b.field), everyElement('key'));
      expect(bindings.first.operation, MutationOperation.create);
      expect(
        bindings.first.identity.components,
        FamilyPhotoId(familyUuid(10)).components,
      );
      expect(() => item.causes.clear(), throwsUnsupportedError);
      expect(() => bindings.clear(), throwsUnsupportedError);
      expect(await inbox.watchRequired().first, {
        remoteObject('a'),
        remoteObject('b'),
        remoteObject('pending'),
      });
      expect(await family.moment.readMain(momentId), isNotNull);
    },
  );

  test('discard rolls back the whole act and its lifecycle closure', () async {
    await capture(['a']);
    await runtimes.mutate('CropPhoto', [
      ModelCreateOperation(
        model: 'FamilyCrop',
        id: FamilyCropId(familyUuid(30)),
        values: {'photoId': familyUuid(10)},
      ),
    ]);
    await ledger.markFailed(remoteObject('a'));
    final item = (await inbox.watchFailures().first).single;
    await inbox.discard(item.id);
    await inbox.discard(item.id);
    expect(await inbox.watchFailures().first, isEmpty);
    expect(await inbox.watchRequired().first, isEmpty);
    expect((await queue.snapshot()).mutations, isEmpty);
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.photo.readMain(FamilyPhotoId(familyUuid(10))), isNull);
    expect(await family.crop.readMain(FamilyCropId(familyUuid(30))), isNull);
    expect(await ledger.read(remoteObject('a')), ReadinessState.pending);
    expect(
      await LocalSyncMutations(
        fixture.scope,
        reads: reads,
      ).watchRejections().first,
      isEmpty,
    );
  });

  test('discard preserves a sequence-only successor', () async {
    await capture(['a']);
    final update = ModelUpdateOperation(
      model: 'FamilySpace',
      id: spaceId,
      patch: {'name': 'later name'},
    );
    await runtimes.apply(
      MutationRecord(
        name: 'RenameSpace',
        slotOperations: [
          MutationSlotOperation(
            slotName: 'space',
            operation: update,
            allowedPatchFields: const ['name'],
          ),
        ],
        sequenceSelectors: [
          MutationSequenceSelector(
            predecessorMutation: 'CapturePage',
            predecessorSlot: 'wire0',
            predecessorRelations: const ['space'],
            currentPaths: [
              MutationSequenceCurrentPath(source: update, relations: const []),
            ],
          ),
        ],
      ),
    );
    await ledger.markFailed(remoteObject('a'));
    expect((await queue.snapshot())[2]!.sequencePredecessorOrdinals, {1});
    final item = (await inbox.watchFailures().first).single;
    await inbox.discard(item.id);
    final after = await queue.snapshot();
    expect(after.mutations.map((m) => m.mutation.ordinal), [2]);
    expect(after[2]!.sequencePredecessorOrdinals, isEmpty);
    expect(await queue.scheduledCandidate(limit: 20), isNotNull);
  });

  test('shared failure remains for the other act after one discard', () async {
    await capture(['shared']);
    await runtimes.mutate('CapturePage', [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: FamilyMomentId(familyUuid(3)),
        values: {'spaceId': spaceId.value, 'caption': 'another page'},
      ),
      ModelCreateOperation(
        model: 'FamilyPhoto',
        id: FamilyPhotoId(familyUuid(20)),
        values: {'momentId': familyUuid(3), 'key': 'shared'},
      ),
    ]);
    await ledger.markFailed(remoteObject('shared'));
    final items = await inbox.watchFailures().first;
    expect(items.map((i) => i.mutationOrdinal), [1, 2]);
    await inbox.discard(items.first.id);
    expect((await inbox.watchFailures().first).single.id, items.last.id);
    expect(await ledger.read(remoteObject('shared')), ReadinessState.failed);
    await inbox.discard(items.last.id);
    expect(await inbox.watchFailures().first, isEmpty);
  });

  test(
    'orphan marks and nonfailed/frozen mutations are not failures',
    () async {
      await ledger.markFailed(remoteObject('orphan'));
      expect(await inbox.watchFailures().first, isEmpty);
      await capture(['a']);
      expect(await inbox.watchFailures().first, isEmpty);
      await ledger.markFailed(remoteObject('a'));
      final stale = (await inbox.watchFailures().first).single;
      await ledger.markReady(remoteObject('a'));
      await inbox.discard(stale.id);
      expect((await queue.snapshot()).mutations, hasLength(1));
      await queue.freeze(expectedSequence: 1, mutationOrdinals: [1]);
      await ledger.markFailed(remoteObject('a'));
      expect(await inbox.watchFailures().first, isEmpty);
      await inbox.discard(stale.id);
      expect((await queue.snapshot())[1]?.phase, MutationPhase.frozen);
      expect(await inbox.watchRequired().first, {remoteObject('a')});
    },
  );

  test('one subscription stays live across empty cycles and closes', () async {
    final values = <List<LocalSyncPrerequisiteFailure>>[];
    final done = Completer<void>();
    final sub = inbox.watchFailures().listen(values.add, onDone: done.complete);
    addTearDown(sub.cancel);
    await _until(() => values.isNotEmpty);
    expect(values.last, isEmpty);
    await capture(['a']);
    await ledger.markFailed(remoteObject('a'));
    await _until(() => values.last.isNotEmpty);
    await inbox.discard(values.last.single.id);
    await _until(() => values.last.isEmpty);
    await capture(['b']);
    await ledger.markFailed(remoteObject('b'));
    await _until(() => values.last.isNotEmpty);
    await reads.close();
    await done.future.timeout(const Duration(seconds: 2));
  });

  test('restart retains failure ID, optimism and durable discard', () async {
    await capture(['a']);
    await ledger.markFailed(remoteObject('a'));
    final before = (await inbox.watchFailures().first).single;
    await reads.close();
    await fixture.database.close();
    final driver = SqliteDatabaseDriver.file(
      path: '${fixture.directory.path}/local-sync.sqlite',
      migrations: [
        SqliteDatabaseMigration(
          version: 1,
          statements: [
            ...localSyncInfrastructureStatements,
            ...familyModelStatements,
          ],
        ),
      ],
    );
    final reopened = await driver.open();
    final scope = LocalDatabaseScope(reopened);
    final registry = FamilyRegistry(scope);
    final reopenedReads = DatabaseReadOnlySql(reopened);
    final after = LocalSyncPrerequisites(
      database: scope,
      registry: registry.registry,
      reads: reopenedReads,
    );
    final retained = (await after.watchFailures().first).single;
    expect(retained.id, before.id);
    expect(retained.id.hashCode, before.id.hashCode);
    expect(await registry.moment.readMain(momentId), isNotNull);
    await after.discard(retained.id);
    await reopenedReads.close();
    await reopened.close();
    final again = await driver.open();
    addTearDown(again.close);
    final againScope = LocalDatabaseScope(again);
    final againReads = DatabaseReadOnlySql(again);
    addTearDown(againReads.close);
    expect(
      await LocalSyncPrerequisites(
        database: againScope,
        registry: FamilyRegistry(againScope).registry,
        reads: againReads,
      ).watchFailures().first,
      isEmpty,
    );
  });

  test('foreign client handle cannot discard the same local ordinal', () async {
    await capture(['a']);
    await ledger.markFailed(remoteObject('a'));
    final item = (await inbox.watchFailures().first).single;
    await fixture.database.execute(
      DatabaseStatement(
        sql: 'UPDATE uplink_client_state SET client_id = ?',
        variables: ['11111111-1111-4111-8111-111111111111'],
      ),
    );
    await runtimes.transaction((tx) async {
      expect(await tx.prerequisites.getFailure(item.id), isNull);
      await tx.prerequisites.discard(item.id);
    });
    final current = (await inbox.watchFailures().first).single;
    expect(current.id, isNot(item.id));
    expect(current.mutationOrdinal, item.mutationOrdinal);
  });

  test(
    'failed rollback leaves queue, optimism and failure unchanged',
    () async {
      await capture(['a']);
      await ledger.markFailed(remoteObject('a'));
      final item = (await inbox.watchFailures().first).single;
      await fixture.database.execute(
        DatabaseStatement(
          sql: '''
      CREATE TRIGGER fail_discard BEFORE DELETE ON family_moment
      BEGIN SELECT RAISE(ABORT, 'injected rollback failure'); END
    ''',
        ),
      );
      await expectLater(
        inbox.discard(item.id),
        throwsA(isA<DatabaseException>()),
      );
      expect((await inbox.watchFailures().first).single.id, item.id);
      expect(await family.moment.readMain(momentId), isNotNull);
      expect((await queue.snapshot()).mutations, hasLength(1));
    },
  );
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('stream did not reach the expected value');
}
