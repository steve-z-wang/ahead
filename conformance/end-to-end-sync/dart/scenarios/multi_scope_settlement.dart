import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/generated/composition.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// One optimistic batch is published into three ledgers. Advancing Book A and
/// User first must retain the whole batch; Book B is the final checkpoint and
/// settles all three acts together.
Future<Map<String, Object?>> runMultiScopeSettlement(
  WireSession session,
) async {
  await session.settle(1, momentFamily());
  final initialUserPage = await session.pull(0);
  await applyPage(session.scope, initialUserPage, afterSyncId: 0);
  final initialUserCursor = await readCursor(session.scope);

  final registry = buildModelRegistry(session.scope);
  final runtimes = buildModelRuntimes(session.scope, registry: registry);
  final transactions =
      TransactionExecutor<TransactionModels, TransactionMutations>(
        database: session.scope,
        contexts: buildTransactionContexts(session.scope, registry, runtimes),
      );
  await transactions.run((tx) async {
    await tx.mutate.renameSpace((mutation) async {
      final space = await mutation.models.space.get(
        SpaceId(UUID.withValidation(conformanceSpaceId)),
      );
      if (space == null) throw StateError('seeded Space did not materialize');
      return (space: mutation.space.update(space, name: 'Three ledgers'));
    });
    await tx.mutate.writeMoment(
      (mutation) async => (
        moment: Moment.create(
          id: UUID.withValidation(conformanceBookAMomentId),
          spaceId: UUID.withValidation(conformanceSpaceId),
          capturedAt: DateTime.parse(conformanceCapturedAt),
          caption: 'Book A',
        ),
      ),
    );
    await tx.mutate.publishNote(
      (mutation) async => (
        note: LocalNote.create(
          id: UUID.withValidation(conformanceBookBNoteId),
          text: 'Book B',
          status: LocalNoteStatus.active,
        ),
      ),
    );
  });

  final queue = MutationQueue(session.scope, registry: registry);
  final batch = await freezeRunnable(queue);
  final sent = await session.transport.sendUplink(
    session.codec.encodeUplinkRequest(
      clientId: batch.clientId,
      batchSequence: 2,
      mutations: batch.mutations,
      records: batch.records,
    ),
  );
  final decoded = session.codec.decodeUplinkResponse(
    localSyncResponseBody(sent),
    requestMutationIds: requestMutationIds(batch),
  );
  await queue.record(
    BatchExecutionResult(
      batchSequence: batch.batchSequence,
      requiredCheckpoints: decoded.requiredCheckpoints,
      legacyPrincipalCheckpoint: decoded.legacyPrincipalCheckpoint,
      rejections: decoded.rejections,
    ),
  );

  final bookAPage = await session.pull(0, scope: conformanceBookAScope);
  await applyPage(session.scope, bookAPage, afterSyncId: 0);
  final batchesAfterBookA = await countRows(session.scope, 'uplink_batches');

  final userPage = await session.pull(initialUserCursor);
  await applyPage(session.scope, userPage, afterSyncId: initialUserCursor);
  final batchesAfterUser = await countRows(session.scope, 'uplink_batches');

  final bookBPage = await session.pull(0, scope: conformanceBookBScope);
  await applyPage(session.scope, bookBPage, afterSyncId: 0);

  return {
    'checkpoints': [
      for (final checkpoint in decoded.requiredCheckpoints)
        '${checkpoint.scope}:${checkpoint.syncId}',
    ],
    'batchesAfterBookA': batchesAfterBookA,
    'batchesAfterUser': batchesAfterUser,
    'batchesAfterBookB': await countRows(session.scope, 'uplink_batches'),
    'operationsAfterBookB': await countRows(
      session.scope,
      'pending_mutation_operations',
    ),
  };
}
