import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../schema/model_schema.dart';
import '../storage/local_value_codec.dart';
import 'downlink_protocol.dart';

final class DecodedModelChange {
  DecodedModelChange({
    required this.syncId,
    required this.entry,
    required this.operation,
    required this.id,
    required Map<String, Object?> values,
  }) : values = Map.unmodifiable(values);

  final int syncId;
  final ModelRegistryEntry entry;
  final DownlinkOperation operation;
  final ModelId id;
  final Map<String, Object?> values;
}

final class ModelChangeDecoder {
  const ModelChangeDecoder(this.registry);

  final ModelRegistry registry;

  DecodedModelChange decode(AddressedModelChange change) {
    final raw = change.raw;
    if (raw['syncId'] != change.syncId) {
      throw const DownlinkDataException(
        'syncId does not match its addressed position',
      );
    }
    final modelName = raw['model'];
    if (modelName is! String || modelName.isEmpty) {
      throw const DownlinkDataException('model must be a non-empty string');
    }
    final entry = registry[modelName];
    if (entry == null) {
      throw DownlinkDataException('unknown Model "$modelName"');
    }
    final schema = entry.schema;
    final operation = _operation(raw['operation']);
    _exactKeys(
      raw,
      operation == DownlinkOperation.delete
          ? const {'syncId', 'model', 'operation', 'id'}
          : const {'syncId', 'model', 'operation', 'id', 'data'},
      '$modelName ${operation.name}',
    );
    final id = _identity(schema, raw['id']);
    final values = operation == DownlinkOperation.upsert
        ? _completeData(schema, raw['data'])
        : const <String, Object?>{};
    return DecodedModelChange(
      syncId: change.syncId,
      entry: entry,
      operation: operation,
      id: id,
      values: values,
    );
  }
}

DownlinkOperation _operation(Object? value) => switch (value) {
  'upsert' => DownlinkOperation.upsert,
  'delete' => DownlinkOperation.delete,
  _ => throw const DownlinkDataException('unknown Downlink operation'),
};

ModelId _identity(ModelSchema<ModelId> schema, Object? input) {
  final raw = _object(input, '${schema.name}.id');
  _exactKeys(raw, schema.identity.toSet(), '${schema.name}.id');
  final components = <String, Object>{};
  for (final name in schema.identity) {
    final field = schema.fieldsByName[name];
    if (field == null) {
      throw StateError('${schema.name} identity field "$name" is missing');
    }
    components[name] = _scalar(field, raw[name], allowNull: false)!;
  }
  try {
    return schema.createIdentity(Map.unmodifiable(components));
  } catch (error) {
    throw DownlinkDataException(
      'could not construct ${schema.name} identity: $error',
    );
  }
}

/// The state of a row, read through THIS client's schema and nothing else.
///
/// **Keys the schema does not declare are dropped, not refused** (CAP-481).
/// The framework's published evolution rule is additive — a field that has
/// once been generated "may gain company and may never leave" — and this used
/// to contradict it with an exact key-set match. One extra key refused the
/// row; a refused row is skipped past forever, because the Downlink cursor
/// advances over it. So adding a nullable field to a Model silently deleted
/// that Model's rows from every build already in the field.
///
/// The tolerance runs both ways, and the second direction is free: a field the
/// schema declares but the payload omits reads as absent, which for a nullable
/// field is simply null. An older server and a newer client therefore work as
/// well as the reverse.
///
/// What did NOT loosen: a **required** field that is missing still throws — a
/// key this client needs and did not get is not a key it does not know. And an
/// identity component sent in the data half is still refused, because that is
/// a payload in the wrong shape rather than a payload from another version;
/// the contract widens in exactly one direction.
Map<String, Object?> _completeData(ModelSchema<ModelId> schema, Object? input) {
  final raw = _object(input, '${schema.name}.data');
  for (final name in schema.identity) {
    if (raw.containsKey(name)) {
      throw DownlinkDataException(
        '${schema.name}.data carries the identity field "$name"',
      );
    }
  }
  final values = <String, Object?>{};
  for (final field in schema.fields) {
    if (schema.isIdentityField(field.name)) continue;
    values[field.name] = _scalar(
      field,
      raw[field.name],
      allowNull: field.nullable,
    );
  }
  return Map.unmodifiable(values);
}

Object? _scalar(
  ModelFieldSchema field,
  Object? value, {
  required bool allowNull,
}) {
  if (value == null) {
    if (allowNull) return null;
    throw DownlinkDataException('field "${field.name}" cannot be null');
  }
  try {
    return const LocalValueCodec().decodeJsonValue(
      field,
      value,
      allowNull: allowNull,
    );
  } on LocalDataException catch (error) {
    throw DownlinkDataException(
      'field "${field.name}" is invalid: ${error.message}',
    );
  }
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map) {
    throw DownlinkDataException('$path must be a JSON object');
  }
  try {
    return value.cast<String, Object?>();
  } on TypeError {
    throw DownlinkDataException('$path must have string keys');
  }
}

void _exactKeys(Map<String, Object?> value, Set<String> keys, String path) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw DownlinkDataException('$path has an invalid key set');
  }
}
