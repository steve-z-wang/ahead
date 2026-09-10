import 'dart:async';

import 'package:local_sync_database/local_sync_database.dart';
import 'package:sqlite3/common.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart' as sqlite;

import 'sqlite_error_mapper.dart';

final class SqliteLocalSyncDatabase implements Database {
  SqliteLocalSyncDatabase(this._connection);

  final sqlite.SqliteDatabase _connection;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Future<DatabaseQueryResult> query(DatabaseQuery query) async {
    _checkOpen();
    try {
      return _materialize(await _connection.getAll(query.sql, query.variables));
    } catch (error, stackTrace) {
      throwMappedDatabaseError(error, stackTrace);
    }
  }

  @override
  Future<DatabaseExecutionResult> execute(DatabaseStatement statement) async {
    _checkOpen();
    try {
      return await _connection.writeLock(
        (context) => _execute(context, statement),
      );
    } catch (error, stackTrace) {
      throwMappedDatabaseError(error, stackTrace);
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(DatabaseTransaction transaction) work,
  ) async {
    _checkOpen();
    try {
      return await _connection.writeTransaction((context) async {
        final transaction = _SqliteDatabaseTransaction(context);
        try {
          return await work(transaction);
        } finally {
          transaction.expire();
        }
      });
    } catch (error, stackTrace) {
      throwMappedDatabaseError(error, stackTrace);
    }
  }

  @override
  Stream<DatabaseQueryResult> watch(DatabaseQuery query) {
    if (_closed) {
      return Stream<DatabaseQueryResult>.error(closedDatabaseError());
    }
    return _connection
        .watch(query.sql, parameters: query.variables)
        .map(_materialize)
        .transform(
          StreamTransformer.fromHandlers(
            handleError: (error, stackTrace, sink) {
              sink.addError(mapSqliteError(error), stackTrace);
            },
          ),
        );
  }

  @override
  Stream<void> watchTables(Set<String> tables) {
    if (_closed) {
      return Stream<void>.error(closedDatabaseError());
    }
    return _connection
        .onChange(tables, triggerImmediately: false)
        .map<void>((_) {})
        .transform(
          StreamTransformer.fromHandlers(
            handleError: (error, stackTrace, sink) {
              sink.addError(mapSqliteError(error), stackTrace);
            },
          ),
        );
  }

  @override
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    return _closing = _connection.close();
  }

  void _checkOpen() {
    if (_closed) throw closedDatabaseError();
  }
}

final class _SqliteDatabaseTransaction implements DatabaseTransaction {
  _SqliteDatabaseTransaction(this._context);

  final sqlite.SqliteWriteContext _context;
  bool _active = true;

  void expire() => _active = false;

  @override
  Future<DatabaseQueryResult> query(DatabaseQuery query) async {
    _checkActive();
    try {
      return _materialize(await _context.getAll(query.sql, query.variables));
    } catch (error, stackTrace) {
      throwMappedDatabaseError(error, stackTrace);
    }
  }

  @override
  Future<DatabaseExecutionResult> execute(DatabaseStatement statement) async {
    _checkActive();
    try {
      return await _execute(_context, statement);
    } catch (error, stackTrace) {
      throwMappedDatabaseError(error, stackTrace);
    }
  }

  @override
  Future<T> savepoint<T>(
    Future<T> Function(DatabaseTransaction transaction) work,
  ) async {
    _checkActive();
    try {
      return await _context.writeTransaction((context) async {
        final savepoint = _SqliteDatabaseTransaction(context);
        try {
          return await work(savepoint);
        } finally {
          savepoint.expire();
        }
      });
    } catch (error, stackTrace) {
      throwMappedDatabaseError(error, stackTrace);
    }
  }

  void _checkActive() {
    if (!_active) throw closedDatabaseError();
  }
}

Future<DatabaseExecutionResult> _execute(
  sqlite.SqliteWriteContext context,
  DatabaseStatement statement,
) async {
  await context.execute(statement.sql, statement.variables);
  final metadata = await context.get(
    'SELECT changes() AS affected_rows, '
    'last_insert_rowid() AS last_insert_row_id',
  );
  return DatabaseExecutionResult(
    affectedRows: metadata['affected_rows']! as int,
    lastInsertRowId: metadata['last_insert_row_id']! as int,
  );
}

DatabaseQueryResult _materialize(sqlite3.ResultSet source) =>
    DatabaseQueryResult(columns: source.columnNames, rows: source.rows);
