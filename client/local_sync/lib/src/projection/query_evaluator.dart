import 'package:uuid/uuid_value.dart';

import '../api/model_query.dart';
import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import 'model_record.dart';
import 'mutation_reducer.dart';
import '../storage/local_value_codec.dart';

final class QueryEvaluator<I extends ModelId> {
  const QueryEvaluator(this.schema);

  final ModelSchema<I> schema;

  List<ModelRecord<I>> evaluate(
    Iterable<ModelRecord<I>> records,
    ProjectionQuery<I> query,
  ) {
    final limit = query.limit;
    if (limit != null && limit < 0) {
      throw ArgumentError.value(limit, 'limit', 'must not be negative');
    }
    final result = records
        .where(
          (record) => query.predicates.every(
            (predicate) => _matches(record, predicate),
          ),
        )
        .toList();
    result.sort((left, right) {
      for (final order in query.order) {
        final compared = _compareOrder(left, right, order);
        if (compared != 0) return compared;
      }
      return _compareIdentity(left.id, right.id);
    });
    if (limit == null || limit >= result.length) {
      return List.unmodifiable(result);
    }
    return List.unmodifiable(result.take(limit));
  }

  bool _matches(ModelRecord<I> record, ModelPredicate predicate) {
    if (predicate.identity) return record.id == predicate.expected;
    final field = _field(predicate.field!);
    if (field.type is LocalScalarListType) {
      throw ProjectionIntegrityException(
        '${schema.name}.${field.name} does not support query predicates',
      );
    }
    final actual = _fieldValue(record, field.name);
    _assertValue(field, predicate.expected);
    if (actual is DateTime && predicate.expected is DateTime) {
      return actual.toUtc().isAtSameMomentAs(
        (predicate.expected! as DateTime).toUtc(),
      );
    }
    return actual == predicate.expected;
  }

  int _compareOrder(
    ModelRecord<I> left,
    ModelRecord<I> right,
    ModelOrder order,
  ) {
    final compared = order.identity
        ? _compareIdentity(left.id, right.id)
        : _compareField(
            _field(order.field!),
            _fieldValue(left, order.field!),
            _fieldValue(right, order.field!),
          );
    return order.direction == ModelOrderDirection.ascending
        ? compared
        : -compared;
  }

  int _compareIdentity(I left, I right) {
    for (final name in schema.identity) {
      final field = _field(name);
      final compared = _compareField(
        field,
        left.components[name],
        right.components[name],
      );
      if (compared != 0) return compared;
    }
    return 0;
  }

  ModelFieldSchema _field(String name) {
    final field = schema.fieldsByName[name];
    if (field == null) {
      throw ProjectionIntegrityException(
        'unknown ${schema.name} query field "$name"',
      );
    }
    return field;
  }

  Object? _fieldValue(ModelRecord<I> record, String name) {
    if (schema.isIdentityField(name)) return record.id.components[name];
    if (!record.fields.containsKey(name)) {
      throw ProjectionIntegrityException(
        '${schema.name} record is missing field "$name"',
      );
    }
    return record.fields[name];
  }

  int _compareField(ModelFieldSchema field, Object? left, Object? right) {
    _assertValue(field, left);
    _assertValue(field, right);
    if (left == null) return right == null ? 0 : -1;
    if (right == null) return 1;
    final type = field.type;
    if (type is LocalEnumType) {
      throw ProjectionIntegrityException(
        '${schema.name}.${field.name} does not support ordering',
      );
    }
    if (type is LocalScalarListType) {
      throw ProjectionIntegrityException(
        '${schema.name}.${field.name} does not support ordering',
      );
    }
    return switch (type as LocalScalarType) {
      LocalScalarType.string => (left as String).compareTo(right as String),
      LocalScalarType.boolean => _compareBool(left as bool, right as bool),
      LocalScalarType.int => (left as int).compareTo(right as int),
      LocalScalarType.float => (left as num).compareTo(right as num),
      LocalScalarType.dateTime => (left as DateTime).toUtc().compareTo(
        (right as DateTime).toUtc(),
      ),
      LocalScalarType.uuid => (left as UuidValue).uuid.compareTo(
        (right as UuidValue).uuid,
      ),
    };
  }

  int _compareBool(bool left, bool right) {
    if (left == right) return 0;
    return left ? 1 : -1;
  }

  void _assertValue(ModelFieldSchema field, Object? value) {
    if (value == null) {
      if (field.nullable) return;
      throw ProjectionIntegrityException(
        '${schema.name}.${field.name} cannot be null',
      );
    }
    try {
      const LocalValueCodec().encodeJsonValue(
        field,
        value,
        allowNull: field.nullable,
      );
    } on LocalDataException {
      throw ProjectionIntegrityException(
        '${schema.name}.${field.name} has the wrong value',
      );
    }
  }
}
