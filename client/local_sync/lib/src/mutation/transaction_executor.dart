import '../api/local_sync_transaction.dart';
import '../storage/database_scope.dart';
import 'transaction_context_factory.dart';

/// Opens the one SQLite transaction that owns direct work and every nested
/// named Mutation savepoint.
final class TransactionExecutor<M, Mutations> {
  const TransactionExecutor({required this.database, required this.contexts});

  final LocalDatabaseScope database;
  final TransactionContextFactory<M, Mutations> contexts;

  Future<R> run<R>(
    Future<R> Function(LocalSyncTransaction<M, Mutations> tx) action,
  ) => database.transaction((_) => contexts.run(action));
}
