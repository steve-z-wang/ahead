import '../mutation/model_mutation.dart';

/// A historical operation, readable even if its Model schema has since changed.
/// Identity and values use the queue's JSON scalar encoding (UUID/date strings,
/// enum names, numbers, booleans, nulls and recursively immutable lists/maps).
/// Values are the original create payload or update patch, not a live row.
final class LocalSyncOperationSnapshot {
  LocalSyncOperationSnapshot.fromSnapshot(Map<String, Object?> snapshot)
    : position = snapshot['position']! as int,
      slotName = snapshot['slot'] as String?,
      model = snapshot['model']! as String,
      identity = _immutableMap(snapshot['identity']),
      operation = MutationOperation.values.byName(
        snapshot['operation']! as String,
      ),
      values = _immutableMap(snapshot['values']),
      isUplink = snapshot['wire']! as bool;

  final int position;
  final String? slotName;
  final String model;
  final Map<String, Object?> identity;
  final MutationOperation operation;
  final Map<String, Object?> values;
  final bool isUplink;
}

Map<String, Object?> _immutableMap(Object? value) => Map.unmodifiable(
  (value! as Map).map(
    (key, value) => MapEntry(key as String, _immutableValue(value)),
  ),
);

Object? _immutableValue(Object? value) => switch (value) {
  Map() => _immutableMap(value),
  List() => List<Object?>.unmodifiable(value.map(_immutableValue)),
  _ => value,
};
