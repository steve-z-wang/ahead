import 'package:local_sync_database/local_sync_database.dart';

import '../projection/model_record.dart';
import '../schema/model_id.dart';
import '../schema/model_schema.dart';
import 'database_scope.dart';
import 'local_value_codec.dart';
import 'model_database_descriptor.dart';

final class LocalStorageException implements Exception {
  const LocalStorageException(this.message);

  final String message;

  @override
  String toString() => 'LocalStorageException: $message';
}

abstract interface class CanonicalStore<I extends ModelId> {
  Future<ModelRecord<I>?> get(I id);
  Future<List<ModelRecord<I>>> readAll();

  /// Identities of the rows whose [fieldValues] all match.
  ///
  /// Reads identity columns only: the cascade walk needs to know which rows
  /// hang off a parent, never what is in them.
  Future<List<I>> identitiesMatching(Map<String, Object?> fieldValues);
  Future<void> create(I id, Map<String, Object?> values);
  Future<void> upsert(I id, Map<String, Object?> values);
  Future<void> update(I id, Map<String, Object?> patch);
  Future<void> delete(I id);
  Future<void> purge(I id);
}

final class SqlCanonicalStore<I extends ModelId> implements CanonicalStore<I> {
  const SqlCanonicalStore({
    required this.database,
    required this.descriptor,
    this.codec = const LocalValueCodec(),
  });

  final LocalDatabaseScope database;
  final ModelDatabaseDescriptor<I> descriptor;
  final LocalValueCodec codec;

  ModelSchema<I> get schema => descriptor.schema;

