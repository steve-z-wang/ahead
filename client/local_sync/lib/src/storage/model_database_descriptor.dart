import '../schema/model_id.dart';
import '../schema/model_schema.dart';

final class ModelDatabaseDescriptor<I extends ModelId> {
  ModelDatabaseDescriptor({
    required this.schema,
    required this.tableName,
    required Map<String, String> columns,
  }) : columns = Map<String, String>.unmodifiable(columns) {
    final fields = schema.fields.map((field) => field.name).toSet();
    if (columns.keys.toSet().length != fields.length ||
        !columns.keys.toSet().containsAll(fields)) {
      throw StateError('${schema.name} database columns do not match fields');
    }
    if (columns.values.toSet().length != columns.length) {
      throw StateError('${schema.name} database columns are not unique');
    }
  }

  final ModelSchema<I> schema;
  final String tableName;
  final Map<String, String> columns;

  String column(String field) {
    final column = columns[field];
    if (column == null) {
      throw StateError('${schema.name} has no database column for "$field"');
    }
    return column;
  }
}

String quoteSqlIdentifier(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';
