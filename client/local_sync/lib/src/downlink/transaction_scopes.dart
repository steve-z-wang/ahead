import '../api/local_sync_transaction.dart';
import '../mutation/transaction_context_factory.dart';
import 'scope_store.dart';

/// Selects direct base assignment or pending Mutation overlay at each awaited
/// operation boundary, including calls through a captured outer transaction.
final class FateAwareScopeWriter implements TransactionScopes, MutationScopes {
  const FateAwareScopeWriter({required this.store, required this.context});

  final ScopeStore store;
  final TransactionFateContext context;

  @override
  Future<void> set(String scope) => _assign(scope, true);

  @override
  Future<void> remove(String scope) => _assign(scope, false);

  Future<void> _assign(String scope, bool desired) =>
      context.runOperation((mutationOrdinal) {
        if (mutationOrdinal == null) {
          return store.assignDirect(scope, desired);
        }
        return store.assignPending(
          scope,
          desired,
          mutationOrdinal: mutationOrdinal,
        );
      });
}
