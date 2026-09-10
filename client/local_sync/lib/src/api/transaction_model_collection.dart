import 'package:meta/meta.dart';

import '../projection/model_record.dart';
import '../schema/model_id.dart';
import 'model.dart';
import 'model_collection.dart';
import 'model_query.dart';
import 'model_writer.dart';
import 'transaction_model_reader.dart';

/// One Model, as a write callback sees it (CAP-488).
///
/// It reads and writes inside the callback's own transaction, so an act can
/// look at the rows it is about to change and see its own companions. It
/// deliberately exposes no `watch`: a stream cannot be allowed to escape the
/// transaction that gives its reads meaning.
abstract base class TransactionModelCollection<
  T extends Model<I>,
  I extends ModelId,
  F
>
    extends ModelCollection<T, I, F> {
  TransactionModelCollection({
    required TransactionModelReader<I> reader,
    required this.writer,
    required ModelMaterializer<T, I> materialize,
    required this.fields,
  }) : _reader = reader,
       _materialize = materialize,
       super(reader: reader);

  final TransactionModelReader<I> _reader;
  final ModelMaterializer<T, I> _materialize;

  @protected
  final ModelWriter<I> writer;

  @protected
  final F fields;

  @override
  @protected
  T materialize(ModelRecord<I> record) => _materialize(record);

  @override
  Future<T?> get(I id) async {
    final record = await _reader.getInCurrentTransaction(id);
    return record == null ? null : materialize(record);
  }

  ModelQuery<T, F> query() => BoundTransactionModelQuery(
    reader: _reader,
    materialize: materialize,
    fields: fields,
  );
}

final class BoundTransactionModelQuery<T, I extends ModelId, F>
    extends ModelQuery<T, F> {
  BoundTransactionModelQuery({
    required this.reader,
    required this.materialize,
    required this.fields,
    ProjectionQuery<I>? projection,
  }) : projection = projection ?? ProjectionQuery();

  final TransactionModelReader<I> reader;
  final ModelMaterializer<T, I> materialize;
  final F fields;
  final ProjectionQuery<I> projection;

  BoundTransactionModelQuery<T, I, F> _copy(ProjectionQuery<I> projection) =>
      BoundTransactionModelQuery(
        reader: reader,
        materialize: materialize,
        fields: fields,
        projection: projection,
      );

  @override
  BoundTransactionModelQuery<T, I, F> where(
    ModelPredicate Function(F fields) build,
  ) => _copy(
    ProjectionQuery(
      predicates: [...projection.predicates, build(fields)],
      order: projection.order,
      limit: projection.limit,
    ),
  );

  @override
  BoundTransactionModelQuery<T, I, F> orderBy(
    ModelOrder Function(F fields) build,
  ) => _copy(
    ProjectionQuery(
      predicates: projection.predicates,
      order: [...projection.order, build(fields)],
      limit: projection.limit,
    ),
  );

  @override
  BoundTransactionModelQuery<T, I, F> limit(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'must not be negative');
    }
    return _copy(
      ProjectionQuery(
        predicates: projection.predicates,
        order: projection.order,
        limit: count,
      ),
    );
  }

  @override
  Future<List<T>> get() async => List.unmodifiable(
    (await reader.queryInCurrentTransaction(projection)).map(materialize),
  );
}
