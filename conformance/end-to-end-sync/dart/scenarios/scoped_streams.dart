import 'dart:convert';
import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_conformance/src/generated/composition.dart';
import 'package:local_sync_conformance/src/support/rest_ws_conformance.dart';
import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'support.dart';

const _sampleId = '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d';
const _runtimeClientId = '6e7f8091-a2b3-4c5d-8e6f-708192a3b4c5';

/// The generated composition root opens both scopes over one real live
/// transport, catches each up through its worker, then carries a User-scoped
/// act through Uplink and back down to settlement.
Future<Map<String, Object?>> runScopedRuntime(WireSession session) async {
  await session.settle(1, momentFamily());
  await session.settle(2, [_sample('create', rank: 42)]);

  final directory = await Directory.systemTemp.createTemp(
    'local_sync_scoped_runtime_',
  );
  final localSync = await LocalSync.open(
    driver: localSyncDatabaseDriver(
      path: '${directory.path}/local-sync.sqlite',
    ),
    clientId: _runtimeClientId,
    transport: RestWsTransport(
      baseUri: Uri.parse('http://127.0.0.1:${session.port}/'),
      getAccessToken: () async => conformanceToken,
      sleep: (_) async {},
    ),
    prerequisites: readyPrerequisites(),
  );
  await startLocalSync(localSync, [
    conformanceUserScope,
    conformanceSpaceScope,
  ]);
  try {
    await _waitFor(localSync, () async {
      final userCursor = await _runtimeCursor(localSync, conformanceUserScope);
      final spaceCursor = await _runtimeCursor(
        localSync,
        conformanceSpaceScope,
      );
      final space = await localSync.models.space.get(
        SpaceId(UUID.withValidation(conformanceSpaceId)),
      );
      final sample = await localSync.models.scalarSample.get(
        ScalarSampleId(UUID.withValidation(_sampleId)),
      );
      return userCursor == 3 &&
          spaceCursor == 1 &&
          space != null &&
          sample?.rank == 42;
    });

    final initialUserCursor = await _runtimeCursor(
      localSync,
      conformanceUserScope,
    );
    final initialSpaceCursor = await _runtimeCursor(
      localSync,
      conformanceSpaceScope,
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.renameSpace((tx) async {
        final space = await tx.models.space.get(
          SpaceId(UUID.withValidation(conformanceSpaceId)),
        );
        if (space == null) throw StateError('seeded Space did not arrive');
        return (space: tx.space.update(space, name: 'Runtime Renamed'));
      }),
    );
    await _waitFor(
      localSync,
      () async =>
          await _runtimeCount(localSync, 'pending_mutation_operations') == 0 &&
          await _runtimeCount(localSync, 'uplink_batches') == 0 &&
          (await localSync.models.space.get(
                SpaceId(UUID.withValidation(conformanceSpaceId)),
              ))?.name ==
              'Runtime Renamed',
    );

    return {
      'initialUserCursor': initialUserCursor,
      'initialSpaceCursor': initialSpaceCursor,
      'finalUserCursor': await _runtimeCursor(localSync, conformanceUserScope),
      'finalSpaceCursor': await _runtimeCursor(
        localSync,
        conformanceSpaceScope,
      ),
      'spaceName': (await localSync.models.space.get(
        SpaceId(UUID.withValidation(conformanceSpaceId)),
      ))?.name,
      'sampleRank': (await localSync.models.scalarSample.get(
        ScalarSampleId(UUID.withValidation(_sampleId)),
      ))?.rank,
      'pendingOperations': await _runtimeCount(
        localSync,
        'pending_mutation_operations',
      ),
      'batches': await _runtimeCount(localSync, 'uplink_batches'),
    };
  } finally {
    await localSync.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Two authorized ledgers reach one SQLite database without sharing a cursor.
/// The final act is accepted against the User ledger; advancing the Space
/// ledger first must leave that act pending until the User page arrives.
Future<Map<String, Object?>> runScopedStreams(WireSession session) async {
  await session.settle(1, momentFamily());
  await session.settle(2, [_sample('create', rank: 42)]);

  final initialUserPage = await session.pull(0);
  final initialSpacePage = await session.pull(0, scope: conformanceSpaceScope);
  final userApplied = await applyPage(
    session.scope,
    initialUserPage,
    afterSyncId: 0,
  );
  final spaceApplied = await applyPage(
    session.scope,
    initialSpacePage,
    afterSyncId: 0,
  );
  final initialUserCursor = await readCursor(session.scope);
  final initialSpaceCursor = await readCursor(
    session.scope,
    forScope: conformanceSpaceScope,
  );

  final registry = buildModelRegistry(session.scope);
  final runtimes = buildModelRuntimes(session.scope, registry: registry);
  final transactions =
      TransactionExecutor<TransactionModels, TransactionMutations>(
        database: session.scope,
        contexts: buildTransactionContexts(session.scope, registry, runtimes),
      );
  await transactions.run(
    (tx) => tx.mutate.renameSpace((mutation) async {
      final space = await mutation.models.space.get(
        SpaceId(UUID.withValidation(conformanceSpaceId)),
      );
      if (space == null) throw StateError('seeded Space did not materialize');
      return (space: mutation.space.update(space, name: 'Renamed'));
    }),
  );

  final queue = MutationQueue(session.scope, registry: registry);
  final batch = await freezeRunnable(queue);

  // The fixture seeding used server sequences 1 and 2. The local database has
  // its own sequence 1; only the wire sequence is translated for this shared
  // conformance client.
  final response = await session.transport.sendUplink(
    session.codec.encodeUplinkRequest(
      clientId: batch.clientId,
      batchSequence: 3,
      mutations: batch.mutations,
      records: batch.records,
    ),
  );
  final decoded = session.codec.decodeUplinkResponse(
    localSyncResponseBody(response),
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

  // Move only the other ledger. A scope-incomparable cursor must not settle
  // the accepted rename, even when its numeric value reaches or exceeds it.
  await session.settle(4, [_sample('update', rank: 43)]);
  await session.settle(5, [_sample('update', rank: 44)]);
  await session.settle(6, [_sample('update', rank: 45)]);
  final spacePage = await session.pull(
    initialSpaceCursor,
    scope: conformanceSpaceScope,
  );
  await applyPage(session.scope, spacePage, afterSyncId: initialSpaceCursor);
  final batchesAfterSpace = await countRows(session.scope, 'uplink_batches');
  final userCursorAfterSpace = await readCursor(session.scope);

  final userPage = await session.pull(initialUserCursor);
  await applyPage(session.scope, userPage, afterSyncId: initialUserCursor);

  final models = typedModels(session.scope);
  final sample = await models.scalarSample.get(
    ScalarSampleId(UUID.withValidation(_sampleId)),
  );
  final space = await models.space.get(
    SpaceId(UUID.withValidation(conformanceSpaceId)),
  );
  return {
    'failures': [
      ...userApplied.failures.map((failure) => failure.toString()),
      ...spaceApplied.failures.map((failure) => failure.toString()),
    ],
    'initialUserCursor': initialUserCursor,
    'initialSpaceCursor': initialSpaceCursor,
    'spaceCursorAfterSpace': await readCursor(
      session.scope,
      forScope: conformanceSpaceScope,
    ),
    'userCursorAfterSpace': userCursorAfterSpace,
    'finalUserCursor': await readCursor(session.scope),
    'requiredScope': decoded.legacyPrincipalCheckpoint.scope,
    'requiredSyncId': decoded.legacyPrincipalCheckpoint.syncId,
    'batchesAfterSpace': batchesAfterSpace,
    'batchesAfterUser': await countRows(session.scope, 'uplink_batches'),
    'spaceName': space?.name,
    'sampleRank': sample?.rank,
  };
}

StoredMutationOperation _sample(String operation, {required int rank}) =>
    StoredMutationOperation(
      mutationOrdinal: 1,
      position: 0,
      model: 'ScalarSample',
      identityJson: jsonEncode({'id': _sampleId}),
      operation: operation,
      valuesJson: jsonEncode(
        operation == 'create'
            ? {
                'enabled': true,
                'rank': rank,
                'score': 1.5,
                'optionalAt': null,
                'optionalUuid': null,
              }
            : {'rank': rank},
      ),
      isUplink: true,
    );

Future<int?> _runtimeCursor(LocalSync localSync, String scope) async {
  final result = await localSync.readOnlySql.query(
    'SELECT last_applied_sync_id FROM downlink_scope_state '
    'WHERE scope = ?',
    [scope],
  );
  if (result.rows.isEmpty) return null;
  return result.rows.single['last_applied_sync_id']! as int;
}

Future<int> _runtimeCount(LocalSync localSync, String table) async {
  final result = await localSync.readOnlySql.query(
    'SELECT COUNT(*) AS count FROM "$table"',
  );
  return result.rows.single['count']! as int;
}

Future<void> _waitFor(
  LocalSync localSync,
  Future<bool> Function() condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('scoped generated runtime did not converge');
}
