import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// Slot bindings at the write boundary (spec 2026-08-16-slot-bindings): the
/// act's declared wiring is a CHECK — a bound row naming a different parent
/// than the act carries dies inside `mutate()`, before anything is written or
/// queued, and the session is left healthy enough that the corrected act
/// lands end to end.
///
/// The happy path needs no journey of its own: `CaptureMoment` is a bound act
/// since the wiring was declared, so every capture the named-mutation journey
/// sends already crosses both checks — the client's verifier and the server's
/// create precheck.
const _clientId = 'c8d9eafb-5c6d-4e7f-8081-9203b4c5d6e7';

/// A moment id the act does NOT carry — what the stray star names.
const _strayMomentId = '9c3d4e5f-6071-4829-93a4-b5c6d7e8f901';

Future<Map<String, Object?>> runSlotBindingMismatch(WireSession session) =>
    _withClient(session, _clientId, (localSync) async {
      await _seed(localSync);

      Object? refused;
      try {
        await localSync.transaction(
          (outerTx) => outerTx.mutate.captureMoment(
            (tx) async => _capture(starOn: _strayMomentId),
          ),
        );
      } on ArgumentError catch (error) {
        refused = error;
      }

      // The throw is the whole story: no record, no operations, no rows.
      final afterThrow = <String, Object?>{
        'refused': refused != null,
        'records': await _count(localSync, 'pending_mutations'),
        'operations': await _count(localSync, 'pending_mutation_operations'),
        'moments': await _count(localSync, 'model_moment'),
        'stars': await _count(localSync, 'model_star'),
      };

      // The corrected act crosses both checks and lands. Its prerequisite is
      // actively ensured by the Engine-owned handler.
      await localSync.transaction(
        (outerTx) => outerTx.mutate.captureMoment(
          (tx) async => _capture(starOn: conformanceMomentId),
        ),
      );
      await _settle(localSync);

      return {
        ...afterThrow,
        'settledMoments': await _count(localSync, 'model_moment'),
        'settledStars': await _count(localSync, 'model_star'),
        'settledTags': await _count(localSync, 'model_star_tag'),
      };
    });

/// The bound act: the star and the tag both name [starOn] as their moment —
/// consistent when it is the act's own page, a binding violation when not.
CaptureMomentResult _capture({required String starOn}) => (
  moment: Moment.create(
    id: UUID.withValidation(conformanceMomentId),
    spaceId: UUID.withValidation(conformanceSpaceId),
    capturedAt: DateTime.parse(conformanceCapturedAt),
    caption: 'a page',
  ),
  star: Star.create(
    userId: UUID.withValidation(conformanceUserId),
    momentId: UUID.withValidation(starOn),
  ),
  tags: [
    StarTag.create(
      id: UUID.withValidation('7d4e5f60-7182-4930-84b5-c6d7e8f90a1b'),
      userId: UUID.withValidation(conformanceUserId),
      momentId: UUID.withValidation(starOn),
      label: 'kept',
    ),
  ],
);

Future<Map<String, Object?>> _withClient(
  WireSession session,
  String clientId,
  Future<Map<String, Object?>> Function(LocalSync localSync) run,
) async {
  final directory = await Directory.systemTemp.createTemp('local_sync_bind_');
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

/// The owner and the book the page needs, accepted by the host first, so the
/// act under test is the only thing in flight.
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
  await _settle(localSync);
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
