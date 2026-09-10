import '../api/model_reader_base.dart';
import '../projection/model_record.dart';
import '../projection/query_evaluator.dart';
import '../schema/model_id.dart';
import 'canonical_store.dart';
import 'database_scope.dart';
import 'model_database_descriptor.dart';

final class CanonicalModelReader<I extends ModelId> extends ModelReaderBase<I> {
  CanonicalModelReader({
    required this.canonical,
    required this.database,
    required this.descriptor,
  }) : super(
         evaluator: QueryEvaluator(descriptor.schema),
         readTransaction: database.readTransaction,
       );

  final CanonicalStore<I> canonical;
  final LocalDatabaseScope database;
  final ModelDatabaseDescriptor<I> descriptor;

  @override
  Future<ModelRecord<I>?> readIdentityInCurrentTransaction(I id) =>
      canonical.get(id);

  @override
  Future<List<ModelRecord<I>>> readModelInCurrentTransaction() =>
      canonical.readAll();

  @override
  Stream<void> invalidations() =>
      database.database.watchTables({descriptor.tableName});
}
