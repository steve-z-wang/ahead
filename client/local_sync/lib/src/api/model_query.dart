import '../schema/model_id.dart';

abstract base class ModelQuery<T, F> {
  ModelQuery<T, F> where(ModelPredicate Function(F fields) build);

  ModelQuery<T, F> orderBy(ModelOrder Function(F fields) build);

  ModelQuery<T, F> limit(int count);

  Future<List<T>> get();
}

abstract base class ReactiveModelQuery<T, F> extends ModelQuery<T, F> {
  @override
  ReactiveModelQuery<T, F> where(ModelPredicate Function(F fields) build);

  @override
  ReactiveModelQuery<T, F> orderBy(ModelOrder Function(F fields) build);

  @override
  ReactiveModelQuery<T, F> limit(int count);

  Stream<List<T>> watch();
}

enum ModelOrderDirection { ascending, descending }

final class ModelPredicate {
  const ModelPredicate.field(this.field, this.expected) : identity = false;

  const ModelPredicate.identity(this.expected) : field = null, identity = true;

  final String? field;
  final Object? expected;
  final bool identity;
}

final class ModelOrder {
  const ModelOrder.field(this.field, this.direction) : identity = false;

  const ModelOrder.identity(this.direction) : field = null, identity = true;

  final String? field;
  final ModelOrderDirection direction;
  final bool identity;
}

abstract interface class ModelField<T> {
  ModelPredicate equals(T value);

  ModelOrder ascending();

  ModelOrder descending();
}

final class SchemaModelField<T> implements ModelField<T> {
  const SchemaModelField(this.name);

  final String name;

  @override
  ModelPredicate equals(T value) => ModelPredicate.field(name, value);

  @override
  ModelOrder ascending() =>
      ModelOrder.field(name, ModelOrderDirection.ascending);

  @override
  ModelOrder descending() =>
      ModelOrder.field(name, ModelOrderDirection.descending);
}

final class ModelIdentityField<I extends ModelId> implements ModelField<I> {
  const ModelIdentityField();

  @override
  ModelPredicate equals(I value) => ModelPredicate.identity(value);

  @override
  ModelOrder ascending() =>
      const ModelOrder.identity(ModelOrderDirection.ascending);

  @override
  ModelOrder descending() =>
      const ModelOrder.identity(ModelOrderDirection.descending);
}

final class ProjectionQuery<I extends ModelId> {
  ProjectionQuery({
    List<ModelPredicate> predicates = const [],
    List<ModelOrder> order = const [],
    this.limit,
  }) : predicates = List.unmodifiable(predicates),
       order = List.unmodifiable(order);

  final List<ModelPredicate> predicates;
  final List<ModelOrder> order;
  final int? limit;
}
