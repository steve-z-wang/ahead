import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// The status stream (spec §6): read-only, identity-keyed, derived entirely
/// from the queue, the ledger and the batch state.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue outbox;
  late ReadinessLedger ledger;
  late UplinkStatusView status;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));
  final photoId = FamilyPhotoId(familyUuid(3));
  final stableMomentId = FamilyMomentId(familyUuid(4));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    ledger = ReadinessLedger(fixture.scope);
    outbox = MutationQueue(fixture.scope, registry: family.registry);
    status = UplinkStatusView(
      database: fixture.scope,
      registry: family.registry,
    );
    await outbox.initialize(clientId);
    await family.space.create(spaceId, {'name': 'book'});
    await family.moment.create(stableMomentId, {
      'spaceId': spaceId.value,
      'caption': 'already canonical',
    });
  });

  tearDown(() => fixture.close());

  /// One named act: the page and the photo on it.
  Future<void> writePage() => runtimes.mutate('CapturePage', [
    ModelCreateOperation(
      model: 'FamilyMoment',
      id: momentId,
      values: {'spaceId': spaceId.value, 'caption': 'a page'},
    ),
    ModelCreateOperation(
      model: 'FamilyPhoto',
      id: photoId,
      values: {'momentId': momentId.value, 'key': 'upload'},
    ),
  ]);

  Future<UplinkBatch> freeze() async {
    final candidate = await outbox.scheduledCandidate(limit: 20);
    return outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: candidate.records.keys.toList(),
    );
  }

  Future<void> writeTag(FamilyTagId id) => runtimes.mutate('TagPage', [
    ModelCreateOperation(
      model: 'FamilyTag',
      id: id,
      values: {'momentId': stableMomentId.value},
    ),
  ]);

  Future<void> reject(UplinkBatch batch) => outbox.recordResponse(
    batchSequence: batch.batchSequence,
    requiredCheckpoints: const [UplinkCheckpoint(scope: userScope, syncId: 1)],
    legacyPrincipalCheckpoint: const UplinkCheckpoint(
      scope: userScope,
      syncId: 1,
    ),
    rejections: [
      UplinkMutationRejection(
        mutationId: batch.records.keys.single,
        code: 'mutation.invalid',
      ),
    ],
  );

  Future<void> waitUntil(bool Function() condition) async {
    for (var attempt = 0; attempt < 200; attempt++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('status did not reach the expected phase');
  }

  Future<void> waitForSummary(
    List<UplinkSummaryPhase> seen,
    UplinkSummaryPhase phase,
  ) => waitUntil(() => seen.isNotEmpty && seen.last == phase);

  test('a page walks waiting -> sendable -> inFlight', () async {
    await writePage();
    final phases = status
        .watch('FamilyMoment', momentId)
        .map((update) => update.phase)
        .take(3)
        .toList();

    // Let the first emission land before anything changes.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await ledger.markReady(remoteObject('upload'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await freeze();

    // The moment carries no key of its own; it moves because its photo did.
    await expectLater(
      phases,
      completion([
        PendingMutationPhase.waiting,
        PendingMutationPhase.sendable,
        PendingMutationPhase.inFlight,
      ]),
    );
  });

  test(
    'explicit discard ends waiting without a transient terminal event',
    () async {
      await writePage();
      final updates = status.watch('FamilyPhoto', photoId).toList();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await ledger.markFailed(remoteObject('upload'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await outbox.discardFailed(clientId: clientId, ordinal: 1);

      // Terminal: the stream closes behind it, because the identity has no
      // queued work left to have a phase.
      await expectLater(
        updates.then((all) => all.map((update) => update.phase).toList()),
        completion([PendingMutationPhase.waiting]),
      );
    },
  );

  test('a sent row leaves without a terminal event', () async {
    final tagId = FamilyTagId(familyUuid(9));
    await writeTag(tagId);
    final updates = status.watch('FamilyTag', tagId).toList();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final batch = await freeze();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await reject(batch);

    // Sendable, then in flight, then gone — and no `dropped`, because the
    // outcome is already visible as canonical state.
    await expectLater(
      updates.then((all) => all.map((update) => update.phase).toList()),
      completion([
        PendingMutationPhase.sendable,
        PendingMutationPhase.inFlight,
      ]),
    );
  });

  test('the emitted type carries no protocol vocabulary', () async {
    await writePage();
    final update = await status.watch('FamilyPhoto', photoId).first;

    // Model name, identity, phase. No ordinal, no batch sequence, no key.
    expect(update.model, 'FamilyPhoto');
    expect(update.identity, photoId);
    expect(update.phase, PendingMutationPhase.waiting);
    expect(
      PendingMutationStatus(
        model: 'FamilyPhoto',
        identity: photoId,
        phase: PendingMutationPhase.waiting,
      ),
      update,
    );
  });

  test(
    'summary follows the complete queue lifecycle and returns idle',
    () async {
      final seen = <UplinkSummaryPhase>[];
      final subscription = status.watchSummary().listen(seen.add);
      addTearDown(subscription.cancel);

      await waitForSummary(seen, UplinkSummaryPhase.idle);
      await writePage();
      await waitForSummary(seen, UplinkSummaryPhase.waiting);
      await ledger.markReady(remoteObject('upload'));
      await waitForSummary(seen, UplinkSummaryPhase.sendable);
      final batch = await freeze();
      await waitForSummary(seen, UplinkSummaryPhase.inFlight);
      await reject(batch);
      await waitForSummary(seen, UplinkSummaryPhase.idle);

      expect(seen, [
        UplinkSummaryPhase.idle,
        UplinkSummaryPhase.waiting,
        UplinkSummaryPhase.sendable,
        UplinkSummaryPhase.inFlight,
        UplinkSummaryPhase.idle,
      ]);
    },
  );

  test('one summary subscription survives repeated queue cycles', () async {
    final seen = <UplinkSummaryPhase>[];
    final subscription = status.watchSummary().listen(seen.add);
    addTearDown(subscription.cancel);

    await waitForSummary(seen, UplinkSummaryPhase.idle);
    for (final suffix in [10, 11]) {
      await writeTag(FamilyTagId(familyUuid(suffix)));
      await waitForSummary(seen, UplinkSummaryPhase.sendable);
      final batch = await freeze();
      await waitForSummary(seen, UplinkSummaryPhase.inFlight);
      await reject(batch);
      await waitForSummary(seen, UplinkSummaryPhase.idle);
    }

    expect(seen, [
      UplinkSummaryPhase.idle,
      UplinkSummaryPhase.sendable,
      UplinkSummaryPhase.inFlight,
      UplinkSummaryPhase.idle,
      UplinkSummaryPhase.sendable,
      UplinkSummaryPhase.inFlight,
      UplinkSummaryPhase.idle,
    ]);
  });

  test('summary reports the most advanced coexisting phase', () async {
    final seen = <UplinkSummaryPhase>[];
    final subscription = status.watchSummary().listen(seen.add);
    addTearDown(subscription.cancel);

    await waitForSummary(seen, UplinkSummaryPhase.idle);
    await writePage();
    await waitForSummary(seen, UplinkSummaryPhase.waiting);
    await writeTag(FamilyTagId(familyUuid(12)));
    await waitForSummary(seen, UplinkSummaryPhase.sendable);
    final batch = await freeze();
    await waitForSummary(seen, UplinkSummaryPhase.inFlight);
    await reject(batch);
    await waitForSummary(seen, UplinkSummaryPhase.waiting);

    expect(seen, [
      UplinkSummaryPhase.idle,
      UplinkSummaryPhase.waiting,
      UplinkSummaryPhase.sendable,
      UplinkSummaryPhase.inFlight,
      UplinkSummaryPhase.waiting,
    ]);
  });
}
