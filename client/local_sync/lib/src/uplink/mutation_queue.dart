import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/mutation_store.dart';
import '../downlink/scopes.dart';
import '../schema/model_id.dart';
import '../schema/relation_index.dart';
import '../schema/model_registry.dart';
import '../storage/cascade_expansion.dart';
import '../storage/database_scope.dart';
import '../storage/row_rebuild_dispatch.dart';
import '../storage/mutation_rejection_store.dart';
import 'readiness_ledger.dart';
import 'prerequisite.dart';
import 'queued_mutation.dart';
import 'mutation_queue_snapshot.dart';
import 'uplink_protocol.dart';

/// The most mutations one batch may carry, matching what the Backend accepts.
/// A send-group larger than this could never ship whole, so it is refused
/// rather than split.
const maximumBatchMutations = 20;

final class UplinkClientStateRow {
  const UplinkClientStateRow({
    required this.clientId,
    required this.lastAssignedBatchSequence,
  });

  final String clientId;
  final int lastAssignedBatchSequence;
}

final class UplinkBatchRow {
  const UplinkBatchRow({required this.sequence});

  final int sequence;
}

final class UplinkBatchCandidate {
  UplinkBatchCandidate({
    required this.clientId,
    required this.batchSequence,
    required List<StoredMutationOperation> mutations,
    List<int>? groupBoundaries,
    Map<int, StoredMutation> records = const {},
  }) : mutations = List.unmodifiable(mutations),
       records = Map.unmodifiable(records),
       groupBoundaries = List.unmodifiable(
         groupBoundaries ?? [for (var i = 1; i <= mutations.length; i += 1) i],
       );

  final String clientId;
  final int batchSequence;
  final List<StoredMutationOperation> mutations;

  /// The named acts these operations belong to, by record ordinal. Empty on a
  /// queue of legacy anonymous writes, where an operation is its own act.
  final Map<int, StoredMutation> records;

  /// The prefix lengths a batch may end at — one per send-group boundary.
  ///
  /// Every truncation downstream must land on one of these. A batch boundary
  /// may fall only BETWEEN groups: a limit that lands inside one defers the
  /// whole group to the next batch rather than publishing half of it.
  final List<int> groupBoundaries;
}

final class UplinkBatch extends UplinkBatchCandidate {
  UplinkBatch({
    required super.clientId,
    required super.batchSequence,
    required super.mutations,
    super.records,
  });
}

final class MutationQueue {
  MutationQueue(this.database, {required this.registry})
    : _expansion = CascadeExpansion(RelationIndex.of(registry)),
      _planner = QueuedMutationPlanner(
        registry: registry,
        ledger: ReadinessLedger(database),
      );

  final LocalDatabaseScope database;

  /// Reached only to rebuild the rows a rejection disturbs.
  final ModelRegistry registry;
  final CascadeExpansion _expansion;
  final QueuedMutationPlanner _planner;

  Future<void> initialize(String clientId) async {
    try {
      UUID.withValidation(clientId);
    } on FormatException catch (error) {
      throw UplinkDataException(
        'clientId must be a UUID',
        clientId,
        error.offset,
      );
    }
    await database.transaction((_) async {
      final current = await _readClientState();
      if (current == null) {
        await database.current.execute(
          DatabaseStatement(
            sql: '''
              INSERT INTO uplink_client_state
                (singleton, client_id, last_assigned_batch_sequence)
              VALUES (1, ?, 0)
            ''',
            variables: [clientId],
          ),
        );
      } else if (current.clientId != clientId) {
        throw StateError('Local Sync database belongs to another client');
      }
    });
  }

