import 'local_sync_prerequisites.dart';
import 'local_sync_mutations.dart';

/// Scope assignments available in an outer local transaction.
abstract interface class TransactionScopes {
  Future<void> set(String scope);

  Future<void> remove(String scope);
}

/// Scope assignments that share one named Mutation's fate.
abstract interface class MutationScopes {
  Future<void> set(String scope);

  Future<void> remove(String scope);
}

/// Everything one outer local transaction can do.
final class LocalSyncTransaction<M, Mutations> {
  const LocalSyncTransaction({
    required this.models,
    required this.scopes,
    required this.mutate,
    required this.prerequisites,
    required this.mutations,
  });

  /// The generated per-Model transaction collections: `tx.models.space`.
  final M models;

  /// Durable scope assignments committed with the outer transaction.
  final TransactionScopes scopes;

  /// The generated named-Mutation namespace bound to this transaction.
  final Mutations mutate;

  /// Pending prerequisite recovery in this transaction.
  final TransactionPrerequisites prerequisites;

  /// Historical rejection reads and acknowledgment in this transaction.
  final TransactionMutationsInbox mutations;
}
