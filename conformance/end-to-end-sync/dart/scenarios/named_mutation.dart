import 'dart:io';
import 'dart:convert';

import 'package:local_sync_database/local_sync_database.dart';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

/// One named act, whole, from `mutate` to settlement (CAP-439).
///
/// The page-shaped composite: one page, forty tags that travel with it, and
/// the star that keeps it — 42 operations the batch limit used to split, sent
/// as ONE record. Nothing here simulates anything: the generated runtime is
/// opened on its own database, the real Uplink worker sends the batch, the
/// real host runs one resolver in one savepoint, and the real Downlink worker
/// brings the whole thing back down.
const _clientId = 'c3d4e5f6-0718-492a-8b3c-4d5e6f708192';
const _rejectedClientId = 'd4e5f607-1829-4a3b-8c4d-5e6f70819203';
const _starTagPrefix = '7a1b2c3d-4e5f-4607-8819-';
const _sideEffectLinkId = 'e7c9a1b2-3d4e-4f50-8617-2839a4b5c6d7';

/// The label the host refuses, which dooms the act it belongs to.
const _rejectedTagLabel = 'reject-me';

/// The whole act succeeds: 42 rows readable at once, one queue record, one
/// resolver run, and a server-only row on the way back.
Future<Map<String, Object?>> runNamedMutation(
  WireSession session,
) => _withClient(session, _clientId, (localSync, prerequisites) async {
  await _seed(localSync);

  final beforeReady = <String, Object?>{};
  await localSync.transaction(
    (outerTx) => outerTx.mutate.captureMoment(
      (tx) async => _capturePage(tagLabels: _labels(40)),
    ),
  );

  // Everything the act wrote is readable at once, before anything is sent.
  beforeReady['moments'] = await _count(localSync, 'model_moment');
  beforeReady['tags'] = await _count(localSync, 'model_star_tag');
  beforeReady['stars'] = await _count(localSync, 'model_star');
  beforeReady['records'] = await _count(localSync, 'pending_mutations');
  beforeReady['operations'] = await _count(
    localSync,
    'pending_mutation_operations',
  );

  // Readiness holds the act until EVERY key is ready: one pending tag is
  // enough to keep 42 operations at home.
  for (var index = 0; index < 39; index += 1) {
    prerequisites.complete('tag-$index', PrerequisiteAttemptResult.ready);
  }
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final heldRecords = await _count(localSync, 'pending_mutations');
  prerequisites.complete('tag-39', PrerequisiteAttemptResult.ready);

  await _settle(localSync);

  return {
    ...beforeReady,
    'heldRecords': heldRecords,
    'settledRecords': await _count(localSync, 'pending_mutations'),
    'settledOperations': await _count(localSync, 'pending_mutation_operations'),
    'uplinkBatches': await _count(localSync, 'uplink_batches'),
    // The act's rows survived settlement, and no twin was left holding a
    // before-image for a row nothing is pending on.
    'moments': await _count(localSync, 'model_moment'),
    'tags': await _count(localSync, 'model_star_tag'),
    'stars': await _count(localSync, 'model_star'),
    'momentBefore': await _count(localSync, 'model_moment_before'),
    'tagBefore': await _count(localSync, 'model_star_tag_before'),
    // A flat Downlink pull brought back a row no operation named.
    'sideEffectLinks': await _count(localSync, 'model_moment_link'),
    'sideEffectLinkId': await _sideEffectLink(localSync),
  };
});

