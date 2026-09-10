import 'package:local_sync_database/local_sync_database.dart';

import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import '../storage/database_scope.dart';
import '../storage/local_value_codec.dart';
import 'model_mutation.dart';

final class StoredMutationOperation {
  const StoredMutationOperation({
    required this.mutationOrdinal,
    this.mutationName,
    this.mutationVersion,
    required this.position,
    this.slotName,
    required this.model,
    required this.identityJson,
    required this.operation,
    required this.valuesJson,
    required this.isUplink,
  });

  final int mutationOrdinal;
  final String? mutationName;
  final int? mutationVersion;
  final int position;
  final String? slotName;
  final String model;
  final String identityJson;
  final String operation;
  final String valuesJson;

  /// Whether this operation is one the Backend receives (CAP-488).
  ///
  /// The act's returned slots are its wire operations; a direct write made
  /// inside the same callback is a device-only companion that rides the queue
  /// for the act's fate alone. Stated per operation rather than inferred from
  /// the Model, because a Model says nothing about replication.
  final bool isUplink;

  MutationPosition get order => MutationPosition(
    mutationOrdinal: mutationOrdinal,
    operationPosition: position,
  );
}

/// One queued named act: the word it was declared under.
///
/// Its operations are the `pending_mutation_operations` rows beneath it. The
/// pair is what the wire carries above the operations, and what tells the
/// server which business to run.
final class StoredMutation {
  const StoredMutation({
    required this.ordinal,
    required this.name,
    required this.legacyFifo,
    this.version,
    this.batchSequence,
    this.legacyWireOrdinal,
  });

  final int ordinal;
  final String name;

  /// Null preserves the legacy omitted-wire spelling of version 1.
  final int? version;
  int get effectiveVersion => version ?? 1;
  final int? batchSequence;
  final int? legacyWireOrdinal;
  final bool legacyFifo;
}

final class StoredMutationSequence {
  const StoredMutationSequence({
    required this.mutationOrdinal,
    required this.predecessorOrdinal,
  });

  final int mutationOrdinal;
  final int predecessorOrdinal;
}

final class StoredMutationPrerequisite {
  const StoredMutationPrerequisite({
    required this.mutationOrdinal,
    required this.prerequisiteOrdinal,
  });

  final int mutationOrdinal;
  final int prerequisiteOrdinal;
}

/// The edits that still stand for one row — what a rebuild replays over truth.
///
/// The queue is one answer to that and not always the whole of it: a row can
/// also be carried off by an ancestor's pending delete, which never appears in
/// its own queue (see `EffectiveMutations`).
abstract interface class SurvivingMutations<I extends ModelId> {
  Future<List<ModelMutation<I>>> read(I id);
}

abstract interface class MutationStore<I extends ModelId>
    implements SurvivingMutations<I> {
  Future<MutationPosition> append({
    required I id,
    required MutationOperation operation,
    required Map<String, Object?> values,
    required int mutationOrdinal,
    required bool wire,
    String? slotName,
  });

  Future<List<ModelMutation<I>>> read(I id);

  Future<List<ModelMutation<I>>> readAll();
}

final class SqlMutationStore<I extends ModelId> implements MutationStore<I> {
  const SqlMutationStore({
    required this.database,
    required this.schema,
    this.codec = const LocalValueCodec(),
  });

  final LocalDatabaseScope database;
  final ModelSchema<I> schema;

  final LocalValueCodec codec;

