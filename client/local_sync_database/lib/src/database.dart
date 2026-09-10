import 'database_executor.dart';
import 'database_query.dart';
import 'database_result.dart';
import 'database_statement.dart';
import 'database_transaction.dart';

abstract interface class Database implements DatabaseExecutor {
  @override
  Future<DatabaseQueryResult> query(DatabaseQuery query);

  @override
  Future<DatabaseExecutionResult> execute(DatabaseStatement statement);

  Future<T> transaction<T>(
    Future<T> Function(DatabaseTransaction transaction) work,
  );

  Stream<DatabaseQueryResult> watch(DatabaseQuery query);

  Stream<void> watchTables(Set<String> tables);

  Future<void> close();
}