  /// Assigns the pre-scope runtime's accepted checkpoints to its one explicit
  /// successor scope. A legacy database had exactly one Downlink stream, so
  /// more than one active candidate is ambiguous and must never be guessed.
  Future<void> bindLegacyCheckpointScope(Iterable<String> scopes) async {
    final active = normalizeScopes(scopes);
    await database.transaction((_) async {
      final legacy = await database.current.query(
        DatabaseQuery(
          sql:
              'SELECT sequence FROM uplink_batches '
              'WHERE legacy_required_sync_id IS NOT NULL',
        ),
      );
      if (legacy.isEmpty) return;
      if (active.length != 1) {
        throw StateError(
          'legacy Uplink checkpoints require exactly one active scope',
        );
      }
      final scope = active.single;
      for (final row in legacy.rows) {
        final inserted = await database.current.execute(
          DatabaseStatement(
            sql:
                'INSERT INTO uplink_batch_checkpoints '
                '(batch_sequence, scope, '
                'required_sync_id) '
                'SELECT sequence, ?, legacy_required_sync_id '
                'FROM uplink_batches WHERE sequence = ?',
            variables: [scope, row['sequence']],
          ),
        );
        _requireAffected(
          inserted,
          1,
          'legacy Uplink checkpoint binding was incomplete',
        );
      }
      final rebound = await database.current.execute(
        DatabaseStatement(
          sql:
              'UPDATE uplink_batches SET required_scope = ?, '
              'required_sync_id = legacy_required_sync_id, '
              'legacy_required_sync_id = NULL '
              'WHERE legacy_required_sync_id IS NOT NULL',
          variables: [scope],
        ),
      );
      if (rebound.affectedRows != legacy.length) {
        throw StateError('legacy Uplink checkpoint binding was incomplete');
      }
    });
  }

  Future<QueueSnapshot> snapshot() => database.transaction((_) => _snapshot());

