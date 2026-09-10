import '../mutation/model_mutation.dart';
import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import '../storage/local_value_codec.dart';
import 'model_record.dart';

final class ProjectionIntegrityException implements Exception {
  const ProjectionIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'ProjectionIntegrityException: $message';
}

abstract interface class ProjectionReducer<I extends ModelId> {
  ModelRecord<I>? reduce(
    ModelRecord<I>? canonical,
    List<ModelMutation<I>> mutations,
  );
}

final class MutationReducer<I extends ModelId> implements ProjectionReducer<I> {
  const MutationReducer(this.schema, {this.codec = const LocalValueCodec()});

  final ModelSchema<I> schema;
  final LocalValueCodec codec;

  ModelRecord<I>? reduce(
    ModelRecord<I>? canonical,
    List<ModelMutation<I>> mutations,
  ) {
    var current = canonical == null
        ? null
        : ModelRecord<I>(
            id: canonical.id,
            fields: _complete(canonical.fields, context: 'canonical record'),
          );
    MutationPosition? previousPosition;
    final ordered = List<ModelMutation<I>>.of(mutations)
      ..sort((left, right) => left.position.compareTo(right.position));

    for (final mutation in ordered) {
      if (mutation.position.mutationOrdinal <= 0 ||
          mutation.position.operationPosition < 0 ||
          mutation.position == previousPosition) {
        throw ProjectionIntegrityException(
          'invalid or duplicate mutation position ${mutation.position}',
        );
      }
      previousPosition = mutation.position;
      if (mutation.id != (current?.id ?? mutation.id)) {
        throw ProjectionIntegrityException(
          '${schema.name} mutation identity does not match its record',
        );
      }
      try {
        switch (mutation.operation) {
          case MutationOperation.create:
            if (current != null) {
              throw ProjectionIntegrityException(
                'cannot create existing ${schema.name}',
              );
            }
            current = ModelRecord<I>(
              id: mutation.id,
              fields: _complete(mutation.values, context: 'create'),
            );
          case MutationOperation.update:
            if (current == null) {
              throw ProjectionIntegrityException(
                'cannot update absent ${schema.name}',
              );
            }
            if (mutation.values.isEmpty) {
              throw ProjectionIntegrityException(
                '${schema.name} update patch cannot be empty',
              );
            }
            final patch = _normalize(mutation.values);
            current = ModelRecord<I>(
              id: current.id,
              fields: {...current.fields, ...patch},
            );
          case MutationOperation.delete:
            if (current == null) {
              // A delete inherited from an ancestor is absorbing: the row it
              // names may already have been deleted in its own right, and the
              // cascade has nothing left to take.
              if (mutation.inherited) break;
              throw ProjectionIntegrityException(
                'cannot delete absent ${schema.name}',
              );
            }
            if (mutation.values.isNotEmpty) {
              throw ProjectionIntegrityException(
                '${schema.name} delete values must be empty',
              );
            }
            // The row is gone, and may be created again: the writer allows
            // exactly that, since the main table has no row to collide with.
            current = null;
        }
      } on LocalDataException catch (error) {
        throw ProjectionIntegrityException(error.message);
      }
    }
    return current;
  }

  Map<String, Object?> _normalize(Map<String, Object?> values) {
    final encoded = codec.encodeValues(schema, values);
    return codec.decodeValues(schema, encoded);
  }

  Map<String, Object?> _complete(
    Map<String, Object?> values, {
    required String context,
  }) {
    final normalized = _normalize(values);
    final complete = <String, Object?>{};
    for (final field in schema.fields) {
      if (schema.isIdentityField(field.name)) continue;
      if (normalized.containsKey(field.name)) {
        complete[field.name] = normalized[field.name];
      } else if (field.nullable) {
        complete[field.name] = null;
      } else {
        throw ProjectionIntegrityException(
          '$context is missing required ${schema.name}.${field.name}',
        );
      }
    }
    return Map.unmodifiable(complete);
  }
}
