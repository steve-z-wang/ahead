import 'dart:typed_data';

import 'database_exception.dart';
import 'database_value.dart';

abstract interface class DatabaseRow {
  Object? operator [](String column);

  Object? valueAt(int index);
}

final class DatabaseQueryResult {
  DatabaseQueryResult({
    required Iterable<String> columns,
    required Iterable<Iterable<Object?>> rows,
  }) : columns = List<String>.unmodifiable(columns),
       rows = _buildRows(columns, rows);

  final List<String> columns;
  final List<DatabaseRow> rows;

  bool get isEmpty => rows.isEmpty;

  int get length => rows.length;

  DatabaseRow operator [](int index) => rows[index];

  DatabaseRow? get singleOrNull {
    if (rows.isEmpty) return null;
    if (rows.length == 1) return rows.single;
    throw const DatabaseException(
      kind: DatabaseErrorKind.invalidArgument,
      message: 'expected zero or one database row',
    );
  }

  static List<DatabaseRow> _buildRows(
    Iterable<String> sourceColumns,
    Iterable<Iterable<Object?>> sourceRows,
  ) {
    final columns = List<String>.unmodifiable(sourceColumns);
    if (columns.toSet().length != columns.length) {
      throw const DatabaseException(
        kind: DatabaseErrorKind.invalidArgument,
        message: 'database result contains duplicate column names',
      );
    }
    final indexes = <String, int>{
      for (var index = 0; index < columns.length; index++)
        columns[index]: index,
    };
    return List<DatabaseRow>.unmodifiable(
      sourceRows.map((row) {
        final values = immutableDatabaseValues(row);
        if (values.length != columns.length) {
          throw const DatabaseException(
            kind: DatabaseErrorKind.invalidArgument,
            message: 'database row width does not match its columns',
          );
        }
        return _MaterializedDatabaseRow(indexes, values);
      }),
    );
  }
}

final class DatabaseExecutionResult {
  const DatabaseExecutionResult({
    required this.affectedRows,
    this.lastInsertRowId,
  });

  final int affectedRows;
  final int? lastInsertRowId;
}

final class _MaterializedDatabaseRow implements DatabaseRow {
  const _MaterializedDatabaseRow(this._indexes, this._values);

  final Map<String, int> _indexes;
  final List<Object?> _values;

  @override
  Object? operator [](String column) {
    final index = _indexes[column];
    if (index == null) {
      throw DatabaseException(
        kind: DatabaseErrorKind.invalidArgument,
        message: 'unknown database column "$column"',
      );
    }
    return _copyIfBytes(_values[index]);
  }

  @override
  Object? valueAt(int index) {
    if (index < 0 || index >= _values.length) {
      throw DatabaseException(
        kind: DatabaseErrorKind.invalidArgument,
        message: 'database column index $index is out of range',
      );
    }
    return _copyIfBytes(_values[index]);
  }

  Object? _copyIfBytes(Object? value) =>
      value is Uint8List ? Uint8List.fromList(value) : value;
}
