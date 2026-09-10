import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/mutation_store.dart';
import '../mutation/transaction_context_factory.dart';
import 'local_sync_operation_snapshot.dart';
import '../mutation/model_mutation.dart';
import '../schema/model_id.dart';
import '../storage/local_value_codec.dart';
import '../schema/model_registry.dart';
import '../storage/database_scope.dart';
import '../uplink/mutation_queue.dart';
import '../uplink/prerequisite.dart';
import '../uplink/queued_mutation.dart';
import 'read_only_sql.dart';

/// The exact queued field occurrence responsible for a concrete prerequisite.
final class LocalSyncPrerequisiteBinding {
  const LocalSyncPrerequisiteBinding({
    required this.operationPosition,
    required this.slotName,
    required this.model,
    required this.operation,
    required this.field,
    required this.identity,
  });
  final int operationPosition;
  final String? slotName;
  final String model;
  final MutationOperation operation;
  final String field;
  final ModelId identity;
}

/// Opaque identity of an unresolved act in its originating client database.
final class LocalSyncPrerequisiteFailureId {
  const LocalSyncPrerequisiteFailureId._(this._clientId, this._ordinal);
  final String _clientId;
  final int _ordinal;

  @override
  bool operator ==(Object other) =>
      other is LocalSyncPrerequisiteFailureId &&
      other._clientId == _clientId &&
      other._ordinal == _ordinal;
  @override
  int get hashCode => Object.hash(_clientId, _ordinal);
}

final class LocalSyncFailedPrerequisite {
  LocalSyncFailedPrerequisite._(
    this.invocation,
    Iterable<LocalSyncPrerequisiteBinding> bindings,
  ) : bindings = List.unmodifiable(bindings);

  final PrerequisiteInvocation invocation;
  final List<LocalSyncPrerequisiteBinding> bindings;
}

/// One complete unsent named Mutation, rather than one transfer attempt.
final class LocalSyncPrerequisiteFailure {
  LocalSyncPrerequisiteFailure._({
    required this.id,
    required this.mutationName,
    required this.mutationOrdinal,
    required Iterable<LocalSyncFailedPrerequisite> causes,
    required Iterable<LocalSyncOperationSnapshot> operations,
  }) : causes = List.unmodifiable(causes),
       operations = List.unmodifiable(operations);

  final LocalSyncPrerequisiteFailureId id;
  final String mutationName;
  final int mutationOrdinal;
  final List<LocalSyncFailedPrerequisite> causes;
  final List<LocalSyncOperationSnapshot> operations;

  List<Object?> get _value => [
    id,
    mutationName,
    for (final operation in operations)
      [
        operation.position,
        operation.slotName,
        operation.model,
        operation.identity,
        operation.operation,
        operation.values,
        operation.isUplink,
      ],
    for (final cause in causes)
      [
        cause.invocation,
        for (final binding in cause.bindings)
          [
            binding.operationPosition,
            binding.slotName,
            binding.model,
            binding.operation,
            binding.field,
            binding.identity.components,
          ],
      ],
  ];
}

/// Derived prerequisite failures. No history is stored; an item exists only
/// while its named Mutation is queued and at least one invocation is failed.
final class LocalSyncPrerequisites extends _PrerequisitesInbox {
  LocalSyncPrerequisites({
    required LocalDatabaseScope database,
    required ModelRegistry registry,
    required LocalSyncReadOnlySql reads,
  }) : _reads = reads,
       super(database, registry);

  final LocalSyncReadOnlySql _reads;

  /// Ordered by local Mutation ordinal; live through empty cycles and closed
  /// with the runtime's managed reads. UNION reads all three sources in ONE
  /// SQLite snapshot without a Cartesian product or a second failure ledger.
  Stream<List<LocalSyncPrerequisiteFailure>> watchFailures() => _reads
      .watch(
        _failureSql,
        tables: const {
          'pending_mutations',
          'pending_mutation_operations',
          'readiness_states',
          'uplink_client_state',
        },
      )
      .map(_failures)
      .distinct(
        (a, b) => const DeepCollectionEquality().equals(
          [for (final item in a) item._value],
          [for (final item in b) item._value],
        ),
      );

  /// Inputs referenced by complete pending acts (also while frozen/accepted).
  /// Infrastructure producers use this for retention, never as failure history.
  Stream<Set<PrerequisiteInvocation>> watchRequired() => _reads
      .watch(
        '${_operations('')} ORDER BY mutation_ordinal, position',
        tables: const {'pending_mutations', 'pending_mutation_operations'},
      )
      .map(
        (result) => Set<PrerequisiteInvocation>.unmodifiable(
          prerequisiteInvocationsOf(
            _registry,
            result.rows.map(storedMutationOperationFromDatabase),
          ),
        ),
      )
      .distinct(const SetEquality<PrerequisiteInvocation>().equals);

  Future<void> discard(LocalSyncPrerequisiteFailureId id) =>
      _database.transaction((_) => _discard(id));

  /// Retries only failed inputs still referenced by pending operations.
  /// A shared invocation resumes every dependent act after commit.
  Future<void> retry(Iterable<PrerequisiteInvocation> invocations) =>
      _database.transaction((_) => _retry(invocations));
}

