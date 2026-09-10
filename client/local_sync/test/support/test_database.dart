import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:local_sync_database_sqlite/local_sync_database_sqlite.dart';

final class TestLocalDatabase {
  TestLocalDatabase._(this.directory, this.database)
    : scope = LocalDatabaseScope(database);

  final Directory directory;
  final Database database;
  final LocalDatabaseScope scope;

  static Future<TestLocalDatabase> open({
    Iterable<DatabaseStatement> modelStatements = const [],
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'local_sync_runtime_',
    );
    final driver = SqliteDatabaseDriver.file(
      path: '${directory.path}/local-sync.sqlite',
      migrations: [
        SqliteDatabaseMigration(
          version: 1,
          statements: [
            ...localSyncInfrastructureStatements,
            ...modelStatements,
          ],
        ),
      ],
    );
    return TestLocalDatabase._(directory, await driver.open());
  }

  /// Queues one named record and returns its ordinal.
  ///
  /// Every queued operation belongs to a named act (CAP-444), so a test that
  /// writes to a mutation store directly needs a record for its rows to name.
  Future<int> queueRecord({String name = 'Act'}) async {
    final result = await scope.current.execute(
      DatabaseStatement(
        sql: 'INSERT INTO pending_mutations (name) VALUES (?)',
        variables: [name],
      ),
    );
    final ordinal = result.lastInsertRowId;
    if (ordinal == null) throw StateError('could not queue a mutation record');
    return ordinal;
  }

  Future<void> close() async {
    await database.close();
    await directory.delete(recursive: true);
  }
}

extension MutationQueueTestDriver on MutationQueue {
  Future<UplinkBatchCandidate?> scheduledCandidate({required int limit}) async {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final current = await snapshot();
    final selected = MutationScheduler(
      maxBytes: 1 << 30,
      maxParents: limit,
    ).select(current, encodedBytes: (_) => 0);
    if (selected.isEmpty) return null;
    final ordinals = selected.toSet();
    final chosen = [
      for (final mutation in current.mutations)
        if (ordinals.contains(mutation.mutation.ordinal)) mutation,
    ];
    final boundaries = <int>[];
    var operationCount = 0;
    for (final mutation in chosen) {
      operationCount += mutation.operations.length;
      boundaries.add(operationCount);
    }
    return UplinkBatchCandidate(
      clientId: current.clientId,
      batchSequence: current.nextBatchSequence,
      mutations: [for (final mutation in chosen) ...mutation.operations],
      groupBoundaries: boundaries,
      records: {
        for (final mutation in chosen)
          mutation.mutation.ordinal: mutation.mutation,
      },
    );
  }

  Future<void> recordResponse({
    required int batchSequence,
    required List<UplinkCheckpoint> requiredCheckpoints,
    required UplinkCheckpoint legacyPrincipalCheckpoint,
    required List<UplinkMutationRejection> rejections,
  }) => record(
    BatchExecutionResult(
      batchSequence: batchSequence,
      requiredCheckpoints: requiredCheckpoints,
      legacyPrincipalCheckpoint: legacyPrincipalCheckpoint,
      rejections: rejections,
    ),
  );
}

Future<void> setTestScopes(
  LocalDatabaseScope database,
  Iterable<String> scopes,
) => database.transaction((_) async {
  final store = ScopeStore(database);
  for (final scope in scopes.toSet()) {
    await store.assignDirect(scope, true);
  }
});
