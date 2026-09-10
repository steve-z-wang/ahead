import 'package:local_sync_database/local_sync_database.dart';

import '../projection/model_record.dart';
import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../schema/model_schema.dart';
import '../storage/database_scope.dart';
import '../storage/local_value_codec.dart';
import 'model_operation.dart';
import 'mutation_store.dart';

final class AppliedMutationOperation {
  const AppliedMutationOperation({
    required this.operation,
    required this.before,
    required this.after,
  });

  final ModelOperation operation;
  final ModelRecord<ModelId>? before;
  final ModelRecord<ModelId>? after;
}

/// Freezes the exact earlier Mutation ordinals this act depends on.
///
/// Row identities exist only while this method matches concrete queue rows.
/// The durable scheduling inputs are the two ordinal pairs written at the end:
/// lifecycle prerequisites and self/product sequence predecessors.
final class MutationDependencyWriter {
  const MutationDependencyWriter({
    required this.database,
    required this.registry,
    this.codec = const LocalValueCodec(),
  });

  final LocalDatabaseScope database;
  final ModelRegistry registry;
  final LocalValueCodec codec;

  Future<void> freeze({
    required int mutationOrdinal,
    required MutationRecord record,
    required Iterable<AppliedMutationOperation> appliedOperations,
  }) async {
    final current = await readStoredMutationOperations(
      database,
      mutationOrdinal,
    );
    final earlier = await _readEarlierActive(mutationOrdinal);
    final sequenceOrdinals = <int>{};
    final prerequisiteOrdinals = <int>{};

    final currentRows = {
      for (final operation in appliedOperations) operation.operation: operation,
    };

    for (final operation in current) {
      for (final candidate in earlier) {
        if (candidate.operation.model == operation.model &&
            candidate.operation.identityJson == operation.identityJson) {
          sequenceOrdinals.add(candidate.operation.mutationOrdinal);
        }
      }
    }

    for (final applied in currentRows.values) {
      if (applied.operation is ModelDeleteOperation || applied.after == null) {
        continue;
      }
      final source = registry[applied.operation.model];
      if (source == null) {
        throw StateError('unknown Model "${applied.operation.model}"');
      }
      for (final relation in source.schema.relations) {
        final target = _relationTarget(
          source: source,
          sourceId: applied.operation.id,
          sourceFields: applied.after!.fields,
          relation: relation,
        );
        if (target == null) continue;
        for (final candidate in earlier) {
          if (candidate.operation.isUplink &&
              candidate.operation.operation == 'create' &&
              candidate.operation.model == target.model &&
              candidate.operation.identityJson == target.identityJson) {
            prerequisiteOrdinals.add(candidate.operation.mutationOrdinal);
          }
        }
      }
    }

    for (final selector in record.sequenceSelectors) {
      final currentEndpoints = <_Node>{};
      for (final path in selector.currentPaths) {
        final applied = currentRows[path.source];
        if (applied == null) {
          throw ArgumentError(
            'mutation "${record.name}" has a sequence path for an operation '
            'outside its returned slots',
          );
        }
        currentEndpoints.addAll(
          await _currentEndpoints(applied, path.relations),
        );
      }
      if (currentEndpoints.isEmpty) continue;

      final endpointsByOrdinal = <int, Set<_Node>>{};
      for (final candidate in earlier) {
        if (candidate.name != selector.predecessorMutation ||
            candidate.operation.slotName != selector.predecessorSlot ||
            !candidate.operation.isUplink) {
          continue;
        }
        final endpoint = _predecessorEndpoint(
          candidate.operation,
          selector.predecessorRelations,
        );
        if (endpoint != null) {
          (endpointsByOrdinal[candidate.operation.mutationOrdinal] ??= {}).add(
            endpoint,
          );
        }
      }
      for (final entry in endpointsByOrdinal.entries) {
        if (entry.value.any(currentEndpoints.contains)) {
          sequenceOrdinals.add(entry.key);
        }
      }
    }

    await insertStoredMutationSequences(database, mutationOrdinal, [
      for (final predecessor in sequenceOrdinals)
        StoredMutationSequence(
          mutationOrdinal: mutationOrdinal,
          predecessorOrdinal: predecessor,
        ),
    ]);
    await insertStoredMutationPrerequisites(database, mutationOrdinal, [
      for (final prerequisite in prerequisiteOrdinals)
        StoredMutationPrerequisite(
          mutationOrdinal: mutationOrdinal,
          prerequisiteOrdinal: prerequisite,
        ),
    ]);
  }

