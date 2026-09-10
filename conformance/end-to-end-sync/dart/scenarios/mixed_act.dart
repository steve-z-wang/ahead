import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// An act with a device-only companion, whole (CAP-488): one declared wire
/// slot, and a direct write made inside the same callback.
///
/// The wire carries the declared slot alone — the resolver's argument type has
/// no `note`, so a settled queue is itself the proof the companion stayed
/// home. What acceptance and refusal do to that row is the contract under
/// test: acceptance finalizes it, refusal takes it back.
const _clientId = 'f5a6b7c8-2930-4a4b-8c5d-6e7f80912a3b';
const _rejectedClientId = 'a6b7c8d9-3a4b-4c5d-8e6f-70819203b4c5';
const _noteId = '8b2c3d4e-5f60-4718-8293-a4b5c6d7e8f9';

/// The caption the host refuses — the same literal the resolvers know.
const _rejectedCaption = 'reject-me';

/// Acceptance: the synced slot lands on the server, and the local note stops
/// being provisional — present, and holding no before-image.
Future<Map<String, Object?>> runMixedAct(
  WireSession session,
) => _withClient(session, _clientId, (localSync) async {
  await _seed(localSync);

  await _captionWithNote(localSync, 'captioned');

  // One record, both operations in it — the companion rides the queue for
  // rollback's sake, never for the wire.
  final queued = <String, Object?>{
    'records': await _count(localSync, 'pending_mutations'),
    'operations': await _count(localSync, 'pending_mutation_operations'),
    'notes': await _count(localSync, 'model_local_note'),
  };

  await _settle(localSync);

  return {
    ...queued,
    'settledOperations': await _count(localSync, 'pending_mutation_operations'),
    'settledNotes': await _count(localSync, 'model_local_note'),
    // Sparsity holds for local twins too: nothing pending, nothing held.
    'settledNoteBefore': await _count(localSync, 'model_local_note_before'),
    'caption': await _caption(localSync),
  };
});

/// Refusal: the act rolls back whole — the local note included. The note was
/// born in this act, so its held truth is nonexistence, and rollback is the
/// row vanishing.
Future<Map<String, Object?>> runMixedActRejection(WireSession session) =>
    _withClient(session, _rejectedClientId, (localSync) async {
      await _seed(localSync);

      await _captionWithNote(localSync, _rejectedCaption);
      // The accepted neighbour, as in the named-mutation refusal journey: a
      // batch of nothing but refusals publishes no change, so this is what
      // gives the Downlink a page to settle the batch against.
      await localSync.transaction(
        (outerTx) => outerTx.mutate.renameSpace(
          (tx) async => (
            space: tx.space.update(
              (await tx.models.space.get(
                SpaceId(UUID.withValidation(conformanceSpaceId)),
              ))!,
              name: 'Renamed',
            ),
          ),
        ),
      );
      final optimisticNotes = await _count(localSync, 'model_local_note');

      await _settle(localSync);

      return {
        // Present while the act was in flight…
        'optimisticNotes': optimisticNotes,
        // …and taken back with it: a rejected act's device-local rows go too.
        'notes': await _count(localSync, 'model_local_note'),
        'noteBefore': await _count(localSync, 'model_local_note_before'),
        'caption': await _caption(localSync),
        'spaceName': (await localSync.models.space.get(
          SpaceId(UUID.withValidation(conformanceSpaceId)),
        ))?.name,
        'records': await _count(localSync, 'pending_mutations'),
        'operations': await _count(localSync, 'pending_mutation_operations'),
      };
    });

/// The direct-scope interleave: a direct transaction lands a FINAL edit on a row
/// a pending act is provisionally restyling as its companion. Final means
/// final — the direct write advances the held truth, so when the act is
/// refused the row rebuilds to the direct edit, not to the value the act
/// found (CAP-488).
const _directClientId = 'b7c8d9ea-4b5c-4d6e-8f70-819203b4c5d6';

