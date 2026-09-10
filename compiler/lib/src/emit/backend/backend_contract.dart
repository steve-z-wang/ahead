import '../../semantic/model_graph.dart';

final class BackendContract {
  BackendContract({
    required Iterable<BackendEnumContract> enums,
    required Iterable<BackendModelContract> models,
    Iterable<BackendMutationContract> mutations = const [],
  }) : enums = List.unmodifiable(enums),
       models = List.unmodifiable(models),
       mutations = List.unmodifiable(mutations);

  final List<BackendEnumContract> enums;
  final List<BackendModelContract> models;

  /// The declared mutations, sorted by name. Every declaration is a wire act
  /// (CAP-488), so every one of them reaches the Backend.
  final List<BackendMutationContract> mutations;

  @override
  bool operator ==(Object other) =>
      other is BackendContract &&
      _listsEqual(enums, other.enums) &&
      _listsEqual(models, other.models) &&
      _listsEqual(mutations, other.mutations);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(enums),
    Object.hashAll(models),
    Object.hashAll(mutations),
  );
}

final class BackendMutationContract {
  BackendMutationContract({
    required this.name,
    this.version = 1,
    required Iterable<BackendMutationSlotContract> slots,
  }) : slots = List.unmodifiable(slots);

  final String name;

  final int version;

  /// Declaration order, which is execution order.
  final List<BackendMutationSlotContract> slots;

  @override
  bool operator ==(Object other) =>
      other is BackendMutationContract &&
      name == other.name &&
      version == other.version &&
      _listsEqual(slots, other.slots);

  @override
  int get hashCode => Object.hash(name, version, Object.hashAll(slots));
}

final class BackendMutationSlotContract {
  BackendMutationSlotContract({
    required this.name,
    required this.model,
    required this.operation,
    required this.cardinality,
    Iterable<String>? allowedPatchFields,
    Iterable<BackendSlotBindingContract> bindings = const [],
  }) : allowedPatchFields = allowedPatchFields == null
           ? null
           : List.unmodifiable(allowedPatchFields),
       bindings = List.unmodifiable(bindings);

  final String name;
  final String model;
  final MutationOperationKind operation;
  final MutationSlotCardinality cardinality;
  final List<String>? allowedPatchFields;

  /// The act-level wiring this slot declares (spec 2026-08-16-slot-bindings),
  /// in declaration order. Empty when the slot binds nothing.
  final List<BackendSlotBindingContract> bindings;

  @override
  bool operator ==(Object other) =>
      other is BackendMutationSlotContract &&
      name == other.name &&
      model == other.model &&
      operation == other.operation &&
      cardinality == other.cardinality &&
      _nullableListsEqual(allowedPatchFields, other.allowedPatchFields) &&
      _listsEqual(bindings, other.bindings);

  @override
  int get hashCode => Object.hash(
    name,
    model,
    operation,
    cardinality,
    allowedPatchFields == null ? null : Object.hashAll(allowedPatchFields!),
    Object.hashAll(bindings),
  );
}

/// One `relation: slot` pair: this slot's rows' [fields] (in the bound
/// Model's identity order) equal the identity of the row in [slot].
final class BackendSlotBindingContract {
  BackendSlotBindingContract({
    required this.relation,
    required Iterable<String> fields,
    required this.slot,
  }) : fields = List.unmodifiable(fields);

  final String relation;
  final List<String> fields;
  final String slot;

  @override
  bool operator ==(Object other) =>
      other is BackendSlotBindingContract &&
      relation == other.relation &&
      _listsEqual(fields, other.fields) &&
      slot == other.slot;

  @override
  int get hashCode => Object.hash(relation, Object.hashAll(fields), slot);
}

final class BackendEnumContract {
  const BackendEnumContract._({required this.name, required this.values});

  factory BackendEnumContract({
    required String name,
    required Iterable<String> values,
  }) => BackendEnumContract._(name: name, values: List.unmodifiable(values));

  final String name;
  final List<String> values;

  @override
  bool operator ==(Object other) =>
      other is BackendEnumContract &&
      name == other.name &&
      _listsEqual(values, other.values);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(values));
}

final class BackendModelContract {
  BackendModelContract({
    required this.name,
    required Iterable<BackendFieldContract> identity,
    required Iterable<BackendFieldContract> fields,
  }) : identity = List.unmodifiable(identity),
       fields = List.unmodifiable(fields);

  final String name;
  final List<BackendFieldContract> identity;
  final List<BackendFieldContract> fields;

  @override
  bool operator ==(Object other) =>
      other is BackendModelContract &&
      name == other.name &&
      _listsEqual(identity, other.identity) &&
      _listsEqual(fields, other.fields);

  @override
  int get hashCode =>
      Object.hash(name, Object.hashAll(identity), Object.hashAll(fields));
}

final class BackendFieldContract {
  const BackendFieldContract({
    required this.name,
    required this.type,
    required this.nullable,
  });

  final String name;
  final BackendFieldType type;
  final bool nullable;

  @override
  bool operator ==(Object other) =>
      other is BackendFieldContract &&
      name == other.name &&
      type == other.type &&
      nullable == other.nullable;

  @override
  int get hashCode => Object.hash(name, type, nullable);
}

sealed class BackendFieldType {
  const BackendFieldType();
}

final class BackendScalarFieldType extends BackendFieldType {
  const BackendScalarFieldType(this.scalar);

  final ScalarType scalar;

  @override
  bool operator ==(Object other) =>
      other is BackendScalarFieldType && scalar == other.scalar;

  @override
  int get hashCode => Object.hash(BackendScalarFieldType, scalar);
}

final class BackendEnumFieldType extends BackendFieldType {
  const BackendEnumFieldType(this.name);

  final String name;

  @override
  bool operator ==(Object other) =>
      other is BackendEnumFieldType && name == other.name;

  @override
  int get hashCode => Object.hash(BackendEnumFieldType, name);
}

final class BackendScalarListFieldType extends BackendFieldType {
  const BackendScalarListFieldType(this.element);

  final ScalarType element;

  @override
  bool operator ==(Object other) =>
      other is BackendScalarListFieldType && element == other.element;

  @override
  int get hashCode => Object.hash(BackendScalarListFieldType, element);
}

bool _listsEqual<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _nullableListsEqual<T>(List<T>? left, List<T>? right) {
  if (left == null || right == null) return left == right;
  return _listsEqual(left, right);
}