  Future<QueueSnapshot> _snapshot() async {
    final state = await _clientState();
    final parentRows = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT ordinal, name, version, batch_sequence, legacy_wire_ordinal, '
            'legacy_fifo FROM pending_mutations ORDER BY ordinal',
      ),
    );
    final parents = parentRows.rows.map(_storedMutationFromDatabase).toList();
    final operations = await _readOperations('1 = 1', const []);
    final operationsByParent = <int, List<StoredMutationOperation>>{};
    for (final operation in operations) {
      (operationsByParent[operation.mutationOrdinal] ??= []).add(operation);
    }
    final planned = {
      for (final mutation in await _planner.plan(operations))
        mutation.ordinal: mutation,
    };
    final prerequisitesByParent = await _readPrerequisiteOrdinals();
    final sequencesByParent = await _readSequencePredecessorOrdinals();
    final batches = await database.current.query(
      DatabaseQuery(
        sql: 'SELECT sequence, required_sync_id FROM uplink_batches',
      ),
    );
    final acceptedBySequence = {
      for (final row in batches.rows)
        row['sequence']! as int: row['required_sync_id'] != null,
    };
    return QueueSnapshot(
      [
        for (final parent in parents)
          QueuedMutationSnapshot(
            mutation: parent,
            phase: parent.batchSequence == null
                ? MutationPhase.queued
                : acceptedBySequence[parent.batchSequence] == true
                ? MutationPhase.accepted
                : MutationPhase.frozen,
            operations: operationsByParent[parent.ordinal] ?? const [],
            prerequisiteOrdinals:
                prerequisitesByParent[parent.ordinal] ?? const {},
            sequencePredecessorOrdinals:
                sequencesByParent[parent.ordinal] ?? const {},
            prerequisites: planned[parent.ordinal]?.prerequisites ?? const [],
            readiness: planned[parent.ordinal]?.state ?? ReadinessState.ready,
          ),
      ],
      clientId: state.clientId,
      nextBatchSequence: state.lastAssignedBatchSequence + 1,
    );
  }

  /// Explicitly gives up one still-unsent terminal prerequisite failure.
  /// A stale or foreign-client handle has no effect. Revalidation and rollback
  /// share the same transaction, so a read from an old inbox cannot drop new work.
  Future<void> discardFailed({
    required String clientId,
    required int ordinal,
  }) => database.transaction(
    (_) => discardFailedInTransaction(clientId: clientId, ordinal: ordinal),
  );

  /// Internal capability entry point; the caller owns the commit boundary.
  Future<void> discardFailedInTransaction({
    required String clientId,
    required int ordinal,
  }) async {
    _requireTransaction();
    final current = await _snapshot();
    if (current.clientId != clientId) return;
    final mutation = current[ordinal];
    if (mutation == null ||
        mutation.phase != MutationPhase.queued ||
        mutation.readiness != ReadinessState.failed)
      return;
    await _dropDoomed([
      QueuedMutation(
        ordinal: ordinal,
        operations: mutation.operations,
        prerequisites: mutation.prerequisites,
        state: mutation.readiness,
      ),
    ]);
  }

  /// Internal capability entry point; failed results alone are forgotten.
  Future<void> retryPrerequisitesInTransaction(
    Iterable<PrerequisiteInvocation> invocations,
  ) async {
    _requireTransaction();
    final requested = invocations.toSet();
    if (requested.isEmpty) return;
    final referenced = prerequisiteInvocationsOf(
      registry,
      await _readOperations('1 = 1', const []),
    ).toSet();
    await ReadinessLedger(
      database,
    ).retryFailed(requested.intersection(referenced));
  }

  void _requireTransaction() {
    if (database.current is! DatabaseTransaction) {
      throw StateError('recovery requires an active LocalSync transaction');
    }
  }

  /// Whether there is anything to send, re-asked whenever that could change.
  ///
  /// The ledger counts are in the query for one reason: a mark is the one event
  /// that can make a waiting group sendable while the queue itself does not
  /// move. Watching only the queue would leave a page sitting until some
  /// unrelated write happened to wake the worker.
  ///
  /// Every re-query EMITS — deliberately not `distinct`. The watch coalesces
  /// nearby commits into one re-query, so a summary that happens to match the
  /// previous one does not mean nothing changed: pruning one settled mark
  /// while vouching another leaves the counts equal, and the vouch may be the
  /// last write for a long time. Distinct-ing on that summary swallowed
  /// exactly that wake and left a ready act sitting unsent (CAP-513). A spare
  /// emission costs one cheap candidate read; a lost one costs the queue.
  Stream<bool> watchSendable() => database.database
      .watch(
        DatabaseQuery(
          sql: '''
            SELECT
              (EXISTS(
                SELECT 1 FROM uplink_batches
                WHERE required_sync_id IS NULL
              ) OR EXISTS(
                SELECT 1 FROM pending_mutations
                WHERE batch_sequence IS NULL
              )) AS sendable,
              (SELECT COUNT(*) FROM readiness_states WHERE state = 'ready')
                AS ready_count,
              (SELECT COUNT(*) FROM readiness_states WHERE state = 'failed')
                AS failed_count
          ''',
        ),
      )
      .map((result) => result.singleOrNull?['sendable'] == 1);

  Future<UplinkBatch?> readInFlightBatch() async {
    final row = await _readSendingBatch();
    if (row == null) return null;
    final state = await _clientState();
    final mutations = await _readBatchMutations(row.sequence);
    return UplinkBatch(
      clientId: state.clientId,
      batchSequence: row.sequence,
      mutations: mutations,
      records: await _readRecords(mutations),
    );
  }

  /// Removes the doomed rows' queued mutations and their dependency closure,
  /// then rebuilds what they touched — the CAP-396 rejection formula, driven
  /// by the product rather than the server.
  Future<void> _dropDoomed(List<QueuedMutation> mutations) async {
    final doomed = <StoredMutationOperation>[];
    // A named act dies whole: which writes share fate is schema, so one
    // failed key takes the mutation, not just the operation carrying it.
    for (final mutation in mutations) {
      if (mutation.state != ReadinessState.failed) continue;
      doomed.addAll(mutation.operations);
    }
    if (doomed.isEmpty) return;

    final failedParents = <int>{for (final row in doomed) row.mutationOrdinal};
    final parentOrdinals = (await _lifecycleClosure(
      failedParents,
      queuedOnly: true,
    )).toList()..sort();
    final condemned = await _readOperationsForParents(parentOrdinals);
    final deleted = await database.current.execute(
      DatabaseStatement(
        sql:
            'DELETE FROM pending_mutations '
            'WHERE ordinal IN (${_placeholders(parentOrdinals.length)}) '
            'AND batch_sequence IS NULL',
        variables: parentOrdinals,
      ),
    );
    _requireAffected(deleted, parentOrdinals.length, 'missing doomed mutation');
    // Rebuild by the rejection formula: truth (or nonexistence) plus whatever
    // of the row's edits still stand. A row whose only edit was the doomed
    // create rebuilds away entirely.
    await visitQueuedRows(
      registry,
      condemned,
      (entry, id) => entry.rebuild(id),
    );
    await visitFallenRows(
      registry,
      _expansion,
      condemned,
      (entry, id) => entry.rebuild(id),
    );
    // Reference-aware (CAP-521): a key another queued act still carries is
    // not this drop's to forget — pruning it would strand that act unsendable.
    await _planner.ledger.pruneUnreferenced(
      _planner.invocationsOf(condemned),
      await queuedPrerequisiteInvocations(database, registry),
    );
  }

  Future<UplinkBatch> freeze({
    required int expectedSequence,
    required List<int> mutationOrdinals,
  }) => database.transaction((_) async {
    if (mutationOrdinals.isEmpty ||
        mutationOrdinals.toSet().length != mutationOrdinals.length) {
      throw StateError('batch mutation ids must be non-empty and unique');
    }
    if (await _readSendingBatch() != null) {
      throw StateError('an Uplink batch is already Sending');
    }
    final state = await _clientState();
    if (state.lastAssignedBatchSequence + 1 != expectedSequence) {
      throw StateError('stale Uplink batch sequence');
    }
    final ready = await _readQueuedParentsByOrdinal(mutationOrdinals);
    final actualIds = ready.map((row) => row.ordinal).toList();
    if (!_sameInts(actualIds, mutationOrdinals)) {
      throw StateError('stale Uplink batch candidate');
    }
    await database.current.execute(
      DatabaseStatement(
        sql: 'INSERT INTO uplink_batches (sequence) VALUES (?)',
        variables: [expectedSequence],
      ),
    );
    final assigned = await database.current.execute(
      DatabaseStatement(
        sql:
            'UPDATE pending_mutations SET batch_sequence = ? '
            'WHERE ordinal IN (${_placeholders(mutationOrdinals.length)})',
        variables: [expectedSequence, ...mutationOrdinals],
      ),
    );
    _requireAffected(
      assigned,
      mutationOrdinals.length,
      'stale mutation assignment',
    );
    final stateUpdate = await database.current.execute(
      DatabaseStatement(
        sql:
            'UPDATE uplink_client_state '
            'SET last_assigned_batch_sequence = ? WHERE singleton = 1',
        variables: [expectedSequence],
      ),
    );
    _requireAffected(stateUpdate, 1, 'missing Uplink client state');
    final assignedMutations = await _readBatchMutations(expectedSequence);
    return UplinkBatch(
      clientId: state.clientId,
      batchSequence: expectedSequence,
      mutations: assignedMutations,
      records: await _readRecords(assignedMutations),
    );
  });

  Future<void> record(BatchExecutionResult result) => database.transaction((
    _,
  ) async {
    final batchSequence = result.batchSequence;
    final requiredCheckpoints = result.requiredCheckpoints;
    final legacyPrincipalCheckpoint = result.legacyPrincipalCheckpoint;
    final rejections = result.rejections;
    if (requiredCheckpoints.isEmpty) {
      throw StateError('required checkpoints must not be empty');
    }
    final checkpointScopes = <String>{};
    for (final checkpoint in [
      ...requiredCheckpoints,
      legacyPrincipalCheckpoint,
    ]) {
      if (checkpoint.syncId < 0 || checkpoint.syncId > 9007199254740991) {
        throw StateError('invalid required checkpoint syncId');
      }
    }
    for (final checkpoint in requiredCheckpoints) {
      if (!checkpointScopes.add(checkpoint.scope)) {
        throw StateError('duplicate required checkpoint scope');
      }
    }
    final sending = await _readSendingBatch();
    if (sending == null || sending.sequence != batchSequence) {
      throw StateError('response does not match the Sending batch');
    }
    final mutations = await _readBatchMutations(batchSequence);
    final records = await _readRecords(mutations);
    final parentByWireOrdinal = {
      for (final record in records.values)
        record.legacyWireOrdinal ?? record.ordinal: record.ordinal,
    };
    final requestIds = parentByWireOrdinal.keys.toSet();
    final rejectionIds = <int>{};
    for (final rejection in rejections) {
      if (rejection.code.isEmpty ||
          !rejectionIds.add(rejection.mutationId) ||
          !requestIds.contains(rejection.mutationId)) {
        throw StateError('invalid Uplink mutation rejection');
      }
    }
    final response = await database.current.execute(
      DatabaseStatement(
        sql:
            'UPDATE uplink_batches SET required_scope = ?, '
            'required_sync_id = ? '
            'WHERE sequence = ?',
        variables: [
          legacyPrincipalCheckpoint.scope,
          legacyPrincipalCheckpoint.syncId,
          batchSequence,
        ],
      ),
    );
    _requireAffected(response, 1, 'missing Uplink batch');
    for (final checkpoint in requiredCheckpoints) {
      final inserted = await database.current.execute(
        DatabaseStatement(
          sql:
              'INSERT INTO uplink_batch_checkpoints '
              '(batch_sequence, scope, '
              'required_sync_id) VALUES (?, ?, ?)',
          variables: [batchSequence, checkpoint.scope, checkpoint.syncId],
        ),
      );
      _requireAffected(inserted, 1, 'missing Uplink checkpoint');
    }
    if (rejectionIds.isNotEmpty) {
      // Save every explicit verdict while the complete named act still exists.
      // The response, result capture and existing rollback share one commit.
      final client = await _clientState();
      final results = MutationRejectionStore(database);
      for (final rejection in rejections) {
        final ordinal = parentByWireOrdinal[rejection.mutationId]!;
        await results.retain(
          clientId: client.clientId,
          mutation: records[ordinal]!,
          code: rejection.code,
          operations: mutations
              .where((operation) => operation.mutationOrdinal == ordinal)
              .toList(),
        );
      }
      // A rejection names one MUTATION. For a named act that is the record,
      // reached by the ordinal of its first operation, and the whole record
      // rolls back: which writes share fate is schema, and the server refused
      // the act, not a letter of it.
      final rejectedRecords = {
        for (final id in rejectionIds) parentByWireOrdinal[id]!,
      };
      // Capture the lifecycle closure BEFORE deleting its roots: the edge
      // tables cascade with their parents, so asking afterwards would erase
      // the evidence that the dependent optimistic acts rested on them.
      final condemnedRecords = await _lifecycleClosure(rejectedRecords);
      final disturbed = await _readOperationsForParents(
        condemnedRecords.toList()..sort(),
      );
      final deleted = await database.current.execute(
        DatabaseStatement(
          sql:
              'DELETE FROM pending_mutations '
              'WHERE ordinal IN (${_placeholders(condemnedRecords.length)})',
          variables: condemnedRecords,
        ),
      );
      _requireAffected(
        deleted,
        condemnedRecords.length,
        'missing Uplink mutation',
      );
      // Reference-aware (CAP-521): only keys no surviving act carries go.
      await _planner.ledger.pruneUnreferenced(
        _planner.invocationsOf(disturbed),
        await queuedPrerequisiteInvocations(database, registry),
      );
      // The rejected edit has left the queue, so every row it touched is now
      // wrong in the main table: rebuild each from the truth held aside plus
      // whatever of its edits still stand (CAP-393 spec §4). In the common
      // case — a row with one pending edit — this is a plain copy-back.
      await visitQueuedRows(
        registry,
        disturbed,
        (entry, id) => entry.rebuild(id),
      );
      // A refused delete takes back everything that fell with it. Each of
      // those rows rebuilds by the same formula, and the formula is what makes
      // the interleavings come out right: a page the user had deleted in its
      // own right replays that delete and stays gone (CAP-396 spec §7).
      await visitFallenRows(
        registry,
        _expansion,
        disturbed,
        (entry, id) => entry.rebuild(id),
      );
    }
  });

  Future<Set<int>> _lifecycleClosure(
    Set<int> roots, {
    bool queuedOnly = false,
  }) async {
    final closure = <int>{...roots};
    var frontier = <int>{...roots};
    while (frontier.isNotEmpty) {
      final result = await database.current.query(
        DatabaseQuery(
          sql:
              'SELECT edge.mutation_ordinal '
              'FROM pending_mutation_prerequisites AS edge '
              'JOIN pending_mutations AS dependent '
              'ON dependent.ordinal = edge.mutation_ordinal '
              'WHERE edge.prerequisite_ordinal IN '
              '(${_placeholders(frontier.length)}) '
              '${queuedOnly ? 'AND dependent.batch_sequence IS NULL ' : ''}'
              'ORDER BY edge.mutation_ordinal',
          variables: frontier,
        ),
      );
      final next = <int>{};
      for (final row in result.rows) {
        final ordinal = row['mutation_ordinal']! as int;
        if (closure.add(ordinal)) next.add(ordinal);
      }
      frontier = next;
    }
    return Set.unmodifiable(closure);
  }

  Future<UplinkClientStateRow?> _readClientState() async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT client_id, last_assigned_batch_sequence '
            'FROM uplink_client_state WHERE singleton = 1',
      ),
    )).singleOrNull;
    return row == null
        ? null
        : UplinkClientStateRow(
            clientId: row['client_id']! as String,
            lastAssignedBatchSequence:
                row['last_assigned_batch_sequence']! as int,
          );
  }

  Future<UplinkClientStateRow> _clientState() async {
    final state = await _readClientState();
    if (state == null) throw StateError('MutationQueue is not initialized');
    return state;
  }

  Future<UplinkBatchRow?> _readSendingBatch() async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT sequence FROM uplink_batches '
            'WHERE required_sync_id IS NULL ORDER BY sequence LIMIT 1',
      ),
    )).singleOrNull;
    return row == null ? null : _batch(row);
  }

  /// The named acts the given operations belong to, by record ordinal.
  Future<Map<int, StoredMutation>> _readRecords(
    List<StoredMutationOperation> rows,
  ) async {
    final ordinals = rows.map((row) => row.mutationOrdinal).toSet().toList();
    if (ordinals.isEmpty) return const {};
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT ordinal, name, version, batch_sequence, legacy_wire_ordinal, '
            'legacy_fifo FROM pending_mutations '
            'WHERE ordinal IN (${_placeholders(ordinals.length)})',
        variables: ordinals,
      ),
    );
    return {
      for (final row in result.rows)
        row['ordinal']! as int: StoredMutation(
          ordinal: row['ordinal']! as int,
          name: row['name']! as String,
          version: row['version'] as int?,
          batchSequence: row['batch_sequence'] as int?,
          legacyWireOrdinal: row['legacy_wire_ordinal'] as int?,
          legacyFifo: (row['legacy_fifo']! as int) != 0,
        ),
    };
  }

  Future<List<StoredMutation>> _readQueuedParentsByOrdinal(
    List<int> ordinals,
  ) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT ordinal, name, version, batch_sequence, legacy_wire_ordinal, '
            'legacy_fifo FROM pending_mutations '
            'WHERE batch_sequence IS NULL '
            'AND ordinal IN (${_placeholders(ordinals.length)}) '
            'ORDER BY ordinal',
        variables: ordinals,
      ),
    );
    return List.unmodifiable(result.rows.map(_storedMutationFromDatabase));
  }

  Future<List<StoredMutationOperation>> _readBatchMutations(int sequence) =>
      _readOperations('parent.batch_sequence = ?', [sequence]);

  Future<List<StoredMutationOperation>> _readOperationsForParents(
    List<int> parentOrdinals,
  ) {
    if (parentOrdinals.isEmpty) return Future.value(const []);
    return _readOperations(
      'operation.mutation_ordinal IN '
      '(${_placeholders(parentOrdinals.length)})',
      parentOrdinals,
    );
  }

  Future<List<StoredMutationOperation>> _readOperations(
    String predicate,
    List<Object?> variables,
  ) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            '''
          SELECT parent.name AS mutation_name, parent.version AS mutation_version,
                 operation.mutation_ordinal, operation.position,
                 operation.slot_name,
                 operation.model, operation.identity_json,
                 operation.operation, operation.values_json,
                 operation.is_uplink
          FROM pending_mutation_operations AS operation
          JOIN pending_mutations AS parent
            ON parent.ordinal = operation.mutation_ordinal
          WHERE $predicate
          ORDER BY operation.mutation_ordinal, operation.position
        ''',
        variables: variables,
      ),
    );
    return List<StoredMutationOperation>.unmodifiable(
      result.rows.map(storedMutationOperationFromDatabase),
    );
  }

  Future<Map<int, Set<int>>> _readPrerequisiteOrdinals() => _readOrdinalEdges(
    table: 'pending_mutation_prerequisites',
    predecessorColumn: 'prerequisite_ordinal',
  );

  Future<Map<int, Set<int>>> _readSequencePredecessorOrdinals() =>
      _readOrdinalEdges(
        table: 'pending_mutation_sequences',
        predecessorColumn: 'predecessor_ordinal',
      );

  Future<Map<int, Set<int>>> _readOrdinalEdges({
    required String table,
    required String predecessorColumn,
  }) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT mutation_ordinal, $predecessorColumn FROM $table '
            'ORDER BY mutation_ordinal, $predecessorColumn',
      ),
    );
    final byParent = <int, Set<int>>{};
    for (final row in result.rows) {
      (byParent[row['mutation_ordinal']! as int] ??= {}).add(
        row[predecessorColumn]! as int,
      );
    }
    return Map.unmodifiable({
      for (final entry in byParent.entries)
        entry.key: Set.unmodifiable(entry.value),
    });
  }
}

StoredMutation _storedMutationFromDatabase(DatabaseRow row) => StoredMutation(
  ordinal: row['ordinal']! as int,
  name: row['name']! as String,
  version: row['version'] as int?,
  batchSequence: row['batch_sequence'] as int?,
  legacyWireOrdinal: row['legacy_wire_ordinal'] as int?,
  legacyFifo: (row['legacy_fifo']! as int) != 0,
);

UplinkBatchRow _batch(DatabaseRow row) =>
    UplinkBatchRow(sequence: row['sequence']! as int);

String _placeholders(int count) => List.filled(count, '?').join(', ');

void _requireAffected(
  DatabaseExecutionResult result,
  int expected,
  String message,
) {
  if (result.affectedRows != expected) throw StateError(message);
}

bool _sameInts(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