/// The refusal variant: the host refuses the act, the whole of it rolls back
/// on both sides, and an unrelated act in the same batch is untouched.
Future<Map<String, Object?>> runNamedMutationRejection(WireSession session) =>
    _withClient(session, _rejectedClientId, seedThenRestartInactive: true, (
      localSync,
      prerequisites,
    ) async {
      // One doomed act, and one the host has no quarrel with.
      await localSync.transaction(
        (outerTx) => outerTx.mutate.captureMoment(
          (tx) async =>
              _capturePage(caption: _rejectedTagLabel, tagLabels: const []),
        ),
      );
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
      // Start only after both acts are queued: this scenario proves
      // positional refusal inside ONE batch, not settlement of an all-refused
      // receipt with no new Downlink row.
      await startLocalSync(localSync);

      await _settle(localSync);

      return {
        // The refused act rolled back whole: not one of its rows survives.
        'moments': await _count(localSync, 'model_moment'),
        'tags': await _count(localSync, 'model_star_tag'),
        'stars': await _count(localSync, 'model_star'),
        // Its neighbour in the same batch was never in question.
        'spaceName': (await localSync.models.space.get(
          SpaceId(UUID.withValidation(conformanceSpaceId)),
        ))?.name,
        // And nothing of the refusal is left behind.
        'records': await _count(localSync, 'pending_mutations'),
        'operations': await _count(localSync, 'pending_mutation_operations'),
        'uplinkBatches': await _count(localSync, 'uplink_batches'),
      };
    });

/// A response is lost after the server commits a mixed-version frozen batch.
/// Reopening must resend the retained spelling and settle through Downlink.
Future<Map<String, Object?>> runMutationVersionRestart(
  WireSession session,
) async {
  const clientId = 'c7280000-0000-4000-8000-000000000001';
  final directory = await Directory.systemTemp.createTemp('mutation_versions_');
  final path = '${directory.path}/local.sqlite';
  final prerequisites = ControlledPrerequisites();
  var local = await _openClient(
    session,
    clientId,
    path,
    activate: true,
    prerequisites: prerequisites,
  );
  var open = true;
  try {
    await _seed(local);
    await local.close();
    open = false;
    local = await _openClient(
      session,
      clientId,
      path,
      activate: false,
      prerequisites: prerequisites,
    );
    open = true;
    for (final name in ['old queued name', 'new queued name']) {
      await local.transaction(
        (outer) => outer.mutate.renameSpace(
          (mutation) async => (
            space: mutation.space.update(
              (await mutation.models.space.get(
                SpaceId(UUID.withValidation(conformanceSpaceId)),
              ))!,
              name: name,
            ),
          ),
        ),
      );
    }
    await local.close();
    open = false;
    final db = await localSyncDatabaseDriver(path: path).open();
    final scope = LocalDatabaseScope(db);
    final registry = buildModelRegistry(scope);
    final queue = MutationQueue(scope, registry: registry);
    // Reproduce a record left by the pre-versioning client alongside a new v2.
    await db.execute(
      DatabaseStatement(
        sql:
            'UPDATE pending_mutations SET version = NULL '
            'WHERE ordinal = (SELECT MIN(ordinal) FROM pending_mutations)',
      ),
    );
    final snapshot = await queue.snapshot();
    final batch = await queue.freeze(
      expectedSequence: snapshot.nextBatchSequence,
      mutationOrdinals: [
        for (final act in snapshot.mutations) act.mutation.ordinal,
      ],
    );
    final codec = LocalSyncJsonCodec(registry: registry);
    final bytes = codec.encodeUplinkRequest(
      clientId: clientId,
      batchSequence: batch.batchSequence,
      mutations: batch.mutations,
      records: batch.records,
    );
    final transport = RestWsTransport(
      baseUri: Uri.parse('http://127.0.0.1:${session.port}/'),
      getAccessToken: () async => conformanceToken,
    );
    final answer = await transport.sendUplink(bytes);
    if (answer.statusCode != 200)
      throw StateError('first send failed: ${answer.statusCode}');
    final receipt =
        jsonDecode(utf8.decode(localSyncResponseBody(answer))) as Map;
    await transport.close();
    // Deliberately never record the successful response in SQLite.
    await db.close();
    local = await _openClient(
      session,
      clientId,
      path,
      activate: true,
      prerequisites: prerequisites,
    );
    open = true;
    await _settle(local);
    return {
      'versions': [
        for (final act
            in (jsonDecode(utf8.decode(bytes)) as Map)['mutations'] as List)
          act['version'],
      ],
      'name': (await local.models.space.get(
        SpaceId(UUID.withValidation(conformanceSpaceId)),
      ))!.name,
      'records': await _count(local, 'pending_mutations'),
      'batches': await _count(local, 'uplink_batches'),
      'beforeImages': await _count(local, 'model_space_before'),
      'rejections': receipt['rejections'],
    };
  } finally {
    if (open) await local.close();
    await directory.delete(recursive: true);
  }
}