Future<Map<String, Object?>> runMixedActDirectLane(WireSession session) =>
    _withClient(session, _directClientId, (localSync) async {
      await _seed(localSync);
      // The note exists in its own right — a `write`, final at commit.
      await localSync.transaction(
        (tx) => tx.models.localNote.create(
          id: UUID.withValidation(_noteId),
          text: 'kept',
          status: LocalNoteStatus.active,
        ),
      );

      // The doomed act pends a provisional restyle of that note as its
      // companion…
      await localSync.transaction(
        (outerTx) => outerTx.mutate.recaptionWithNote((tx) async {
          await tx.models.localNote.update(
            id: LocalNoteId(UUID.withValidation(_noteId)),
            text: 'provisional',
          );
          final moment = await tx.models.moment.get(
            MomentId(UUID.withValidation(conformanceMomentId)),
          );
          if (moment == null) return null;
          return (
            moment: tx.moment.update(
              moment,
              caption: FieldUpdate.set(_rejectedCaption),
            ),
          );
        }),
      );
      // …and a `write` lands THROUGH it, final.
      await localSync.transaction(
        (tx) => tx.models.localNote.update(
          id: LocalNoteId(UUID.withValidation(_noteId)),
          text: 'final',
        ),
      );
      // The accepted neighbour that gives the Downlink a page to settle
      // the refused batch against.
      await localSync.transaction(
        (outerTx) => outerTx.mutate.renameSpace(
          (tx) async => (
            space: tx.space.update(
              (await tx.models.space.get(
                SpaceId(UUID.withValidation(conformanceSpaceId)),
              ))!,
              name: 'Renamed',
            ),
          ),
        ),
      );

      await _settle(localSync);

      return {
        // The refusal took the provisional restyle — and ONLY it. The direct
        // edit was never the act's to take back.
        'noteText': (await localSync.models.localNote.get(
          LocalNoteId(UUID.withValidation(_noteId)),
        ))?.text,
        'noteBefore': await _count(localSync, 'model_local_note_before'),
        'caption': await _caption(localSync),
        'spaceName': (await localSync.models.space.get(
          SpaceId(UUID.withValidation(conformanceSpaceId)),
        ))?.name,
        'operations': await _count(localSync, 'pending_mutation_operations'),
      };
    });

/// One declared wire slot, and a device-only companion written through the
/// callback's own `tx` — the whole of what "mixed" means since CAP-488.
Future<void> _captionWithNote(LocalSync localSync, String caption) =>
    localSync.transaction(
      (outerTx) => outerTx.mutate.captionWithNote((tx) async {
        await tx.models.localNote.create(
          id: UUID.withValidation(_noteId),
          text: 'device-only',
          status: LocalNoteStatus.active,
        );
        final moment = await tx.models.moment.get(
          MomentId(UUID.withValidation(conformanceMomentId)),
        );
        if (moment == null) return null;
        return (
          moment: tx.moment.update(moment, caption: FieldUpdate.set(caption)),
        );
      }),
    );

Future<String?> _caption(LocalSync localSync) async =>
    (await localSync.models.moment.get(
      MomentId(UUID.withValidation(conformanceMomentId)),
    ))?.caption;

/// The owner, the book, and the page the act edits — accepted first, so the
/// mixed act is the only thing in flight.
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
          id: UUID.withValidation(conformanceMomentId),
          spaceId: UUID.withValidation(conformanceSpaceId),
          capturedAt: DateTime.parse(conformanceCapturedAt),
          caption: null,
        ),
      ),
    ),
  );
  await _settle(localSync);
}

Future<Map<String, Object?>> _withClient(
  WireSession session,
  String clientId,
  Future<Map<String, Object?>> Function(LocalSync localSync) run,
) async {
  final directory = await Directory.systemTemp.createTemp('local_sync_mixed_');
  final localSync = await LocalSync.open(
    driver: localSyncDatabaseDriver(
      path: '${directory.path}/local-sync.sqlite',
    ),
    clientId: clientId,
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
    await directory.delete(recursive: true);
  }
}

/// Waits until the client owes the server nothing.
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

Future<int> _count(LocalSync localSync, String table) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM "$table"',
  );
  return result.rows.single['count']! as int;
}
