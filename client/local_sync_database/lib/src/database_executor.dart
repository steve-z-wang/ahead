import 'database_query.dart';
import 'database_result.dart';
import 'database_statement.dart';

abstract interface class DatabaseExecutor {
  Future<DatabaseQueryResult> query(DatabaseQuery query);

  Future<DatabaseExecutionResult> execute(DatabaseStatement statement);
}
