import 'database_exception.dart';
import 'database_value.dart';

final class DatabaseStatement {
  DatabaseStatement({required this.sql, Iterable<Object?> variables = const []})
    : variables = immutableDatabaseValues(variables) {
    if (sql.trim().isEmpty) {
      throw const DatabaseException(
        kind: DatabaseErrorKind.invalidArgument,
        message: 'statement SQL is empty',
      );
    }
  }

  final String sql;
  final List<Object?> variables;
}