  @override
  Future<MutationPosition> append({
    required I id,
    required MutationOperation operation,
    required Map<String, Object?> values,
    required int mutationOrdinal,
    required bool wire,
    String? slotName,
  }) async {
    final next = (await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT COALESCE(MAX(position), -1) + 1 AS position '
            'FROM pending_mutation_operations WHERE mutation_ordinal = ?',
        variables: [mutationOrdinal],
      ),
    )).singleOrNull?['position'];
    if (next is! int) {
      throw StateError('could not allocate ${schema.name} mutation position');
    }
    final result = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT INTO pending_mutation_operations
            (mutation_ordinal, position, slot_name, model, identity_json,
             operation, values_json, is_uplink)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        variables: [
          mutationOrdinal,
          next,
          slotName,
          schema.name,
          codec.encodeIdentity(schema, id),
          operation.name,
          codec.encodeValues(schema, values),
          wire ? 1 : 0,
        ],
      ),
    );
    if (result.affectedRows != 1) {
      throw StateError('could not append ${schema.name} mutation');
    }
    return MutationPosition(
      mutationOrdinal: mutationOrdinal,
      operationPosition: next,
    );
  }

  @override
  Future<List<ModelMutation<I>>> read(I id) async => _decode(
    await _read('model = ? AND identity_json = ?', [
      schema.name,
      codec.encodeIdentity(schema, id),
    ]),
  );

  @override
  Future<List<ModelMutation<I>>> readAll() async =>
      _decode(await _read('model = ?', [schema.name]));

  Future<List<StoredMutationOperation>> _read(
    String predicate,
    List<Object?> variables,
  ) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            '''
          SELECT (SELECT name FROM pending_mutations WHERE ordinal = mutation_ordinal) AS mutation_name,
                 (SELECT version FROM pending_mutations WHERE ordinal = mutation_ordinal) AS mutation_version,
                 mutation_ordinal, position, slot_name, model, identity_json,
                 operation, values_json, is_uplink
          FROM pending_mutation_operations
          WHERE $predicate
          ORDER BY mutation_ordinal, position
        ''',
        variables: variables,
      ),
    );
    return List<StoredMutationOperation>.unmodifiable(
      result.rows.map(storedMutationOperationFromDatabase),
    );
  }

  List<ModelMutation<I>> _decode(List<StoredMutationOperation> rows) {
    final decoded = <ModelMutation<I>>[];
    for (final row in rows) {
      if (row.model != schema.name) {
        throw LocalDataException(
          'expected ${schema.name} mutation, found ${row.model}',
        );
      }
      final operation = MutationOperation.values
          .where((operation) => operation.name == row.operation)
          .firstOrNull;
      if (operation == null) {
        throw LocalDataException(
          'unknown ${schema.name} mutation operation "${row.operation}"',
        );
      }
      decoded.add(
        ModelMutation(
          position: row.order,
          id: codec.decodeIdentity(schema, row.identityJson),
          operation: operation,
          values: codec.decodeValues(schema, row.valuesJson),
          wire: row.isUplink,
        ),
      );
    }
    decoded.sort((left, right) => left.position.compareTo(right.position));
    return List.unmodifiable(decoded);
  }
}

StoredMutationOperation storedMutationOperationFromDatabase(DatabaseRow row) =>
    StoredMutationOperation(
      mutationOrdinal: row['mutation_ordinal']! as int,
      mutationName: row['mutation_name'] as String?,
      mutationVersion: row['mutation_version'] as int?,
      position: row['position']! as int,
      slotName: row['slot_name'] as String?,
      model: row['model']! as String,
      identityJson: row['identity_json']! as String,
      operation: row['operation']! as String,
      valuesJson: row['values_json']! as String,
      isUplink: (row['is_uplink']! as int) != 0,
    );

Future<List<StoredMutationOperation>> readStoredMutationOperations(
  LocalDatabaseScope database,
  int mutationOrdinal,
) async {
  final result = await database.current.query(
    DatabaseQuery(
      sql: '''
        SELECT (SELECT name FROM pending_mutations WHERE ordinal = mutation_ordinal) AS mutation_name,
                 (SELECT version FROM pending_mutations WHERE ordinal = mutation_ordinal) AS mutation_version,
                 mutation_ordinal, position, slot_name, model, identity_json,
               operation, values_json, is_uplink
        FROM pending_mutation_operations
        WHERE mutation_ordinal = ?
        ORDER BY position
      ''',
      variables: [mutationOrdinal],
    ),
  );
  return List.unmodifiable(
    result.rows.map(storedMutationOperationFromDatabase),
  );
}

Future<void> insertStoredMutationSequences(
  LocalDatabaseScope database,
  int mutationOrdinal,
  Iterable<StoredMutationSequence> sequences,
) async {
  for (final sequence in sequences) {
    if (sequence.mutationOrdinal != mutationOrdinal) {
      throw ArgumentError('sequence belongs to another mutation');
    }
    final result = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT OR IGNORE INTO pending_mutation_sequences
            (mutation_ordinal, predecessor_ordinal)
          VALUES (?, ?)
        ''',
        variables: [sequence.mutationOrdinal, sequence.predecessorOrdinal],
      ),
    );
    if (result.affectedRows != 0 && result.affectedRows != 1) {
      throw StateError('could not store mutation sequence fact');
    }
  }
}

Future<void> insertStoredMutationPrerequisites(
  LocalDatabaseScope database,
  int mutationOrdinal,
  Iterable<StoredMutationPrerequisite> prerequisites,
) async {
  for (final prerequisite in prerequisites) {
    if (prerequisite.mutationOrdinal != mutationOrdinal) {
      throw ArgumentError('prerequisite belongs to another mutation');
    }
    final result = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT OR IGNORE INTO pending_mutation_prerequisites
            (mutation_ordinal, prerequisite_ordinal)
          VALUES (?, ?)
        ''',
        variables: [
          prerequisite.mutationOrdinal,
          prerequisite.prerequisiteOrdinal,
        ],
      ),
    );
    if (result.affectedRows != 0 && result.affectedRows != 1) {
      throw StateError('could not store mutation prerequisite');
    }
  }
}
