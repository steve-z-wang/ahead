import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// Synchronization is a write-path choice (CAP-488), proved on ONE Model.
///
/// The same `LocalNote` is written both ways in one run: a direct transaction
/// edit commits it to this device and nothing becomes sendable, then
/// `tx.mutate.publishNote` sends an ordinary act naming that same row. Nothing
/// about the Model decided either — the call site did.
const _clientId = 'c8d9ea0b-5c6d-4e7f-8091-2a3b4c5d6e7f';
const _noteId = '9c3d4e5f-6071-4829-83a4-b5c6d7e8f901';
const _publishedNoteId = 'ad4e5f60-7182-493a-84b5-c6d7e8f90123';

Future<Map<String, Object?>> runWritePath(WireSession session) => _withClient(
  session,
  (localSync) async {
    await _seed(localSync);

    // Device-only: the row exists, and the Uplink has nothing to send.
    await localSync.transaction(
      (tx) => tx.models.localNote.create(
        id: UUID.withValidation(_noteId),
        text: 'device only',
        status: LocalNoteStatus.active,
      ),
    );
    final afterWrite = <String, Object?>{
      'writtenText': await _noteText(localSync, _noteId),
      'writeRecords': await _count(localSync, 'pending_mutations'),
      'writeOperations': await _count(localSync, 'pending_mutation_operations'),
      'writeBatches': await _count(localSync, 'uplink_batches'),
    };

    // The same Model, now as a declared act: it queues, it ships, it
    // settles. Nothing in the Model said it could not.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.publishNote(
        (tx) async => (
          note: LocalNote.create(
            id: UUID.withValidation(_publishedNoteId),
            text: 'shared',
            status: LocalNoteStatus.active,
          ),
        ),
      ),
    );
    final queuedOperations = await _count(
      localSync,
      'pending_mutation_operations',
    );
    await _settle(localSync);

    // A callback that reads its own rows and proves the act already
    // happened returns null: a deliberate atomic no-op, leaving no record,
    // no companion and no request behind it.
    await localSync.transaction(
      (outerTx) => outerTx.mutate.publishNote((tx) async {
        final already = await tx.models.localNote.get(
          LocalNoteId(UUID.withValidation(_publishedNoteId)),
        );
        if (already != null) return null;
        return (
          note: LocalNote.create(
            id: UUID.withValidation(_publishedNoteId),
            text: 'never',
            status: LocalNoteStatus.active,
          ),
        );
      }),
    );

    return {
      ...afterWrite,
      'queuedOperations': queuedOperations,
      'publishedText': await _noteText(localSync, _publishedNoteId),
      // The device-only row is untouched by any of it.
      'writtenTextAfterPublish': await _noteText(localSync, _noteId),
      // The no-op left no record, no operation, and no batch behind it.
      'records': await _count(localSync, 'pending_mutations'),
      'operations': await _count(localSync, 'pending_mutation_operations'),
    };
  },
);

Future<String?> _noteText(LocalSync localSync, String id) async =>
    (await localSync.models.localNote.get(
      LocalNoteId(UUID.withValidation(id)),
    ))?.text;

Future<void> _seed(LocalSync localSync) async {
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
  await _settle(localSync);
}

Future<int> _count(LocalSync localSync, String table) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM "$table"',
  );
  return result.rows.single['count']! as int;
}

Future<void> _settle(LocalSync localSync) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final operations = await _count(localSync, 'pending_mutation_operations');
    final batches = await _count(localSync, 'uplink_batches');
    if (operations == 0 && batches == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('the Uplink queue never settled');
}

Future<Map<String, Object?>> _withClient(
  WireSession session,
  Future<Map<String, Object?>> Function(LocalSync localSync) run,
) async {
  final directory = await Directory.systemTemp.createTemp('local_sync_write_');
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
    return await run(localSync);
  } finally {
    await localSync.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
