import 'dart:collection';
import 'dart:convert';

import 'package:uuid/uuid_value.dart';

import '../schema/model_id.dart';
import '../schema/model_schema.dart';

const _maxSafeInteger = 9007199254740991;
final _utcDateTime = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$',
);

final class LocalDataException implements FormatException {
  const LocalDataException(this.message, [this.source, this.offset]);

  @override
  final String message;

  @override
  final Object? source;

  @override
  final int? offset;

  @override
  String toString() => 'LocalDataException: $message';
}

final class LocalValueCodec {
  const LocalValueCodec();

  Object? encodeJsonValue(
    ModelFieldSchema field,
    Object? value, {
    required bool allowNull,
  }) => _encodeValue(field, value, allowNull: allowNull);

  Object? decodeJsonValue(
    ModelFieldSchema field,
    Object? value, {
    required bool allowNull,
  }) => _decodeValue(field, value, allowNull: allowNull);

  String encodeTextStorage(ModelFieldSchema field, Object value) {
    final type = field.type;
    if (type is! LocalEnumType && type is! LocalScalarListType) {
      throw StateError('field "${field.name}" is not text-storage encoded');
    }
    final encoded = _encodeValue(field, value, allowNull: false);
    return type is LocalEnumType ? encoded! as String : jsonEncode(encoded);
  }

  T decodeTextStorage<T>(ModelFieldSchema field, String source) {
    if (field.type is! LocalEnumType) {
      throw StateError('field "${field.name}" is not an enum');
    }
    final decoded = _decodeValue(field, source, allowNull: false);
    if (decoded is! T) {
      throw LocalDataException(
        'field "${field.name}" has the wrong decoded value',
        source,
      );
    }
    return decoded;
  }

  Object? encodeSqlValue(ModelFieldSchema field, Object? value) {
    final encoded = _encodeValue(field, value, allowNull: field.nullable);
    if (encoded == null) return null;
    final type = field.type;
    if (type == LocalScalarType.boolean) return (encoded as bool) ? 1 : 0;
    if (type is LocalScalarListType) return jsonEncode(encoded);
    return encoded;
  }

  Object? decodeSqlValue(ModelFieldSchema field, Object? value) {
    if (value == null) {
      return _decodeValue(field, null, allowNull: field.nullable);
    }
    final type = field.type;
    final encoded = switch (type) {
      LocalScalarType.boolean when value == 0 => false,
      LocalScalarType.boolean when value == 1 => true,
      LocalScalarListType() when value is String => _decodeStoredJsonValue(
        field,
        value,
      ),
      _ => value,
    };
    return _decodeValue(field, encoded, allowNull: field.nullable);
  }

  List<T> decodeListTextStorage<T>(ModelFieldSchema field, String source) {
    if (field.type is! LocalScalarListType) {
      throw StateError('field "${field.name}" is not a scalar list');
    }
    final decoded = _decodeStoredJson(field, source);
    if (decoded is! List) {
      throw LocalDataException(
        'field "${field.name}" has the wrong decoded value',
        source,
      );
    }
    try {
      return List<T>.unmodifiable(decoded.cast<T>());
    } on TypeError {
      throw LocalDataException(
        'field "${field.name}" has the wrong decoded value',
        source,
      );
    }
  }

  String encodeIdentity<I extends ModelId>(ModelSchema<I> schema, ModelId id) {
    final components = id.components;
    if (components.length != schema.identity.length ||
        !schema.identity.every(components.containsKey)) {
      throw LocalDataException('invalid ${schema.name} identity components');
    }
    final encoded = <String, Object?>{};
    for (final name in schema.identity) {
      encoded[name] = _encodeValue(
        schema.fieldsByName[name]!,
        components[name],
        allowNull: false,
      );
    }
    return _canonicalJson(encoded);
  }

  I decodeIdentity<I extends ModelId>(ModelSchema<I> schema, String json) {
    final object = _decodeObject(json);
    if (object.length != schema.identity.length ||
        !schema.identity.every(object.containsKey)) {
      throw LocalDataException('invalid ${schema.name} identity JSON', json);
    }
    final components = <String, Object>{};
    for (final name in schema.identity) {
      final decoded = _decodeValue(
        schema.fieldsByName[name]!,
        object[name],
        allowNull: false,
      );
      components[name] = decoded!;
    }
    try {
      return schema.createId(Map.unmodifiable(components));
    } on LocalDataException {
      rethrow;
    } catch (error) {
      throw LocalDataException(
        'could not construct ${schema.name} identity: $error',
        json,
      );
    }
  }

  String encodeValues<I extends ModelId>(
    ModelSchema<I> schema,
    Map<String, Object?> values,
  ) {
    final encoded = <String, Object?>{};
    for (final entry in values.entries) {
      final field = _valueField(schema, entry.key);
      encoded[entry.key] = _encodeValue(
        field,
        entry.value,
        allowNull: field.nullable,
      );
    }
    return _canonicalJson(encoded);
  }

  Map<String, Object?> decodeValues<I extends ModelId>(
    ModelSchema<I> schema,
    String json,
  ) {
    final object = _decodeObject(json);
    final decoded = <String, Object?>{};
    for (final entry in object.entries) {
      final field = _valueField(schema, entry.key);
      decoded[entry.key] = _decodeValue(
        field,
        entry.value,
        allowNull: field.nullable,
      );
    }
    return Map.unmodifiable(decoded);
  }

