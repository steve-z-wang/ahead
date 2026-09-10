import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/model_mutation.dart';
import '../mutation/mutation_store.dart';
import '../schema/model_registry.dart';
import '../storage/database_scope.dart';
import '../storage/local_value_codec.dart';
import 'readiness_ledger.dart';
import 'prerequisite.dart';
import 'uplink_protocol.dart';

/// One queued named act: the record, the operations that spell it, and whether
/// the work they wait on is done.
///
/// Which operations share fate was settled by the name at the call site, so
/// nothing here derives it: no closure walk over the reference graph, and no
/// stranger admitted. A reference describes structure and leaves the queue
/// alone (CAP-437), and the act is the one unit throughout — one wire element,
/// one server savepoint, one rejection, one settlement (CAP-439).
final class QueuedMutation {
  QueuedMutation({
    required this.ordinal,
    required List<StoredMutationOperation> operations,
    Iterable<PrerequisiteInvocation> prerequisites = const [],
    required this.state,
  }) : operations = List.unmodifiable(operations),
       prerequisites = List.unmodifiable(prerequisites);

  /// The `pending_mutations` record these operations belong to.
  final int ordinal;

  /// Position-ordered; FIFO inside an act is never disturbed.
  final List<StoredMutationOperation> operations;
  final List<PrerequisiteInvocation> prerequisites;

  /// The act's own readiness: ready only if every operation is.
  final ReadinessState state;
}

/// Reads a window of queued operations back into the acts they spell, and
/// judges each one.
final class QueuedMutationPlanner {
  const QueuedMutationPlanner({
    required this.registry,
    required this.ledger,
    this.codec = const LocalValueCodec(),
  });

  final ModelRegistry registry;

  /// The one place readiness is read; the outbox prunes through it too.
  final ReadinessLedger ledger;
  final LocalValueCodec codec;

  /// The acts over [rows], ordered by the ordinal each one starts at.
  ///
  /// [rows] must be the queue in ordinal order.
  Future<List<QueuedMutation>> plan(List<StoredMutationOperation> rows) async {
    final byRecord = <int, List<StoredMutationOperation>>{};
    for (final row in rows) {
      (byRecord[row.mutationOrdinal] ??= <StoredMutationOperation>[]).add(row);
    }

    final mutations = <QueuedMutation>[];
    for (final entry in byRecord.entries) {
      final operations = entry.value
        ..sort((left, right) => left.position.compareTo(right.position));
      // Readiness scans every operation in the record, so one pending key
      // holds the whole act and one failed key parks it.
      mutations.add(
        QueuedMutation(
          ordinal: entry.key,
          operations: operations,
          prerequisites: invocationsOf(operations),
          state: await _stateOf(invocationsOf(operations)),
        ),
      );
    }
    mutations.sort((left, right) => left.ordinal.compareTo(right.ordinal));
    return List.unmodifiable(mutations);
  }

  /// One failed prerequisite parks the entire named act until explicit discard.
  Future<ReadinessState> _stateOf(
    Iterable<PrerequisiteInvocation> prerequisites,
  ) async {
    var state = ReadinessState.ready;
    for (final prerequisite in prerequisites) {
      final marked = await ledger.read(prerequisite);
      if (marked == ReadinessState.failed) return ReadinessState.failed;
      if (marked == ReadinessState.pending) state = ReadinessState.pending;
    }
    return state;
  }

  Iterable<PrerequisiteInvocation> invocationsOf(
    Iterable<StoredMutationOperation> rows,
  ) => prerequisiteInvocationsOf(registry, rows, codec: codec);
}

Future<Set<PrerequisiteInvocation>> queuedPrerequisiteInvocations(
  LocalDatabaseScope database,
  ModelRegistry registry, {
  LocalValueCodec codec = const LocalValueCodec(),
}) async {
  final result = await database.current.query(
    DatabaseQuery(
      sql:
          'SELECT parent.name AS mutation_name, parent.version AS mutation_version, '
          'mutation_ordinal, position, slot_name, model, identity_json, '
          'operation, values_json, is_uplink '
          'FROM pending_mutation_operations '
          'JOIN pending_mutations AS parent ON parent.ordinal = mutation_ordinal',
    ),
  );
  return prerequisiteInvocationsOf(
    registry,
    result.rows.map(storedMutationOperationFromDatabase),
    codec: codec,
  ).toSet();
}

/// Every concrete prerequisite invocation carried by the wire operations.
///
/// Creates and updates expose exactly the values stored in [valuesJson], so an
/// update that does not name a prerequisite field contributes nothing. Deletes
/// and device-only companions never reach the wire and therefore contribute
/// nothing either.
Iterable<PrerequisiteInvocation> prerequisiteInvocationsOf(
  ModelRegistry registry,
  Iterable<StoredMutationOperation> rows, {
  LocalValueCodec codec = const LocalValueCodec(),
}) sync* {
  final seen = <PrerequisiteInvocation>{};
  for (final occurrence in prerequisiteOccurrencesOf(
    registry,
    rows,
    codec: codec,
  )) {
    if (seen.add(occurrence.invocation)) yield occurrence.invocation;
  }
}

/// A concrete invocation and the queued field that produced it. Keeping the
/// stored row here avoids decoding identities when only readiness is needed.
final class PrerequisiteOccurrence {
  const PrerequisiteOccurrence(this.invocation, this.row, this.field);
  final PrerequisiteInvocation invocation;
  final StoredMutationOperation row;
  final String field;
}

Iterable<PrerequisiteOccurrence> prerequisiteOccurrencesOf(
  ModelRegistry registry,
  Iterable<StoredMutationOperation> rows, {
  LocalValueCodec codec = const LocalValueCodec(),
}) sync* {
  for (final row in rows) {
    if (!row.isUplink || row.operation == MutationOperation.delete.name) {
      continue;
    }
    final entry = registry[row.model];
    if (entry == null) {
      throw UplinkDataException('unknown queued Model', row.model, null);
    }
    final schema = registry.inputSchema(row);
    final values = codec.decodeValues(schema, row.valuesJson);
    for (final field in schema.fields) {
      final requirement = field.prerequisite;
      if (requirement == null || !values.containsKey(field.name)) continue;
      final arguments = <String, Object>{};
      var absent = false;
      for (final binding in requirement.arguments.entries) {
        final value = values[binding.value];
        if (value == null) {
          absent = true;
          break;
        }
        arguments[binding.key] = value;
      }
      if (absent) continue;
      final invocation = PrerequisiteInvocation(
        name: requirement.name,
        arguments: arguments,
      );
      yield PrerequisiteOccurrence(invocation, row, field.name);
    }
  }
}
