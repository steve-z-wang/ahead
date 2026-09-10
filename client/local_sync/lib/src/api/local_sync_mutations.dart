import 'dart:convert';

import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/transaction_context_factory.dart';
import 'local_sync_operation_snapshot.dart';

export 'local_sync_operation_snapshot.dart';
import '../storage/database_scope.dart';
import 'read_only_sql.dart';

/// A stable rejection handle belonging to the originating client database.
final class LocalSyncMutationRejectionId {
  const LocalSyncMutationRejectionId._(this._value);

  final String _value;

  @override
  bool operator ==(Object other) =>
      other is LocalSyncMutationRejectionId && other._value == _value;

  @override
  int get hashCode => _value.hashCode;
}

/// Compatibility name for an immutable operation in a refused act.
typedef LocalSyncRejectedOperation = LocalSyncOperationSnapshot;

/// A device-only scope assignment that shared the rejected act's fate.
final class LocalSyncRejectedScope {
  LocalSyncRejectedScope._(Map<String, Object?> snapshot)
    : position = snapshot['position']! as int,
      scope = snapshot['scope']! as String,
      desired = snapshot['desired']! as bool;

  final int position;
  final String scope;
  final bool desired;
}

/// One explicit Backend refusal; cascaded dependents do not invent refusals.
final class LocalSyncMutationRejection {
  LocalSyncMutationRejection._(DatabaseRow row)
    : id = LocalSyncMutationRejectionId._(row['id']! as String),
      mutationOrdinal = row['mutation_ordinal']! as int,
      mutationName = row['name']! as String,
      version = (row['version'] as int?) ?? 1,
      code = row['code']! as String,
      operations = List.unmodifiable([
        for (final snapshot
            in jsonDecode(row['operations_json']! as String) as List)
          LocalSyncOperationSnapshot.fromSnapshot(
            (snapshot as Map).cast<String, Object?>(),
          ),
      ]),
      scopes = List.unmodifiable([
        for (final snapshot
            in jsonDecode(row['scopes_json']! as String) as List)
          LocalSyncRejectedScope._((snapshot as Map).cast<String, Object?>()),
      ]);

  final LocalSyncMutationRejectionId id;
  final int mutationOrdinal;
  final String mutationName;
  final int version;

  /// The exact server code, including codes unknown to this client build.
  final String code;
  final List<LocalSyncRejectedOperation> operations;
  final List<LocalSyncRejectedScope> scopes;
}

/// Durable Mutation results. Reads never acknowledge or filter by business code.
final class LocalSyncMutations extends _MutationsInbox {
  const LocalSyncMutations(
    LocalDatabaseScope database, {
    required LocalSyncReadOnlySql reads,
  }) : _reads = reads,
       super(database);

  final LocalSyncReadOnlySql _reads;

  /// Emits all unacknowledged refusals in Mutation order, including the initial
  /// empty list. Uses the runtime's managed watcher so subscriptions finish
  /// when LocalSync closes and remain live across empty/non-empty cycles.
  Stream<List<LocalSyncMutationRejection>> watchRejections() => _reads
      .watch(
        '''SELECT id, mutation_ordinal, name, version, code, operations_json, scopes_json
           FROM mutation_rejections ORDER BY mutation_ordinal''',
        tables: const {'mutation_rejections'},
      )
      .map(
        (rows) => List<LocalSyncMutationRejection>.unmodifiable(
          rows.rows.map(LocalSyncMutationRejection._),
        ),
      );

  /// Removes only the result. Rollback has already happened. A stale or
  /// already-acknowledged handle is an idempotent no-op, with no network I/O.
  Future<void> acknowledgeRejection(LocalSyncMutationRejectionId id) =>
      _database.transaction((_) => _acknowledge(id));
}

/// Historical results available only in the open outer local transaction.
final class TransactionMutationsInbox extends _MutationsInbox {
  const TransactionMutationsInbox(
    super.database, {
    required TransactionFateContext context,
  }) : _context = context;

  final TransactionFateContext _context;

  Future<LocalSyncMutationRejection?> getRejection(
    LocalSyncMutationRejectionId id,
  ) => _context.runOuterOperation(() => _get(id));

  Future<void> acknowledgeRejection(LocalSyncMutationRejectionId id) =>
      _context.runOuterOperation(() => _acknowledge(id));
}

abstract class _MutationsInbox {
  const _MutationsInbox(this._database);
  final LocalDatabaseScope _database;

  Future<LocalSyncMutationRejection?> _get(
    LocalSyncMutationRejectionId id,
  ) async {
    final row = (await _database.current.query(
      DatabaseQuery(
        sql:
            'SELECT id, mutation_ordinal, name, version, code, operations_json, scopes_json '
            'FROM mutation_rejections WHERE id = ?',
        variables: [id._value],
      ),
    )).singleOrNull;
    return row == null ? null : LocalSyncMutationRejection._(row);
  }

  Future<void> _acknowledge(LocalSyncMutationRejectionId id) async {
    await _database.current.execute(
      DatabaseStatement(
        sql: 'DELETE FROM mutation_rejections WHERE id = ?',
        variables: [id._value],
      ),
    );
  }
}
