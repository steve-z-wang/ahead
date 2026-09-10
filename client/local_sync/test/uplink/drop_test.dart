import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// Explicit prerequisite discard reuses rejection and lifecycle rollback.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue outbox;
  late ReadinessLedger ledger;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));
  final goodPhotoId = FamilyPhotoId(familyUuid(3));
  final doomedPhotoId = FamilyPhotoId(familyUuid(4));
  final cropId = FamilyCropId(familyUuid(5));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    ledger = ReadinessLedger(fixture.scope);
    outbox = MutationQueue(fixture.scope, registry: family.registry);
    await outbox.initialize(clientId);
    await family.space.create(spaceId, {'name': 'book'});
  });

  tearDown(() => fixture.close());

  /// Two acts: the page with the photo it was captured with, and a second
  /// photo attached afterwards. Two names, so two fates — which is what the
  /// drop has to be able to tell apart.
  Future<void> writePage() async {
    await runtimes.mutate('CapturePage', [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: momentId,
        values: {'spaceId': spaceId.value, 'caption': 'a page'},
      ),
      ModelCreateOperation(
        model: 'FamilyPhoto',
        id: goodPhotoId,
        values: {'momentId': momentId.value, 'key': 'good'},
      ),
    ]);
    await runtimes.mutate('AttachPhoto', [
      ModelCreateOperation(
        model: 'FamilyPhoto',
        id: doomedPhotoId,
        values: {'momentId': momentId.value, 'key': 'doomed'},
      ),
    ]);
  }

  Future<List<int>> queuedOrdinals() async {
    final result = await fixture.scope.current.query(
      DatabaseQuery(
        sql: 'SELECT ordinal FROM pending_mutations ORDER BY ordinal',
      ),
    );
    return [for (final row in result.rows) row['ordinal']! as int];
  }

  test('discard removes only the doomed act and its neighbour ships', () async {
    await writePage();
    await ledger.markReady(remoteObject('good'));
    await ledger.markFailed(remoteObject('doomed'));
    await outbox.discardFailed(clientId: clientId, ordinal: 2);

    final candidate = await outbox.scheduledCandidate(limit: 20);

    // The capture act carries no failed key, so it ships whole; only the act
    // that named the doomed upload dies.
    expect(candidate!.records.keys, [1]);
    expect(candidate.mutations.map((row) => row.position), [0, 1]);
    expect(await queuedOrdinals(), [1]);
    // The row is rebuilt away: it never existed for the server, and it no
    // longer exists here.
    expect(await family.photo.readMain(doomedPhotoId), isNull);
    expect(await family.photo.readBefore(doomedPhotoId), isNull);
    expect(await family.photo.readMain(goodPhotoId), isNotNull);
  });

  test('the doomed row takes its dependants with it', () async {
    await writePage();
    await runtimes.mutate('CropPhoto', [
      ModelCreateOperation(
        model: 'FamilyCrop',
        id: cropId,
        values: {'photoId': doomedPhotoId.value},
      ),
    ]);
    await ledger.markReady(remoteObject('good'));
    await ledger.markFailed(remoteObject('doomed'));
    await outbox.discardFailed(clientId: clientId, ordinal: 2);

    await outbox.scheduledCandidate(limit: 20);

    // The crop pointed at a row that will never exist, so it goes too — the
    // dependency closure, exactly as a rejection computes it.
    expect(await queuedOrdinals(), [1]);
    expect(await family.crop.readMain(cropId), isNull);
  });

  test('the moment itself is untouched', () async {
    await writePage();
    await ledger.markReady(remoteObject('good'));
    await ledger.markFailed(remoteObject('doomed'));
    await outbox.discardFailed(clientId: clientId, ordinal: 2);

    await outbox.scheduledCandidate(limit: 20);

    expect(await family.moment.readMain(momentId), isNotNull);
    expect(await family.moment.pendingMutations(momentId), hasLength(1));
  });

  test('the ledger row is pruned once nothing references it', () async {
    await writePage();
    await ledger.markReady(remoteObject('good'));
    await ledger.markFailed(remoteObject('doomed'));
    await outbox.discardFailed(clientId: clientId, ordinal: 2);

    await outbox.scheduledCandidate(limit: 20);

    expect(await ledger.read(remoteObject('doomed')), ReadinessState.pending);
    // The surviving key is still referenced by a queued mutation, so it stays.
    expect(await ledger.read(remoteObject('good')), ReadinessState.ready);
  });

  test('a frozen batch is never touched', () async {
    await writePage();
    await ledger.markReady(remoteObject('good'));
    await ledger.markReady(remoteObject('doomed'));

    final candidate = await outbox.scheduledCandidate(limit: 20);
    await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: candidate.records.keys.toList(),
    );

    // The mark arrives while the first act is in flight. The frozen act is
    // untouched, while its still-queued lifecycle dependent is dropped.
    await ledger.markFailed(remoteObject('doomed'));
    await outbox.discardFailed(clientId: clientId, ordinal: 2);
    expect(await outbox.scheduledCandidate(limit: 20), isNull);
    expect(await queuedOrdinals(), [1]);
    expect(await family.photo.readMain(doomedPhotoId), isNull);
    expect(await family.moment.readMain(momentId), isNotNull);
  });

  test(
    'a drop keeps a mark another queued act still references (CAP-521)',
    () async {
      // Two acts carry the SAME readiness key — a clip's mp4 uploading once
      // while two pages wait on it is the product shape. One act also carries
      // its own doomed key, so the drop removes it alone.
      await runtimes.mutate('CapturePage', [
        ModelCreateOperation(
          model: 'FamilyMoment',
          id: momentId,
          values: {'spaceId': spaceId.value, 'caption': 'a page'},
        ),
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: goodPhotoId,
          values: {'momentId': momentId.value, 'key': 'shared'},
        ),
      ]);
      await runtimes.mutate('AttachPhoto', [
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: doomedPhotoId,
          values: {'momentId': momentId.value, 'key': 'shared'},
        ),
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: FamilyPhotoId(familyUuid(6)),
          values: {'momentId': momentId.value, 'key': 'doomed'},
        ),
      ]);
      await ledger.markReady(remoteObject('shared'));
      await ledger.markFailed(remoteObject('doomed'));
      await outbox.discardFailed(clientId: clientId, ordinal: 2);

      await outbox.scheduledCandidate(limit: 20);

      // The doomed act is gone, but the first act still waits on 'shared':
      // pruning it would strand that page unsendable forever.
      expect(await queuedOrdinals(), [1]);
      expect(await ledger.read(remoteObject('shared')), ReadinessState.ready);
      expect(await ledger.read(remoteObject('doomed')), ReadinessState.pending);
    },
  );

  test(
    'a rejection keeps a mark a surviving act still references (CAP-521)',
    () async {
      await runtimes.mutate('CapturePage', [
        ModelCreateOperation(
          model: 'FamilyMoment',
          id: momentId,
          values: {'spaceId': spaceId.value, 'caption': 'a page'},
        ),
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: goodPhotoId,
          values: {'momentId': momentId.value, 'key': 'shared'},
        ),
      ]);
      await runtimes.mutate('CapturePage', [
        ModelCreateOperation(
          model: 'FamilyMoment',
          id: FamilyMomentId(familyUuid(6)),
          values: {'spaceId': spaceId.value, 'caption': 'another page'},
        ),
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: FamilyPhotoId(familyUuid(7)),
          values: {'momentId': familyUuid(6), 'key': 'shared'},
        ),
      ]);
      await ledger.markReady(remoteObject('shared'));

      final candidate = await outbox.scheduledCandidate(limit: 20);
      await outbox.freeze(
        expectedSequence: candidate!.batchSequence,
        mutationOrdinals: candidate.records.keys.toList(),
      );
      await outbox.recordResponse(
        batchSequence: candidate.batchSequence,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 1)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 1,
        ),
        rejections: const [
          UplinkMutationRejection(mutationId: 2, code: 'mutation.invalid'),
        ],
      );

      // The rejected act left the queue, but the independent accepted act is
      // still queued until Downlink settlement and still carries 'shared'.
      expect(await ledger.read(remoteObject('shared')), ReadinessState.ready);
    },
  );

  test('a rejection prunes the keys of the mutations it removed', () async {
    await writePage();
    await ledger.markReady(remoteObject('good'));
    await ledger.markReady(remoteObject('doomed'));

    final first = await outbox.scheduledCandidate(limit: 20);
    final firstBatch = await outbox.freeze(
      expectedSequence: first!.batchSequence,
      mutationOrdinals: first.records.keys.toList(),
    );
    await outbox.recordResponse(
      batchSequence: firstBatch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 1)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 1),
      rejections: const [],
    );
    final downlink = DownlinkPageProcessor(
      database: fixture.scope,
      registry: family.registry,
      decoder: ModelChangeDecoder(family.registry),
    );
    await setTestScopes(fixture.scope, [userScope]);
    final settled = await downlink.apply(
      DownlinkPage(
        scope: userScope,
        fromSyncId: 0,
        throughSyncId: 1,
        changes: const [],
      ),
      afterSyncId: 0,
    );
    expect(settled.failures, isEmpty);

    final second = await outbox.scheduledCandidate(limit: 20);
    final secondBatch = await outbox.freeze(
      expectedSequence: second!.batchSequence,
      mutationOrdinals: second.records.keys.toList(),
    );
    await outbox.recordResponse(
      batchSequence: secondBatch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 2)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 2),
      rejections: const [
        UplinkMutationRejection(mutationId: 2, code: 'mutation.invalid'),
      ],
    );

    // Each key disappears once the last mutation carrying it settles or is
    // rejected.
    expect(await ledger.read(remoteObject('doomed')), ReadinessState.pending);
    expect(await ledger.read(remoteObject('good')), ReadinessState.pending);
  });
}
