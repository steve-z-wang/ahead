import 'package:meta/meta.dart';

import '../projection/model_record.dart';
import '../schema/model_id.dart';
import 'model.dart';
import 'model_query.dart';
import 'model_reader.dart';

typedef ModelMaterializer<T, I extends ModelId> = T Function(ModelRecord<I>);

abstract base class ModelCollection<T extends Model<I>, I extends ModelId, F> {
  ModelCollection({required this.reader});

  @protected
  final ModelReader<I> reader;

  @protected
  T materialize(ModelRecord<I> record);

  Future<T?> get(I id) async {
    final record = await reader.get(id);
    return record == null ? null : materialize(record);
  }
}

abstract base class ReactiveModelCollection<
  T extends Model<I>,
  I extends ModelId,
  F
>
    extends ModelCollection<T, I, F> {
  ReactiveModelCollection({
    required super.reader,
    required ModelMaterializer<T, I> materialize,
    required this.fields,
  }) : _materialize = materialize;

  final ModelMaterializer<T, I> _materialize;

  @protected
  final F fields;

  @override
  @protected
  T materialize(ModelRecord<I> record) => _materialize(record);

  Stream<T?> watch(I id) => reader
      .watch(id)
      .map((record) => record == null ? null : materialize(record));

  ReactiveModelQuery<T, F> query() => BoundReactiveModelQuery(
    reader: reader,
    materialize: materialize,
    fields: fields,
  );
}

final class BoundReactiveModelQuery<T, I extends ModelId, F>
    extends ReactiveModelQuery<T, F> {
  BoundReactiveModelQuery({
    required this.reader,
    required this.materialize,
    required this.fields,
    ProjectionQuery<I>? projection,
  }) : projection = projection ?? ProjectionQuery();

  final ModelReader<I> reader;
  final ModelMaterializer<T, I> materialize;
  final F fields;
  final ProjectionQuery<I> projection;

  BoundReactiveModelQuery<T, I, F> _copy(ProjectionQuery<I> projection) =>
      BoundReactiveModelQuery(
        reader: reader,
        materialize: materialize,
        fields: fields,
        projection: projection,
      );

  @override
  BoundReactiveModelQuery<T, I, F> where(
    ModelPredicate Function(F fields) build,
  ) => _copy(
    ProjectionQuery(
      predicates: [...projection.predicates, build(fields)],
      order: projection.order,
      limit: projection.limit,
    ),
  );

  @override
  BoundReactiveModelQuery<T, I, F> orderBy(
    ModelOrder Function(F fields) build,
  ) => _copy(
    ProjectionQuery(
      predicates: projection.predicates,
      order: [...projection.order, build(fields)],
      limit: projection.limit,
    ),
  );

  @override
  BoundReactiveModelQuery<T, I, F> limit(int count) {
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
  Future<List<T>> get() async =>
      List.unmodifiable((await reader.query(projection)).map(materialize));

  @override
  Stream<List<T>> watch() => reader
      .watchQuery(projection)
      .map((records) => List.unmodifiable(records.map(materialize)));
}
