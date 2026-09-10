import 'dart:convert';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/generated/composition.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';
import 'package:local_sync_database/local_sync_database.dart';

/// What every end-to-end journey needs and no single one of them owns: the
/// families the host will publish, the generated typed readers over the
/// client's own database, and the two local facts a journey ends by reading —
/// the Model row and the cursor saying how far the client has applied.
///
/// End-to-end only, deliberately. A helper moves up into the shared harness
/// when a SECOND contract needs it, and none of this is another contract's
/// business: the protocol suite stops at the envelope and never opens a
/// database at all.

const conformanceMomentId = '550e8400-e29b-41d4-a716-446655440000';
const conformanceCapturedAt = '2026-08-05T00:00:00.000Z';

/// The caption the host fixture refuses by name, on a create and on an update
/// alike (`src/support/model-bindings.ts`). A deterministic refusal is the
/// only kind a journey can wait on.
const rejectedCaption = 'reject-me';

/// The family the CAP-428 baseline lands, chosen for the three field shapes a
/// page can spell wrong: an enum (`Space.kind`), a list (`spaceOrder`), and a
/// nullable field actually holding null (`inboxSeenAt`). AccountState hangs off
/// User, so its owner rides along.
List<StoredMutationOperation> accountStateFamily() => [
  conformanceUserRow(),
  conformanceSpaceRow(),
  StoredMutationOperation(
    mutationOrdinal: 3,
    position: 0,
    model: 'AccountState',
    identityJson: jsonEncode({'userId': conformanceUserId}),
    operation: 'create',
    valuesJson: jsonEncode({
      'spaceOrder': [conformanceSpaceId],
      'inboxSeenAt': null,
    }),
    isUplink: true,
  ),
];

/// A Moment lives under a Space, which lives under a User, and the local store
/// enforces both — so a journey about one page still sends three rows.
List<StoredMutationOperation> momentFamily({String caption = 'first'}) => [
  conformanceUserRow(),
  conformanceSpaceRow(),
  momentCreate(3, caption: caption),
];

StoredMutationOperation momentCreate(
  int ordinal, {
  String id = conformanceMomentId,
  String? caption = 'first',
}) => StoredMutationOperation(
  mutationOrdinal: ordinal,
  position: 0,
  model: 'Moment',
  identityJson: jsonEncode({'id': id}),
  operation: 'create',
  valuesJson: jsonEncode({
    'caption': caption,
    'capturedAt': conformanceCapturedAt,
    'spaceId': conformanceSpaceId,
  }),
  isUplink: true,
);

StoredMutationOperation momentUpdate(
  int ordinal, {
  String id = conformanceMomentId,
  required Map<String, Object?> values,
}) => StoredMutationOperation(
  mutationOrdinal: ordinal,
  position: 0,
  model: 'Moment',
  identityJson: jsonEncode({'id': id}),
  operation: 'update',
  valuesJson: jsonEncode(values),
  isUplink: true,
);

StoredMutationOperation momentDelete(
  int ordinal, {
  String id = conformanceMomentId,
}) => StoredMutationOperation(
  mutationOrdinal: ordinal,
  position: 0,
  model: 'Moment',
  identityJson: jsonEncode({'id': id}),
  operation: 'delete',
  valuesJson: jsonEncode(<String, Object?>{}),
  isUplink: true,
);

/// The generated typed readers, over the same database the page lands in.
/// A journey that asserts through these is asserting what the app would see.
Models typedModels(LocalDatabaseScope scope) =>
    buildModels(buildModelRuntimes(scope, registry: buildModelRegistry(scope)));

MomentId momentIdOf(String value) => MomentId(UUID.withValidation(value));

/// The real apply path: the strict Model decoder, the store the app runs, and
/// the client's own SQLite underneath.
DownlinkPageProcessor downlinkProcessor(LocalDatabaseScope scope) {
  final registry = buildModelRegistry(scope);
  return DownlinkPageProcessor(
    database: scope,
    registry: registry,
    decoder: ModelChangeDecoder(registry),
  );
}

Future<void> initializeJourneyScopes(LocalDatabaseScope scope) =>
    scope.transaction((_) async {
      final store = ScopeStore(scope);
      for (final desiredScope in [
        conformanceUserScope,
        conformanceSpaceScope,
        conformanceBookAScope,
        conformanceBookBScope,
      ]) {
        await store.assignDirect(desiredScope, true);
      }
    });

Future<void> startLocalSync(
  LocalSync localSync, [
  Iterable<String> scopes = const [conformanceUserScope],
]) async {
  await localSync.transaction((tx) async {
    for (final scope in scopes) {
      await tx.scopes.set(scope);
    }
  });
  await localSync.start();
}

Future<DownlinkApplyResult> applyPage(
  LocalDatabaseScope scope,
  DownlinkPage page, {
  required int afterSyncId,
}) => downlinkProcessor(scope).apply(page, afterSyncId: afterSyncId);

/// How far the client has applied, read out of its own durable state.
Future<int> readCursor(LocalDatabaseScope scope, {String? forScope}) async =>
    downlinkProcessor(
      scope,
    ).readLastAppliedSyncId(forScope ?? conformanceUserScope);

Future<int> countRows(LocalDatabaseScope scope, String table) async {
  final result = await scope.current.query(
    DatabaseQuery(sql: 'SELECT COUNT(*) AS count FROM "$table"'),
  );
  return result.rows.single['count']! as int;
}

/// Freezes the runnable mutations exactly as the production Controller does.
Future<UplinkBatch> freezeRunnable(MutationQueue queue) async {
  final snapshot = await queue.snapshot();
  final selected = const MutationScheduler(
    maxBytes: maximumUplinkBatchBytes,
  ).select(snapshot, encodedBytes: (_) => 1);
  if (selected.isEmpty) throw StateError('no runnable mutation');
  return queue.freeze(
    expectedSequence: snapshot.nextBatchSequence,
    mutationOrdinals: selected,
  );
}

Set<int> requestMutationIds(UplinkBatch batch) => {
  for (final record in batch.records.values)
    record.legacyWireOrdinal ?? record.ordinal,
};
