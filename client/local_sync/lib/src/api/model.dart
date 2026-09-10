import '../schema/model_id.dart';

abstract base class Model<I extends ModelId> {
  const Model();

  I get id;
}

final class FieldUpdate<T> {
  const FieldUpdate.set(this.value);

  final T value;
}
