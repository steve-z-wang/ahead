import '../projection/model_record.dart';
import '../schema/model_id.dart';
import 'model_query.dart';

typedef ReadTransaction = Future<T> Function<T>(Future<T> Function() action);

abstract interface class ModelReader<I extends ModelId> {
  Future<ModelRecord<I>?> get(I id);

  Future<List<ModelRecord<I>>> query(ProjectionQuery<I> query);

  Stream<ModelRecord<I>?> watch(I id);

  Stream<List<ModelRecord<I>>> watchQuery(ProjectionQuery<I> query);
}