/// Recovery capabilities bound to the open outer local transaction.
final class TransactionPrerequisites extends _PrerequisitesInbox {
  TransactionPrerequisites({
    required LocalDatabaseScope database,
    required ModelRegistry registry,
    required TransactionFateContext context,
  }) : _context = context,
       super(database, registry);

  final TransactionFateContext _context;

  Future<LocalSyncPrerequisiteFailure?> getFailure(
    LocalSyncPrerequisiteFailureId id,
  ) => _context.runOuterOperation(() => _get(id));

  Future<void> discard(LocalSyncPrerequisiteFailureId id) =>
      _context.runOuterOperation(() => _discard(id));

  Future<void> retry(Iterable<PrerequisiteInvocation> invocations) =>
      _context.runOuterOperation(() => _retry(invocations));
}

abstract class _PrerequisitesInbox {
  _PrerequisitesInbox(this._database, this._registry)
    : _queue = MutationQueue(_database, registry: _registry);

  final LocalDatabaseScope _database;
  final ModelRegistry _registry;
  final MutationQueue _queue;

  Future<void> _discard(LocalSyncPrerequisiteFailureId id) => _queue
      .discardFailedInTransaction(clientId: id._clientId, ordinal: id._ordinal);

  Future<void> _retry(Iterable<PrerequisiteInvocation> invocations) =>
      _queue.retryPrerequisitesInTransaction(invocations);

  Future<LocalSyncPrerequisiteFailure?> _get(
    LocalSyncPrerequisiteFailureId id,
  ) async => _failures(
    await _database.current.query(DatabaseQuery(sql: _failureSql)),
  ).where((failure) => failure.id == id).firstOrNull;

  String get _failureSql =>
      '''
    ${_operations('WHERE parent.batch_sequence IS NULL')}
    UNION ALL
    SELECT 'failed', NULL, key, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
      FROM readiness_states WHERE state = 'failed'
    UNION ALL
    SELECT 'client', NULL, client_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
      FROM uplink_client_state
    ORDER BY kind, mutation_ordinal, position
  ''';

  List<LocalSyncPrerequisiteFailure> _failures(DatabaseQueryResult result) {
    final failed = <String>{};
    final operations = <int, List<StoredMutationOperation>>{};
    final names = <int, String>{};
    String? clientId;
    for (final row in result.rows) {
      switch (row['kind']) {
        case 'client':
          clientId = row['name']! as String;
        case 'failed':
          failed.add(row['name']! as String);
        case 'operation':
          final operation = storedMutationOperationFromDatabase(row);
          (operations[operation.mutationOrdinal] ??= []).add(operation);
          names[operation.mutationOrdinal] = row['name']! as String;
      }
    }
    if (operations.isEmpty) return const [];
    if (clientId == null) throw StateError('missing LocalSync client identity');
    return List.unmodifiable([
      for (final entry in operations.entries)
        if (_causes(entry.value, failed) case final causes
            when causes.isNotEmpty)
          LocalSyncPrerequisiteFailure._(
            id: LocalSyncPrerequisiteFailureId._(clientId, entry.key),
            mutationName: names[entry.key]!,
            mutationOrdinal: entry.key,
            causes: causes,
            operations: [
              for (final operation in entry.value)
                LocalSyncOperationSnapshot.fromSnapshot({
                  'position': operation.position,
                  'slot': operation.slotName,
                  'model': operation.model,
                  'identity': jsonDecode(operation.identityJson),
                  'operation': operation.operation,
                  'values': jsonDecode(operation.valuesJson),
                  'wire': operation.isUplink,
                }),
            ],
          ),
    ]);
  }

  List<LocalSyncFailedPrerequisite> _causes(
    List<StoredMutationOperation> operations,
    Set<String> failed,
  ) {
    final byInvocation =
        <PrerequisiteInvocation, List<LocalSyncPrerequisiteBinding>>{};
    for (final occurrence in prerequisiteOccurrencesOf(_registry, operations)) {
      if (failed.contains(occurrence.invocation.identity)) {
        final row = occurrence.row;
        (byInvocation[occurrence.invocation] ??= []).add(
          LocalSyncPrerequisiteBinding(
            operationPosition: row.position,
            slotName: row.slotName,
            model: row.model,
            operation: MutationOperation.values.byName(row.operation),
            field: occurrence.field,
            identity: const LocalValueCodec().decodeIdentity(
              _registry[row.model]!.schema,
              row.identityJson,
            ),
          ),
        );
      }
    }
    return [
      for (final cause in byInvocation.entries)
        LocalSyncFailedPrerequisite._(cause.key, cause.value),
    ];
  }

  String _operations(String predicate) =>
      '''
    SELECT 'operation' AS kind, operation.mutation_ordinal, parent.name, parent.name AS mutation_name, parent.version AS mutation_version,
      operation.position, operation.slot_name, operation.model,
      operation.identity_json, operation.operation, operation.values_json,
      operation.is_uplink
    FROM pending_mutation_operations AS operation
    JOIN pending_mutations AS parent ON parent.ordinal = operation.mutation_ordinal
    $predicate
  ''';
}
