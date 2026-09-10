import 'package:meta/meta.dart';

import '../projection/model_record.dart';
import '../schema/model_id.dart';
import 'model_query.dart';
import 'model_reader.dart';

abstract interface class TransactionModelReader<I extends ModelId>
    implements ModelReader<I> {
  @internal
  Future<ModelRecord<I>?> getInCurrentTransaction(I id);

  @internal
  Future<List<ModelRecord<I>>> queryInCurrentTransaction(
    ProjectionQuery<I> query,
  );
}
