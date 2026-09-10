import 'dart:async';

import '../api/local_sync_transaction.dart';
import '../api/local_sync_prerequisites.dart';
import '../api/local_sync_mutations.dart';
import '../schema/model_registry.dart';
import '../storage/database_scope.dart';
import 'local_sync_mutation_scope.dart';
import 'mutation_scope_executor.dart';

/// The fate of operations entering one open outer transaction.
///
/// A Zone carries the active Mutation ordinal across `await`. The transaction
/// object owns the exclusivity guard, so a sibling Zone cannot enter while a
/// savepoint is active and an accidentally captured outer writer cannot escape
/// the active Mutation fate.
final class TransactionFateContext {
  final Object _ordinalKey = Object();
  bool _closed = false;
  bool _mutationActive = false;
  bool _operationActive = false;
  int? _activeOrdinal;

  Future<T> runOperation<T>(
    Future<T> Function(int? mutationOrdinal) operation,
  ) async {
    if (_closed) throw StateError('LocalSync transaction is closed');
    if (_operationActive) {
      throw StateError('LocalSync transaction operations must be awaited');
    }

    final zoneOrdinal = Zone.current[_ordinalKey] as int?;
    if (_mutationActive) {
      if (zoneOrdinal == null || zoneOrdinal != _activeOrdinal) {
        throw StateError(
          'a sibling operation cannot enter an active LocalSync Mutation',
        );
      }
    } else if (zoneOrdinal != null) {
      throw StateError('LocalSync Mutation scope is no longer active');
    }

    _operationActive = true;
    try {
      return await operation(zoneOrdinal);
    } finally {
      _operationActive = false;
    }
  }

  /// Inbox recovery changes the whole outer transaction, never a named fate.
  Future<T> runOuterOperation<T>(Future<T> Function() operation) =>
      runOperation((ordinal) {
        if (ordinal != null) {
          throw StateError('recovery cannot run inside a LocalSync Mutation');
        }
        return operation();
      });

  Future<T> runMutation<T>(Future<T> Function() action) async {
    if (_closed) throw StateError('LocalSync transaction is closed');
    if (_mutationActive || _operationActive) {
      throw StateError(
        'LocalSync Mutations must run sequentially inside a transaction',
      );
    }
    _mutationActive = true;
    try {
      return await action();
    } finally {
      _activeOrdinal = null;
      _mutationActive = false;
    }
  }

  Future<T> bindMutation<T>(int ordinal, Future<T> Function() action) {
    if (!_mutationActive || _activeOrdinal != null) {
      throw StateError('LocalSync Mutation savepoint is not ready to bind');
    }
    _activeOrdinal = ordinal;
    return runZoned(action, zoneValues: {_ordinalKey: ordinal});
  }

  void close() {
    if (_mutationActive || _operationActive) {
      throw StateError(
        'LocalSync transaction operations must complete before callback return',
      );
    }
    _closed = true;
  }
}

/// Builds the public transaction capability against an already-open database
/// transaction. It owns no commit boundary, so Downlink can reuse it inside
/// its existing per-change transaction.
final class TransactionContextFactory<M, Mutations> {
  const TransactionContextFactory({
    required this.database,
    required this.registry,
    required this.targets,
    required this.buildModels,
    required this.buildTransactionScopes,
    required this.buildMutationScopes,
    required this.buildMutations,
  });

  final LocalDatabaseScope database;
  final ModelRegistry registry;
  final Map<String, MutationTarget> targets;
  final M Function(TransactionFateContext context) buildModels;
  final TransactionScopes Function(TransactionFateContext context)
  buildTransactionScopes;
  final MutationScopes Function(TransactionFateContext context)
  buildMutationScopes;
  final Mutations Function(MutationScopeExecutor<M> executor) buildMutations;

  Future<R> run<R>(
    Future<R> Function(LocalSyncTransaction<M, Mutations> tx) action,
  ) async {
    final context = TransactionFateContext();
    final models = buildModels(context);
    final mutationScope = LocalSyncMutationScope<M>(
      models: models,
      scopes: buildMutationScopes(context),
    );
    final mutationExecutor = MutationScopeExecutor<M>(
      database: database,
      registry: registry,
      targets: targets,
      context: context,
      scope: mutationScope,
    );
    final transaction = LocalSyncTransaction<M, Mutations>(
      models: models,
      scopes: buildTransactionScopes(context),
      mutate: buildMutations(mutationExecutor),
      prerequisites: TransactionPrerequisites(
        database: database,
        registry: registry,
        context: context,
      ),
      mutations: TransactionMutationsInbox(database, context: context),
    );
    try {
      return await action(transaction);
    } finally {
      context.close();
    }
  }
}
