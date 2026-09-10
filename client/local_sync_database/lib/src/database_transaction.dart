import 'database_executor.dart';
import 'database_query.dart';
import 'database_result.dart';
import 'database_statement.dart';

abstract interface class DatabaseTransaction implements DatabaseExecutor {
  @override
  Future<DatabaseQueryResult> query(DatabaseQuery query);

  @override
  Future<DatabaseExecutionResult> execute(DatabaseStatement statement);

  Future<T> savepoint<T>(
    Future<T> Function(DatabaseTransaction transaction) work,
  );
}