  ModelFieldSchema _valueField<I extends ModelId>(
    ModelSchema<I> schema,
    String name,
  ) {
    final field = schema.fieldsByName[name];
    if (field == null) {
      throw LocalDataException('unknown ${schema.name} field "$name"');
    }
    if (schema.isIdentityField(name)) {
      throw LocalDataException(
        '${schema.name} identity field "$name" cannot occur in values',
      );
    }
    return field;
  }

  Map<String, Object?> _decodeObject(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw LocalDataException(error.message, source, error.offset);
    }
    if (decoded is! Map<String, Object?>) {
      throw LocalDataException('expected a JSON object', source);
    }
    return decoded;
  }

  Object _decodeStoredJson(ModelFieldSchema field, String source) {
    final encoded = _decodeStoredJsonValue(field, source);
    final decoded = _decodeValue(field, encoded, allowNull: false);
    if (decoded == null) {
      throw LocalDataException('field "${field.name}" cannot be null', source);
    }
    return decoded;
  }

  Object? _decodeStoredJsonValue(ModelFieldSchema field, String source) {
    final Object? encoded;
    try {
      encoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw LocalDataException(error.message, source, error.offset);
    }
    return encoded;
  }

  String _canonicalJson(Map<String, Object?> values) =>
      jsonEncode(SplayTreeMap<String, Object?>.of(values));

  Object? _encodeValue(
    ModelFieldSchema field,
    Object? value, {
    required bool allowNull,
  }) {
    if (value == null) {
      if (allowNull) return null;
      throw LocalDataException('field "${field.name}" cannot be null');
    }
    final type = field.type;
    if (type is LocalScalarType) {
      return _encodeScalar(field.name, type, value);
    }
    if (type is LocalEnumType) {
      final String wire;
      try {
        wire = type.encode(value);
      } on Object {
        throw LocalDataException(
          'field "${field.name}" has the wrong ${type.name} value',
        );
      }
      if (!type.values.contains(wire)) {
        throw LocalDataException(
          'field "${field.name}" has an unknown ${type.name} value',
        );
      }
      return wire;
    }
    if (type is LocalScalarListType) {
      if (value is! List) {
        throw LocalDataException('field "${field.name}" must be a list');
      }
      return List<Object?>.unmodifiable(
        value.map(
          (element) => _encodeScalar(field.name, type.element, element),
        ),
      );
    }
    throw StateError('unsupported LocalValueType $type');
  }

  Object? _decodeValue(
    ModelFieldSchema field,
    Object? value, {
    required bool allowNull,
  }) {
    if (value == null) {
      if (allowNull) return null;
      throw LocalDataException('field "${field.name}" cannot be null');
    }
    try {
      final type = field.type;
      if (type is LocalScalarType) {
        return _decodeScalar(field.name, type, value);
      }
      if (type is LocalEnumType) {
        if (value is! String || !type.values.contains(value)) {
          throw LocalDataException(
            'field "${field.name}" has an unknown ${type.name} value',
          );
        }
        return type.decode(value);
      }
      if (type is LocalScalarListType) {
        if (value is! List) {
          throw LocalDataException('field "${field.name}" must be a list');
        }
        return List<Object>.unmodifiable(
          value.map((element) {
            final decoded = _decodeScalar(field.name, type.element, element);
            return decoded;
          }),
        );
      }
      throw StateError('unsupported LocalValueType $type');
    } on LocalDataException {
      rethrow;
    } on FormatException catch (error) {
      throw LocalDataException(
        'field "${field.name}" is invalid: ${error.message}',
      );
    }
  }

  Object _encodeScalar(String field, LocalScalarType type, Object value) =>
      switch (type) {
        LocalScalarType.string when value is String => value,
        LocalScalarType.boolean when value is bool => value,
        LocalScalarType.int
            when value is int && value.abs() <= _maxSafeInteger =>
          value,
        LocalScalarType.float when value is double && value.isFinite => value,
        LocalScalarType.float when value is int => value.toDouble(),
        LocalScalarType.dateTime when value is DateTime =>
          value.toUtc().toIso8601String(),
        LocalScalarType.uuid when value is UuidValue => _validatedUuid(value),
        _ => throw LocalDataException(
          'field "$field" has the wrong ${type.name} value',
        ),
      };

  Object _decodeScalar(String field, LocalScalarType type, Object value) =>
      switch (type) {
        LocalScalarType.string when value is String => value,
        LocalScalarType.boolean when value is bool => value,
        LocalScalarType.int
            when value is int && value.abs() <= _maxSafeInteger =>
          value,
        LocalScalarType.float when value is num && value.isFinite =>
          value.toDouble(),
        LocalScalarType.dateTime
            when value is String && _utcDateTime.hasMatch(value) =>
          DateTime.parse(value).toUtc(),
        LocalScalarType.uuid when value is String => UuidValue.withValidation(
          value,
        ),
        _ => throw LocalDataException(
          'field "$field" has the wrong ${type.name} value',
        ),
      };

  String _validatedUuid(UuidValue value) {
    try {
      return UuidValue.withValidation(value.uuid).uuid;
    } on FormatException catch (error) {
      throw LocalDataException('invalid UUID: ${error.message}');
    }
  }
}
