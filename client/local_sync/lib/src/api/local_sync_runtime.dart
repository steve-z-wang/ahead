import 'package:meta/meta.dart';

import '../mutation/transaction_context_factory.dart';
import '../mutation/transaction_executor.dart';
import '../downlink/scope_reconciler.dart';
import '../schema/model_registry.dart';
import 'local_sync_transaction.dart';
import 'local_sync_mutations.dart';
import 'local_sync_prerequisites.dart';
import '../storage/database_scope.dart';
import '../uplink/uplink_status.dart';
import 'read_only_sql.dart';

abstract base class LocalSyncRuntime<M, Tx, Mutations> {
  @protected
  LocalSyncRuntime({
    required this.models,
    required LocalDatabaseScope database,
    required ModelRegistry registry,
    required Future<void> Function() closeDatabase,
    required TransactionContextFactory<Tx, Mutations> transactionContexts,
    required ScopeReconciler scopeReconciler,
  }) : _database = database,
       _registry = registry,
       _scopeReconciler = scopeReconciler,
       _closeDatabase = closeDatabase,
       _transactions = TransactionExecutor(
         database: database,
         contexts: transactionContexts,
       );

  final M models;

  /// Explicit server refusals remain available until acknowledged.
  late final LocalSyncMutations mutations = LocalSyncMutations(
    _database,
    reads: readOnlySql,
  );

  /// Unsent named acts parked by terminal prerequisites, retaining optimism.
  late final LocalSyncPrerequisites prerequisites = LocalSyncPrerequisites(
    database: _database,
    registry: _registry,
    reads: readOnlySql,
  );
  final TransactionExecutor<Tx, Mutations> _transactions;

  /// Reads the local database directly, in SQL. See [LocalSyncReadOnlySql].
  late final DatabaseReadOnlySql readOnlySql = DatabaseReadOnlySql(
    _database.database,
  );

  /// Where an identity's queued work stands, as a stream.
  ///
  /// Read-only and derived: it writes nothing, stores nothing, and speaks no
  /// protocol vocabulary (CAP-385 spec §6).
  late final UplinkStatusView status = UplinkStatusView(
    database: _database,
    registry: _registry,
  );

  final LocalDatabaseScope _database;
  final ModelRegistry _registry;
  final Future<void> Function() _closeDatabase;
  final ScopeReconciler _scopeReconciler;

  /// The one local atomicity boundary. Direct edits are final at commit;
  /// generated named Mutations beneath `tx.mutate` remain independent Uplink
  /// records with their own later acceptance or rejection fate.
  Future<R> transaction<R>(
    Future<R> Function(LocalSyncTransaction<Tx, Mutations> tx) action,
  ) => _transactions.run(action);

  /// Starts durable scope reconciliation. Opening a runtime performs no I/O.
  Future<void> start() => _scopeReconciler.start();

  Future<void> close() async {
    try {
      await readOnlySql.close();
    } finally {
      try {
        await _scopeReconciler.close();
      } finally {
        await _closeDatabase();
      }
    }
  }
}
