import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// The whole optimistic loop, with a real refusal in the middle of it: the
/// user's edit shows at once, the host says no, and the row the user is
/// looking at goes back to what the server holds.
///
/// Nothing here simulates settlement. The generated runtime is opened on its
/// own database, the real Uplink worker sends the batch, the real host refuses
/// one mutation of it positionally, and the real Downlink worker catches up —
/// so what this proves is the loop, not simulated Queue settlement.
///
/// The batch carries a second edit the host is happy with, which is what makes
/// "no stranded batch" observable: a refusal alone moves the server's head
/// nowhere, and a client already standing at the head has nothing to catch up
/// on.
const _clientId = 'b2c3d4e5-f607-4819-9a2b-3c4d5e6f7081';
const _neighbourMomentId = 'd1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6';

Future<Map<String, Object?>> runRejectionRebuild(WireSession session) async {
  final directory = await Directory.systemTemp.createTemp(
    'local_sync_rejection_',
  );
  final localSync = await LocalSync.open(
    driver: localSyncDatabaseDriver(
      path: '${directory.path}/local-sync.sqlite',
    ),
    clientId: _clientId,
    transport: RestWsTransport(
      baseUri: Uri.parse('http://127.0.0.1:${session.port}/'),
      getAccessToken: () async => conformanceToken,
      sleep: (_) async {},
    ),
    prerequisites: readyPrerequisites(),
  );
  await startLocalSync(localSync);
  try {
    final momentId = momentIdOf(conformanceMomentId);
    final neighbourId = momentIdOf(_neighbourMomentId);

    // Server truth first: written here, accepted there, and back down as a
    // page — so the row the refusal will disturb is one the server holds.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (
          user: User.create(
            id: UUID.withValidation(conformanceUserId),
            handle: 'steve',
          ),
        ),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: UUID.withValidation(conformanceSpaceId),
            ownerId: UUID.withValidation(conformanceUserId),
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.writeMoment(
        (tx) async => (
          moment: Moment.create(
            id: momentId.value,
            spaceId: UUID.withValidation(conformanceSpaceId),
            capturedAt: DateTime.parse(conformanceCapturedAt),
            caption: 'first',
          ),
        ),
      ),
    );
    await _settle(localSync);
    final seededCursor = await _cursor(localSync);

    // One batch, two acts: the caption the host refuses by name, and a
    // neighbour it has no quarrel with.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.reviseMoment((tx) async {
        final moment = await tx.models.moment.get(momentId);
        if (moment == null) return null;
        return (
          moment: tx.moment.update(
            moment,
            caption: const FieldUpdate.set(rejectedCaption),
          ),
          removedTags: const <StarTagDelete>[],
          addedTags: const <StarTagCreate>[],
          star: null,
        );
      }),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.writeMoment(
        (tx) async => (
          moment: Moment.create(
            id: neighbourId.value,
            spaceId: UUID.withValidation(conformanceSpaceId),
            capturedAt: DateTime.parse(conformanceCapturedAt),
            caption: 'kept',
          ),
        ),
      ),
    );
    await _settle(localSync);

    return {
      'caption': (await localSync.models.moment.get(momentId))?.caption,
      'neighbourCaption': (await localSync.models.moment.get(
        neighbourId,
      ))?.caption,
      'pendingMutations': await _count(
        localSync,
        'pending_mutation_operations',
      ),
      'uplinkBatches': await _count(localSync, 'uplink_batches'),
      'seededCursor': seededCursor,
      'cursor': await _cursor(localSync),
    };
  } finally {
    await localSync.close();
    await directory.delete(recursive: true);
  }
}

/// Waits until the client owes the server nothing: no queued mutation, and no
/// batch waiting on a sync ID it has not reached.
///
/// Bounded, and polled rather than driven — the workers are the real ones, and
/// telling them when to run would be the simulation this journey exists to
/// avoid.
Future<void> _settle(LocalSync localSync) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final mutations = await _count(localSync, 'pending_mutation_operations');
    final batches = await _count(localSync, 'uplink_batches');
    if (mutations == 0 && batches == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('the Uplink queue never settled');
}

Future<int> _count(LocalSync localSync, String table) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM "$table"',
  );
  return result.rows.single['count']! as int;
}

Future<int> _cursor(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT last_applied_sync_id FROM downlink_scope_state '
    'WHERE scope = ?',
    [conformanceUserScope],
  );
  return result.rows.single['last_applied_sync_id']! as int;
}