  Future<List<_EarlierOperation>> _readEarlierActive(int ordinal) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql: '''
          SELECT parent.name, parent.name AS mutation_name,
                 parent.version AS mutation_version,
                 operation.mutation_ordinal, operation.position,
                 operation.slot_name, operation.model,
                 operation.identity_json, operation.operation,
                 operation.values_json, operation.is_uplink
          FROM pending_mutation_operations AS operation
          JOIN pending_mutations AS parent
            ON parent.ordinal = operation.mutation_ordinal
          LEFT JOIN uplink_batches AS batch
            ON batch.sequence = parent.batch_sequence
          WHERE parent.ordinal < ?
            AND (parent.batch_sequence IS NULL
                 OR batch.required_sync_id IS NULL)
          ORDER BY parent.ordinal, operation.position
        ''',
        variables: [ordinal],
      ),
    );
    return [
      for (final row in result.rows)
        _EarlierOperation(
          name: row['name']! as String,
          operation: storedMutationOperationFromDatabase(row),
        ),
    ];
  }

  Future<Set<_Node>> _currentEndpoints(
    AppliedMutationOperation applied,
    List<String> relations,
  ) async {
    if (relations.isEmpty) {
      return {_node(applied.operation.model, applied.operation.id)};
    }
    final snapshots = switch (applied.operation) {
      ModelCreateOperation() => [applied.after],
      ModelUpdateOperation() => [applied.before, applied.after],
      ModelDeleteOperation() => [applied.before],
    };
    final result = <_Node>{};
    for (final snapshot in snapshots.whereType<ModelRecord<ModelId>>()) {
      final endpoint = await _walkCurrent(
        sourceModel: applied.operation.model,
        sourceId: applied.operation.id,
        sourceFields: snapshot.fields,
        relations: relations,
      );
      if (endpoint != null) result.add(endpoint);
    }
    return result;
  }

  Future<_Node?> _walkCurrent({
    required String sourceModel,
    required ModelId sourceId,
    required Map<String, Object?> sourceFields,
    required List<String> relations,
  }) async {
    final sourceEntry = registry[sourceModel];
    if (sourceEntry == null) throw StateError('unknown Model "$sourceModel"');
    ModelRegistryEntry entry = sourceEntry;
    var id = sourceId;
    var fields = sourceFields;
    for (var index = 0; index < relations.length; index += 1) {
      final relation = entry.schema.relations
          .where((candidate) => candidate.name == relations[index])
          .singleOrNull;
      if (relation == null) {
        throw StateError(
          '${entry.schema.name} has no singular relation '
          '"${relations[index]}"',
        );
      }
      final target = _relationTarget(
        source: entry,
        sourceId: id,
        sourceFields: fields,
        relation: relation,
      );
      if (target == null) return null;
      if (index == relations.length - 1) return target;
      final targetEntry = registry[target.model];
      if (targetEntry == null) {
        throw StateError('unknown Model "${target.model}"');
      }
      entry = targetEntry;
      id = codec.decodeIdentity(entry.schema, target.identityJson);
      final row = await entry.readMain(id);
      if (row == null) return null;
      fields = row.fields;
    }
    return null;
  }

  _Node? _predecessorEndpoint(
    StoredMutationOperation operation,
    List<String> relations,
  ) {
    final entry = registry[operation.model];
    if (entry == null) throw StateError('unknown Model "${operation.model}"');
    final id = codec.decodeIdentity(entry.schema, operation.identityJson);
    if (relations.isEmpty) return _node(operation.model, id);
    if (relations.length != 1) {
      throw StateError('predecessor sequence paths may have one relation');
    }
    final relation = entry.schema.relations
        .where((candidate) => candidate.name == relations.single)
        .singleOrNull;
    if (relation == null) {
      throw StateError(
        '${entry.schema.name} has no singular relation "${relations.single}"',
      );
    }
    return _relationTarget(
      source: entry,
      sourceId: id,
      sourceFields: codec.decodeValues(entry.schema, operation.valuesJson),
      relation: relation,
    );
  }

  _Node? _relationTarget({
    required ModelRegistryEntry source,
    required ModelId sourceId,
    required Map<String, Object?> sourceFields,
    required ModelRelationSchema relation,
  }) {
    final target = registry[relation.targetModel];
    if (target == null) {
      throw StateError('unknown Model "${relation.targetModel}"');
    }
    final row = <String, Object?>{...sourceId.components, ...sourceFields};
    final components = <String, Object>{};
    for (var index = 0; index < relation.localFields.length; index += 1) {
      final value = row[relation.localFields[index]];
      if (value == null) return null;
      components[relation.referencedFields[index]] = value;
    }
    return _node(target.schema.name, target.schema.createIdentity(components));
  }

  _Node _node(String model, ModelId id) {
    final entry = registry[model];
    if (entry == null) throw StateError('unknown Model "$model"');
    return _Node(model, codec.encodeIdentity(entry.schema, id));
  }
}

final class _EarlierOperation {
  const _EarlierOperation({required this.name, required this.operation});

  final String name;
  final StoredMutationOperation operation;
}

final class _Node {
  const _Node(this.model, this.identityJson);

  final String model;
  final String identityJson;

  @override
  bool operator ==(Object other) =>
      other is _Node &&
      other.model == model &&
      other.identityJson == identityJson;

  @override
  int get hashCode => Object.hash(model, identityJson);
}
