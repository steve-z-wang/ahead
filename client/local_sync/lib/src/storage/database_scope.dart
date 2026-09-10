import 'dart:async';

import 'package:local_sync_database/local_sync_database.dart';

final class LocalDatabaseScope {
  LocalDatabaseScope(this.database);

  final Database database;
  final Object _zoneKey = Object();

  DatabaseExecutor get current =>
      Zone.current[_zoneKey] as DatabaseExecutor? ?? database;

  Future<T> transaction<T>(
    Future<T> Function(DatabaseTransaction transaction) work,
  ) => database.transaction(
    (transaction) =>
        runZoned(() => work(transaction), zoneValues: {_zoneKey: transaction}),
  );

  Future<T> readTransaction<T>(Future<T> Function() work) {
    if (current is DatabaseTransaction) return work();
    return transaction((_) => work());
  }

  Future<T> savepoint<T>(Future<T> Function() work) {
    final executor = current;
    if (executor is! DatabaseTransaction) {
      throw StateError('savepoint requires an active database transaction');
    }
    return executor.savepoint(
      (savepoint) => runZoned(work, zoneValues: {_zoneKey: savepoint}),
    );
  }
}
