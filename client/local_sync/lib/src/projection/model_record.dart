import 'package:collection/collection.dart';

import '../schema/model_id.dart';

final class ModelRecord<I extends ModelId> {
  ModelRecord({required this.id, required Map<String, Object?> fields})
    : fields = Map.unmodifiable(fields);

  final I id;
  final Map<String, Object?> fields;

  @override
  bool operator ==(Object other) =>
      other is ModelRecord<I> &&
      other.id == id &&
      const DeepCollectionEquality().equals(other.fields, fields);

  @override
  int get hashCode =>
      Object.hash(id, const DeepCollectionEquality().hash(fields));

  @override
  String toString() => 'ModelRecord($id, $fields)';
}