CaptureMomentResult _capturePage({
  required List<String> tagLabels,
  String caption = 'a page',
}) => (
  moment: Moment.create(
    id: UUID.withValidation(conformanceMomentId),
    spaceId: UUID.withValidation(conformanceSpaceId),
    capturedAt: DateTime.parse(conformanceCapturedAt),
    caption: caption,
  ),
  tags: [
    for (var index = 0; index < tagLabels.length; index += 1)
      StarTag.create(
        id: UUID.withValidation(
          '$_starTagPrefix${index.toString().padLeft(12, '0')}',
        ),
        userId: UUID.withValidation(conformanceUserId),
        momentId: UUID.withValidation(conformanceMomentId),
        label: tagLabels[index],
      ),
  ],
  star: Star.create(
    userId: UUID.withValidation(conformanceUserId),
    momentId: UUID.withValidation(conformanceMomentId),
  ),
);

List<String> _labels(int count) => [
  for (var index = 0; index < count; index += 1) 'tag-$index',
];

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

Future<Map<String, Object?>> _withClient(
  WireSession session,
  String clientId,
  Future<Map<String, Object?>> Function(
    LocalSync localSync,
    ControlledPrerequisites prerequisites,
  )
  run, {
  bool seedThenRestartInactive = false,
}) async {
  final directory = await Directory.systemTemp.createTemp('local_sync_named_');
  final path = '${directory.path}/local-sync.sqlite';
  final prerequisites = ControlledPrerequisites();
  var localSync = await _openClient(
    session,
    clientId,
    path,
    activate: true,
    prerequisites: prerequisites,
  );
  var isOpen = true;
  try {
    if (seedThenRestartInactive) {
      await _seed(localSync);
      await localSync.close();
      isOpen = false;
      localSync = await _openClient(
        session,
        clientId,
        path,
        activate: false,
        prerequisites: prerequisites,
      );
      isOpen = true;
    }
    return await run(localSync, prerequisites);
  } finally {
    if (isOpen) await localSync.close();
    await directory.delete(recursive: true);
  }
}

Future<LocalSync> _openClient(
  WireSession session,
  String clientId,
  String path, {
  required bool activate,
  required ControlledPrerequisites prerequisites,
}) async {
  final localSync = await LocalSync.open(
    driver: localSyncDatabaseDriver(path: path),
    clientId: clientId,
    transport: RestWsTransport(
      baseUri: Uri.parse('http://127.0.0.1:${session.port}/'),
      getAccessToken: () async => conformanceToken,
      sleep: (_) async {},
    ),
    prerequisites: prerequisites.handlers,
    failureObserver: (failure) => stderr.writeln(
      'LocalSync failure: ${failure.error} ${failure.stackTrace}',
    ),
  );
  if (activate) await startLocalSync(localSync);
  return localSync;
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
  final parents = await localSync.readOnlySql.query(
    'SELECT * FROM pending_mutations',
  );
  final batches = await localSync.readOnlySql.query(
    'SELECT * FROM uplink_batches',
  );
  final cursors = await localSync.readOnlySql.query(
    'SELECT * FROM downlink_scope_state',
  );
  throw StateError(
    'the Uplink queue never settled: parents=${parents.rows.map((r) => [r["name"], r["version"], r["batch_sequence"]]).toList()} batches=${batches.rows.map((r) => [r["sequence"], r["required_sync_id"]]).toList()} cursors=${cursors.rows.map((r) => [r["scope"], r["last_applied_sync_id"]]).toList()}',
  );
}

/// The row the host wrote on its own, read back by the identity it chose.
Future<String?> _sideEffectLink(LocalSync localSync) async {
  final result = await localSync.readOnlySql.query(
    'SELECT id FROM "model_moment_link" WHERE id = ?',
    [_sideEffectLinkId],
  );
  return result.rows.singleOrNull?['id'] as String?;
}

Future<int> _count(LocalSync localSync, String table) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM "$table"',
  );
  return result.rows.single['count']! as int;
}