  @override
  Future<ModelRecord<I>?> get(I id) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT ${_selectedColumns()} FROM ${_table()} '
            'WHERE ${_identityPredicate()}',
        variables: _identityValues(id),
      ),
    );
    final row = result.singleOrNull;
    return row == null ? null : _decode(row);
  }

  @override
  Future<List<ModelRecord<I>>> readAll() async {
    final result = await database.current.query(
      DatabaseQuery(sql: 'SELECT ${_selectedColumns()} FROM ${_table()}'),
    );
    return List<ModelRecord<I>>.unmodifiable(result.rows.map(_decode));
  }

  @override
  Future<List<I>> identitiesMatching(Map<String, Object?> fieldValues) async {
    if (fieldValues.isEmpty) {
      throw LocalStorageException('${schema.name} match has no fields');
    }
    final predicates = <String>[];
    final variables = <Object?>[];
    for (final entry in fieldValues.entries) {
      final field = schema.fieldsByName[entry.key];
      if (field == null) {
        throw LocalStorageException(
          '${schema.name} has no field "${entry.key}"',
        );
      }
      if (entry.value == null) {
        predicates.add('${_column(field.name)} IS NULL');
      } else {
        predicates.add('${_column(field.name)} = ?');
        variables.add(codec.encodeSqlValue(field, entry.value));
      }
    }
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT ${schema.identity.map(_column).join(', ')} '
            'FROM ${_table()} WHERE ${predicates.join(' AND ')}',
        variables: variables,
      ),
    );
    return List<I>.unmodifiable(result.rows.map(_decodeIdentity));
  }

  @override
  Future<void> create(I id, Map<String, Object?> values) async {
    final materialized = _materialize(id, values);
    final fields = schema.fields;
    await database.current.execute(
      DatabaseStatement(
        sql:
            'INSERT INTO ${_table()} '
            '(${fields.map((field) => _column(field.name)).join(', ')}) '
            'VALUES (${List.filled(fields.length, '?').join(', ')})',
        variables: _recordValues(materialized),
      ),
    );
  }

  @override
  Future<void> upsert(I id, Map<String, Object?> values) async {
    final materialized = _materialize(id, values);
    final fields = schema.fields;
    final mutable = fields
        .where((field) => !schema.isIdentityField(field.name))
        .toList();
    // A Model that is nothing but its identity has nothing to update: the row
    // either exists or does not, and its presence is the whole of its state.
    // `DO UPDATE SET` with no assignment is not SQL.
    final resolution = mutable.isEmpty
        ? 'DO NOTHING'
        : 'DO UPDATE SET '
              '${mutable.map((field) {
                final column = _column(field.name);
                return '$column = excluded.$column';
              }).join(', ')}';
    await database.current.execute(
      DatabaseStatement(
        sql:
            'INSERT INTO ${_table()} '
            '(${fields.map((field) => _column(field.name)).join(', ')}) '
            'VALUES (${List.filled(fields.length, '?').join(', ')}) '
            'ON CONFLICT '
            '(${schema.identity.map(_column).join(', ')}) $resolution',
        variables: _recordValues(materialized),
      ),
    );
  }

  @override
  Future<void> update(I id, Map<String, Object?> patch) async {
    if (patch.isEmpty) {
      throw LocalStorageException('${schema.name} canonical patch is empty');
    }
    final normalized = codec.decodeValues(
      schema,
      codec.encodeValues(schema, patch),
    );
    final result = await database.current.execute(
      DatabaseStatement(
        sql:
            'UPDATE ${_table()} SET '
            '${normalized.keys.map((field) => '${_column(field)} = ?').join(', ')} '
            'WHERE ${_identityPredicate()}',
        variables: [
          for (final entry in normalized.entries)
            codec.encodeSqlValue(schema.fieldsByName[entry.key]!, entry.value),
          ..._identityValues(id),
        ],
      ),
    );
    _requireOne(result.affectedRows, 'update');
  }

  @override
  Future<void> delete(I id) async {
    final result = await _delete(id);
    _requireOne(result.affectedRows, 'delete');
  }

  @override
  Future<void> purge(I id) async {
    await _delete(id);
  }

  Future<DatabaseExecutionResult> _delete(I id) => database.current.execute(
    DatabaseStatement(
      sql: 'DELETE FROM ${_table()} WHERE ${_identityPredicate()}',
      variables: _identityValues(id),
    ),
  );

  ModelRecord<I> _materialize(I id, Map<String, Object?> values) {
    codec.encodeIdentity(schema, id);
    final normalized = codec.decodeValues(
      schema,
      codec.encodeValues(schema, values),
    );
    final complete = <String, Object?>{};
    for (final field in schema.fields) {
      if (schema.isIdentityField(field.name)) continue;
      if (normalized.containsKey(field.name)) {
        complete[field.name] = normalized[field.name];
      } else if (field.nullable) {
        complete[field.name] = null;
      } else {
        throw LocalStorageException(
          'create is missing required ${schema.name}.${field.name}',
        );
      }
    }
    return ModelRecord(id: id, fields: complete);
  }

  List<Object?> _recordValues(ModelRecord<I> record) => [
    for (final field in schema.fields)
      codec.encodeSqlValue(
        field,
        schema.isIdentityField(field.name)
            ? record.id.components[field.name]
            : record.fields[field.name],
      ),
  ];

  ModelRecord<I> _decode(DatabaseRow row) {
    final components = <String, Object>{};
    final values = <String, Object?>{};
    for (final field in schema.fields) {
      final decoded = codec.decodeSqlValue(
        field,
        row[descriptor.column(field.name)],
      );
      if (schema.isIdentityField(field.name)) {
        components[field.name] = decoded!;
      } else {
        values[field.name] = decoded;
      }
    }
    return ModelRecord(
      id: schema.createId(Map.unmodifiable(components)),
      fields: values,
    );
  }

  I _decodeIdentity(DatabaseRow row) => schema.createId(
    Map.unmodifiable({
      for (final field in schema.identity)
        field: codec.decodeSqlValue(
          schema.fieldsByName[field]!,
          row[descriptor.column(field)],
        )!,
    }),
  );

  List<Object?> _identityValues(I id) => [
    for (final field in schema.identity)
      codec.encodeSqlValue(schema.fieldsByName[field]!, id.components[field]),
  ];

  String _selectedColumns() =>
      schema.fields.map((field) => _column(field.name)).join(', ');
  String _identityPredicate() =>
      schema.identity.map((field) => '${_column(field)} = ?').join(' AND ');
  String _table() => quoteSqlIdentifier(descriptor.tableName);
  String _column(String field) => quoteSqlIdentifier(descriptor.column(field));

  void _requireOne(int affected, String operation) {
    if (affected != 1) {
      throw LocalStorageException(
        'expected one ${schema.name} $operation, affected $affected',
      );
    }
  }
}
