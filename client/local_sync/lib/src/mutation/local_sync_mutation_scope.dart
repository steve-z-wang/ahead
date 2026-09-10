import '../api/local_sync_transaction.dart';

/// The capability handed to one named Mutation callback.
///
/// It deliberately has no nested `mutate` member. Runtime context checks are
/// still the enforcement boundary because a Dart closure can capture its
/// outer transaction.
final class LocalSyncMutationScope<M> {
  const LocalSyncMutationScope({required this.models, required this.scopes});

  final M models;
  final MutationScopes scopes;
}
