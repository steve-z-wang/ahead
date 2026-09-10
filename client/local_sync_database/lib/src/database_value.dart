import 'dart:typed_data';

import 'database_exception.dart';

List<Object?> immutableDatabaseValues(Iterable<Object?> values) =>
    List<Object?>.unmodifiable(values.map(immutableDatabaseValue));

Object? immutableDatabaseValue(Object? value) {
  if (value == null || value is String) return value;
  if (value is int) return value;
  if (value is double && value.isFinite) return value;
  if (value is Uint8List) return Uint8List.fromList(value);
  throw DatabaseException(
    kind: DatabaseErrorKind.invalidArgument,
    message: 'unsupported SQLite value ${value.runtimeType}',
  );
}
