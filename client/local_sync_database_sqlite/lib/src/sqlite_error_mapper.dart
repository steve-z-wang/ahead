import 'package:local_sync_database/local_sync_database.dart';
import 'package:sqlite3/common.dart' as sqlite3;
import 'package:sqlite_async/sqlite_async.dart' as sqlite;

Never throwMappedDatabaseError(Object error, StackTrace stackTrace) {
  Error.throwWithStackTrace(mapSqliteError(error), stackTrace);
}

Object mapSqliteError(Object error) {
  if (error is DatabaseException) return error;
  if (error is sqlite3.SqliteException) {
    return DatabaseException(
      kind: _kindForResultCode(error.resultCode),
      message: error.message,
      nativeCode: error.extendedResultCode,
      cause: error,
    );
  }
  if (error is sqlite.AbortException || error is sqlite.LockError) {
    return DatabaseException(
      kind: DatabaseErrorKind.busy,
      message: error.toString(),
      cause: error,
    );
  }
  return error;
}

DatabaseErrorKind _kindForResultCode(int code) => switch (code) {
  5 || 6 => DatabaseErrorKind.busy,
  11 || 26 => DatabaseErrorKind.corrupt,
  19 => DatabaseErrorKind.constraint,
  _ => DatabaseErrorKind.unknown,
};

DatabaseException closedDatabaseError() => const DatabaseException(
  kind: DatabaseErrorKind.closed,
  message: 'database is closed',
);
