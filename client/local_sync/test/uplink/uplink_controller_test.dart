import 'dart:async';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/fake_protocol_codec.dart';
import '../support/fake_uplink_transport.dart';
import '../support/test_database.dart';

void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue queue;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    queue = MutationQueue(fixture.scope, registry: family.registry);
    await queue.initialize(clientId);
    await family.space.create(spaceId, {'name': 'book'});
  });

  tearDown(() => fixture.close());

  test(
    'startup settles recorded receipts even when no work is sendable',
    () async {
      final settled = Completer<void>();
      const codec = FakeProtocolCodec();
      final transport = FakeUplinkTransport(const []);
      final controller = UplinkController(
        settleAccepted: () async {
          if (!settled.isCompleted) settled.complete();
        },
        queue: queue,
        codec: codec,
        scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
        prerequisiteRunner: PrerequisiteRunner(
          ledger: ReadinessLedger(fixture.scope),
          handlers: PrerequisiteHandlerRegistry(const {}),
          retryDelay: (_) => Duration.zero,
        ),
        executor: BatchExecutor(
          codec: codec,
          transport: transport,
          retryPolicy: RetryPolicy(randomDouble: () => 0),
        ),
      );
      controller.start();
      await settled.future.timeout(const Duration(seconds: 1));
      await controller.close();
      expect(transport.bodies, isEmpty);
    },
  );

  test('sends an unrelated ready act past readiness-blocked work', () async {
    await runtimes.mutate('CapturePage', [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: momentId,
        values: {'spaceId': spaceId.value, 'caption': 'page'},
      ),
      ModelCreateOperation(
        model: 'FamilyPhoto',
        id: FamilyPhotoId(familyUuid(3)),
        values: {'momentId': momentId.value, 'key': 'pending-photo'},
      ),
    ]);
    await runtimes.mutate('RenameSpace', [
      ModelUpdateOperation(
        model: 'FamilySpace',
        id: spaceId,
        patch: const {'name': 'renamed'},
      ),
    ]);

    final transport = FakeUplinkTransport([
      encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
    ]);
    final attempted = Completer<void>();
    final held = Completer<PrerequisiteAttemptResult>();
    final prerequisiteRunner = PrerequisiteRunner(
      ledger: ReadinessLedger(fixture.scope),
      handlers: PrerequisiteHandlerRegistry({
        'RemoteObject': (_) {
          if (!attempted.isCompleted) attempted.complete();
          return held.future;
        },
      }),
      retryDelay: (_) => Duration.zero,
    );
    const codec = FakeProtocolCodec();
    final controller = UplinkController(
      settleAccepted: () async {},
      queue: queue,
      codec: codec,
      scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
      prerequisiteRunner: prerequisiteRunner,
      executor: BatchExecutor(
        codec: codec,
        transport: transport,
        retryPolicy: RetryPolicy(randomDouble: () => 0),
        sleep: (_) async {},
      ),
    );

    controller.start();
    await attempted.future;
    await _waitUntil(() => transport.bodies.isNotEmpty);
    await controller.close();

    final request = decodeBytes(transport.bodies.single);
    final mutations = request['mutations']! as List<Object?>;
    expect(mutations, hasLength(1));
    expect((mutations.single! as Map<String, Object?>)['ordinal'], 2);
    final snapshot = await queue.snapshot();
    expect(snapshot[1]?.phase, MutationPhase.queued);
    expect(snapshot[1]?.readiness, ReadinessState.pending);
    expect(snapshot[2]?.phase, MutationPhase.accepted);
  });

  test(
    'parks terminal prerequisite failures and sends later unrelated work',
    () async {
      await runtimes.mutate('CapturePage', [
        ModelCreateOperation(
          model: 'FamilyMoment',
          id: momentId,
          values: {'spaceId': spaceId.value, 'caption': 'page'},
        ),
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: FamilyPhotoId(familyUuid(3)),
          values: {'momentId': momentId.value, 'key': 'pending-photo'},
        ),
      ]);

      final transport = FakeUplinkTransport([
        encodeBytes({'requiredSyncId': 7, 'rejections': <Object>[]}),
      ]);
      final attempted = Completer<void>();
      final prerequisiteRunner = PrerequisiteRunner(
        ledger: ReadinessLedger(fixture.scope),
        handlers: PrerequisiteHandlerRegistry({
          'RemoteObject': (_) {
            if (!attempted.isCompleted) attempted.complete();
            return Future.value(PrerequisiteAttemptResult.failed);
          },
        }),
        retryDelay: (_) => Duration.zero,
      );
      const codec = FakeProtocolCodec();
      final controller = UplinkController(
        settleAccepted: () async {},
        queue: queue,
        codec: codec,
        scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
        prerequisiteRunner: prerequisiteRunner,
        executor: BatchExecutor(
          codec: codec,
          transport: transport,
          retryPolicy: RetryPolicy(randomDouble: () => 0),
          sleep: (_) async {},
        ),
      );

      controller.start();
      await attempted.future;
      // Let the terminal result and its controller wake finish before a later
      // unrelated product act arrives. Closing immediately after the first send
      // would mask the automatic-drop pass this regression is about.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await runtimes.mutate('RenameSpace', [
        ModelUpdateOperation(
          model: 'FamilySpace',
          id: spaceId,
          patch: const {'name': 'renamed'},
        ),
      ]);
      await _waitUntil(() => transport.bodies.isNotEmpty);
      await controller.close();

      final request = decodeBytes(transport.bodies.single);
      final mutations = request['mutations']! as List<Object?>;
      expect(mutations, hasLength(1));
      expect((mutations.single! as Map<String, Object?>)['ordinal'], 2);
      final snapshot = await queue.snapshot();
      expect(snapshot[1]?.phase, MutationPhase.queued);
      expect(snapshot[1]?.readiness, ReadinessState.failed);
      expect(await family.moment.readMain(momentId), isNotNull);
      expect(
        await family.photo.readMain(FamilyPhotoId(familyUuid(3))),
        isNotNull,
      );
      expect(snapshot[2]?.phase, MutationPhase.accepted);
    },
  );

  test(
    'retries an existing frozen batch before taking a new snapshot',
    () async {
      await runtimes.mutate('RenameSpace', [
        ModelUpdateOperation(
          model: 'FamilySpace',
          id: spaceId,
          patch: const {'name': 'renamed'},
        ),
      ]);
      await queue.freeze(expectedSequence: 1, mutationOrdinals: const [1]);

      final transport = FakeUplinkTransport([
        encodeBytes({'requiredSyncId': 9, 'rejections': <Object>[]}),
      ]);
      const codec = FakeProtocolCodec();
      final controller = UplinkController(
        settleAccepted: () async {},
        queue: queue,
        codec: codec,
        scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
        prerequisiteRunner: PrerequisiteRunner(
          ledger: ReadinessLedger(fixture.scope),
          handlers: PrerequisiteHandlerRegistry(const {}),
          retryDelay: (_) => Duration.zero,
        ),
        executor: BatchExecutor(
          codec: codec,
          transport: transport,
          retryPolicy: RetryPolicy(randomDouble: () => 0),
          sleep: (_) async {},
        ),
      );

      controller.start();
      await _waitUntil(() => transport.bodies.isNotEmpty);
      await controller.close();

      expect((await queue.snapshot())[1]?.phase, MutationPhase.accepted);
    },
  );

  test(
    'unsupported version stops Uplink with the frozen batch and optimism intact',
    () async {
      await runtimes.mutate('RenameSpace', [
        ModelUpdateOperation(
          model: 'FamilySpace',
          id: spaceId,
          patch: const {'name': 'renamed'},
        ),
      ]);
      final transport = FakeUplinkTransport([
        LocalSyncHttpResponse(
          statusCode: 409,
          body: encodeBytes({
            'code': 'mutation_version_unsupported',
            'ordinal': 1,
            'name': 'RenameSpace',
            'version': 2,
          }),
        ),
      ]);
      final failures = <LocalSyncClientFailure>[];
      final codec = LocalSyncJsonCodec(registry: family.registry);
      final controller = UplinkController(
        settleAccepted: () async {},
        queue: queue,
        codec: codec,
        scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
        prerequisiteRunner: PrerequisiteRunner(
          ledger: ReadinessLedger(fixture.scope),
          handlers: PrerequisiteHandlerRegistry(const {}),
          retryDelay: (_) => Duration.zero,
        ),
        executor: BatchExecutor(
          codec: codec,
          transport: transport,
          retryPolicy: RetryPolicy(randomDouble: () => 0),
          sleep: (_) async {},
        ),
        failureObserver: failures.add,
      );
      controller.start();
      await _waitUntil(() => failures.isNotEmpty);
      await controller.close();
      expect(failures.single.fate, LocalSyncClientFailureFate.terminal);
      expect(transport.bodies, hasLength(1));
      final batch = (await queue.readInFlightBatch())!;
      expect(
        codec.encodeUplinkRequest(
          clientId: batch.clientId,
          batchSequence: batch.batchSequence,
          mutations: batch.mutations,
          records: batch.records,
        ),
        transport.bodies.single,
      );
      expect(
        (await fixture.scope.current.query(
          DatabaseQuery(sql: 'SELECT name FROM family_space'),
        )).singleOrNull!['name'],
        'renamed',
      );
      expect(
        (await fixture.scope.current.query(
          DatabaseQuery(sql: 'SELECT id FROM mutation_rejections'),
        )).isEmpty,
        isTrue,
      );
    },
  );

  test('reports one terminal root failure and closes cleanly', () async {
    await runtimes.mutate('RenameSpace', [
      ModelUpdateOperation(
        model: 'FamilySpace',
        id: spaceId,
        patch: const {'name': 'renamed'},
      ),
    ]);
    await fixture.scope.current.execute(
      DatabaseStatement(
        sql: "UPDATE pending_mutation_operations SET values_json = '{'",
      ),
    );
    final failures = <LocalSyncClientFailure>[];
    const codec = FakeProtocolCodec();
    final controller = UplinkController(
      settleAccepted: () async {},
      queue: queue,
      codec: codec,
      scheduler: const MutationScheduler(maxBytes: maximumUplinkBatchBytes),
      prerequisiteRunner: PrerequisiteRunner(
        ledger: ReadinessLedger(fixture.scope),
        handlers: PrerequisiteHandlerRegistry(const {}),
        retryDelay: (_) => Duration.zero,
      ),
      executor: BatchExecutor(
        codec: codec,
        transport: FakeUplinkTransport(const []),
        retryPolicy: RetryPolicy(randomDouble: () => 0),
        sleep: (_) async {},
      ),
      failureObserver: (failure) {
        failures.add(failure);
        throw StateError('observer');
      },
    );

    controller.start();
    await _waitUntil(() => failures.isNotEmpty);
    await controller.close().timeout(const Duration(seconds: 1));

    expect(failures, hasLength(1));
    expect(failures.single.error, isA<FormatException>());
    expect(failures.single.boundary, LocalSyncClientFailureBoundary.uplink);
    expect(failures.single.fate, LocalSyncClientFailureFate.terminal);
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200 && !condition(); attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!condition()) throw StateError('condition was not reached');
}
