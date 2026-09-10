enum ScalarType { string, boolean, int, float, dateTime, uuid }

final class PrerequisiteSymbol implements Comparable<PrerequisiteSymbol> {
  const PrerequisiteSymbol(this.name);

  final String name;

  @override
  int compareTo(PrerequisiteSymbol other) => name.compareTo(other.name);

  @override
  bool operator ==(Object other) =>
      other is PrerequisiteSymbol && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

final class PrerequisiteParameterDefinition {
  const PrerequisiteParameterDefinition({
    required this.name,
    required this.type,
  });

  final String name;
  final ScalarType type;
}

final class PrerequisiteDefinition {
  PrerequisiteDefinition({
    required this.symbol,
    required Iterable<PrerequisiteParameterDefinition> parameters,
  }) : parameters = List.unmodifiable(parameters);

  final PrerequisiteSymbol symbol;
  final List<PrerequisiteParameterDefinition> parameters;
}

enum PrerequisiteBinding { self }

final class PrerequisiteRequirementDefinition {
  PrerequisiteRequirementDefinition({
    required this.prerequisite,
    required Map<String, PrerequisiteBinding> arguments,
  }) : arguments = Map.unmodifiable(arguments);

  final PrerequisiteSymbol prerequisite;
  final Map<String, PrerequisiteBinding> arguments;
}

final class EnumSymbol implements Comparable<EnumSymbol> {
  const EnumSymbol(this.name);

  final String name;

  @override
  int compareTo(EnumSymbol other) => name.compareTo(other.name);

  @override
  bool operator ==(Object other) => other is EnumSymbol && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

final class EnumValueSymbol {
  const EnumValueSymbol({required this.owner, required this.name});

  final EnumSymbol owner;
  final String name;
}

final class EnumDefinition {
  EnumDefinition({
    required this.symbol,
    required Iterable<EnumValueSymbol> values,
  }) : values = List.unmodifiable(values);

  final EnumSymbol symbol;
  final List<EnumValueSymbol> values;
}

sealed class FieldValueType {
  const FieldValueType();
}

final class ScalarValueType extends FieldValueType {
  const ScalarValueType(this.scalar);

  final ScalarType scalar;

  @override
  bool operator ==(Object other) =>
      other is ScalarValueType && other.scalar == scalar;

  @override
  int get hashCode => scalar.hashCode;
}

final class EnumValueType extends FieldValueType {
  const EnumValueType(this.enumSymbol);

  final EnumSymbol enumSymbol;

  @override
  bool operator ==(Object other) =>
      other is EnumValueType && other.enumSymbol == enumSymbol;

  @override
  int get hashCode => enumSymbol.hashCode;
}

final class ScalarListValueType extends FieldValueType {
  const ScalarListValueType(this.element);

  final ScalarType element;

  @override
  bool operator ==(Object other) =>
      other is ScalarListValueType && other.element == element;

  @override
  int get hashCode => element.hashCode;
}

final class ModelSymbol implements Comparable<ModelSymbol> {
  const ModelSymbol(this.name);

  final String name;

  @override
  int compareTo(ModelSymbol other) => name.compareTo(other.name);

  @override
  bool operator ==(Object other) => other is ModelSymbol && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

final class FieldSymbol {
  const FieldSymbol({required this.model, required this.name});

  final ModelSymbol model;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is FieldSymbol && other.model == model && other.name == name;

  @override
  int get hashCode => Object.hash(model, name);

  @override
  String toString() => '${model.name}.$name';
}

final class RelationSymbol {
  const RelationSymbol({required this.model, required this.name});

  final ModelSymbol model;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is RelationSymbol && other.model == model && other.name == name;

  @override
  int get hashCode => Object.hash(model, name);

  @override
  String toString() => '${model.name}.$name';
}

final class ModelFieldDefinition {
  const ModelFieldDefinition({
    required this.symbol,
    required this.valueType,
    required this.nullable,
    this.prerequisite,
  });

  final FieldSymbol symbol;
  final FieldValueType valueType;
  final bool nullable;

  final PrerequisiteRequirementDefinition? prerequisite;

  bool get isScalar => valueType is ScalarValueType;
}

final class UniqueConstraint {
  UniqueConstraint(Iterable<FieldSymbol> fields)
    : fields = List.unmodifiable(fields);

  final List<FieldSymbol> fields;
}

final class ModelIdentity {
  ModelIdentity(Iterable<FieldSymbol> fields)
    : fields = List.unmodifiable(fields);

  final List<FieldSymbol> fields;
}

/// A Model naming another and the fields it stores the pointer in:
/// `@reference(via: [spaceId], onTargetDelete: delete)`.
///
/// The declaration is the whole of it — nothing is inferred from the relation's
/// field name. [localFields] is the ordered list the source declared, and it
/// maps positionally onto [referencedFields], the ordered fields of the
/// target's [ModelIdentity].
final class RelationDefinition {
  RelationDefinition({
    required this.symbol,
    required this.target,
    required Iterable<FieldSymbol> localFields,
    required Iterable<FieldSymbol> referencedFields,
    required this.nullable,
    required this.deleteOnTarget,
    this.relationName,
  }) : localFields = List.unmodifiable(localFields),
       referencedFields = List.unmodifiable(referencedFields);

  final RelationSymbol symbol;
  final ModelSymbol target;
  final List<FieldSymbol> localFields;
  final List<FieldSymbol> referencedFields;
  final bool nullable;

  /// When the referenced target row is deleted, this row is deleted with it.
  final bool deleteOnTarget;

  /// The shared name both directions of the relation carry, when the pair
  /// needs one: `@reference("Source", …)` here, `@inverse("Source")` there.
  /// Null when one reference between the two Models makes the pairing obvious.
  final String? relationName;
}

/// How many rows of the declared type an inverse field stands for.
enum InverseCardinality {
  /// `Child[]` — the ordinary shape: many rows point back.
  many,

  /// `Child` — at most one row points back, and the author says there is one.
  one,

  /// `Child?` — at most one row points back, and there may be none.
  optionalOne,
}

/// The reverse direction of a relation: `photos MomentPhoto[]` on the Model the
/// reference points AT.
///
/// It is virtual. Nothing stores it — the key lives on the referencing Model —
/// so it never becomes a column, a wire field, or a migration. It exists so the
/// graph can be walked in both directions.
final class InverseRelationDefinition {
  const InverseRelationDefinition({
    required this.symbol,
    required this.target,
    required this.cardinality,
    required this.reference,
    this.relationName,
  });

  final RelationSymbol symbol;

  /// The Model whose rows point back — the type the field was declared with.
  final ModelSymbol target;
  final InverseCardinality cardinality;

  /// The reference this field is the other half of.
  final RelationSymbol reference;
  final String? relationName;
}

final class ModelDefinition {
  factory ModelDefinition({
    required ModelSymbol symbol,
    required Iterable<ModelFieldDefinition> fields,
    required ModelIdentity identity,
    required Iterable<UniqueConstraint> uniqueConstraints,
    required Iterable<RelationDefinition> relations,
    Iterable<InverseRelationDefinition> inverses = const [],
  }) {
    final frozenFields = List<ModelFieldDefinition>.unmodifiable(fields);
    final frozenRelations = List<RelationDefinition>.unmodifiable(relations);
    return ModelDefinition._(
      symbol: symbol,
      fields: frozenFields,
      identity: identity,
      uniqueConstraints: List<UniqueConstraint>.unmodifiable(uniqueConstraints),
      relations: frozenRelations,
      inverses: List<InverseRelationDefinition>.unmodifiable(inverses),
      fieldsBySymbol: {for (final field in frozenFields) field.symbol: field},
      relationsBySymbol: {
        for (final relation in frozenRelations) relation.symbol: relation,
      },
    );
  }

  ModelDefinition._({
    required this.symbol,
    required this.fields,
    required this.identity,
    required this.uniqueConstraints,
    required this.relations,
    required this.inverses,
    required Map<FieldSymbol, ModelFieldDefinition> fieldsBySymbol,
    required Map<RelationSymbol, RelationDefinition> relationsBySymbol,
  }) : _fieldsBySymbol = Map.unmodifiable(fieldsBySymbol),
       _relationsBySymbol = Map.unmodifiable(relationsBySymbol);

  final ModelSymbol symbol;
  final List<ModelFieldDefinition> fields;
  final ModelIdentity identity;
  final List<UniqueConstraint> uniqueConstraints;
  final List<RelationDefinition> relations;

  /// The reverse halves declared on this Model, in declaration order.
  final List<InverseRelationDefinition> inverses;
  final Map<FieldSymbol, ModelFieldDefinition> _fieldsBySymbol;
  final Map<RelationSymbol, RelationDefinition> _relationsBySymbol;

  ModelFieldDefinition field(FieldSymbol symbol) {
    final field = _fieldsBySymbol[symbol];
    if (field == null) throw StateError('unknown field "$symbol"');
    return field;
  }

  RelationDefinition relation(RelationSymbol symbol) {
    final relation = _relationsBySymbol[symbol];
    if (relation == null) throw StateError('unknown relation "$symbol"');
    return relation;
  }
}

/// The operation vocabulary, closed forever: `{Model} × {create, update,
/// delete}` (CAP-439). Mutations are the open half; nothing adds a kind here.
enum MutationOperationKind { create, update, delete }

/// How many rows of one `(Model, op)` pair a slot stands for.
enum MutationSlotCardinality {
  /// `moment Moment.create` — exactly one.
  single,

  /// `feed FeedEntry.delete?` — one or none.
  optional,

  /// `photos MomentPhoto.create[]` — a list, possibly empty.
  list,
}

final class MutationSymbol implements Comparable<MutationSymbol> {
  const MutationSymbol(this.name);

  final String name;

  @override
  int compareTo(MutationSymbol other) => name.compareTo(other.name);

  @override
  bool operator ==(Object other) =>
      other is MutationSymbol && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// One `fieldName Model.op` line. The pair is fixed at declaration, so a
/// resolver reads a slot's exact type and never switches on a discriminator.
final class MutationSlotDefinition {
  MutationSlotDefinition({
    required this.mutation,
    required this.name,
    required this.model,
    required this.operation,
    required this.cardinality,
    Iterable<FieldSymbol> allowedPatchFields = const [],
    Iterable<MutationSlotBindingDefinition> bindings = const [],
  }) : allowedPatchFields = List.unmodifiable(allowedPatchFields),
       bindings = List.unmodifiable(bindings);

  final MutationSymbol mutation;
  final String name;
  final ModelSymbol model;
  final MutationOperationKind operation;
  final MutationSlotCardinality cardinality;

  /// The complete source-ordered set of stored, non-identity fields this
  /// named update slot may patch. Empty for create and delete slots.
  final List<FieldSymbol> allowedPatchFields;

  /// The act-level wiring this slot declares (spec 2026-08-16-slot-bindings):
  /// each entry says these rows' relation points at the row another slot of
  /// the same act carries. A binding is a check and nothing else — builders,
  /// values and the wire are untouched by it.
  final List<MutationSlotBindingDefinition> bindings;

  @override
  String toString() => '${mutation.name}.$name';
}

/// One resolved `relation: slot` pair on a mutation slot.
///
/// [fields] are the referencing fields on the slot's Model, in the bound
/// Model's identity order (the relation's `via` mapping) — the fields that
/// must equal the bound slot's row identity for the act to be internally
/// consistent.
final class MutationSlotBindingDefinition {
  MutationSlotBindingDefinition({
    required this.relation,
    required Iterable<FieldSymbol> fields,
    required this.slot,
  }) : fields = List.unmodifiable(fields);

  final RelationSymbol relation;
  final List<FieldSymbol> fields;

  /// The bound slot's name — a `(single)`-cardinality slot declared earlier
  /// in the same mutation.
  final String slot;
}

/// One resolved slot-rooted endpoint of a Mutation sequence selector.
final class MutationSequenceEndpointDefinition {
  MutationSequenceEndpointDefinition({
    required this.slot,
    required Iterable<RelationSymbol> relations,
    required this.model,
  }) : relations = List.unmodifiable(relations);

  final String slot;
  final List<RelationSymbol> relations;
  final ModelSymbol model;
}

/// One directional product-order selector declared on the current Mutation.
final class MutationSequenceSelectorDefinition {
  const MutationSequenceSelectorDefinition({
    required this.predecessorMutation,
    required this.predecessor,
    required this.current,
  });

  final MutationSymbol predecessorMutation;
  final MutationSequenceEndpointDefinition predecessor;
  final MutationSequenceEndpointDefinition current;
}

/// A named group of operations — one product act, and the only thing a client
/// sends (CAP-439).
///
/// Slots are held in declaration order, which is execution order. Every
/// declared mutation is a wire act (CAP-488): a Model describes a row shape and
/// says nothing about replication, so device-only work is not declared here at
/// all — it is an ordinary direct transaction operation.
final class MutationDefinition {
  MutationDefinition({
    this.version = 1,
    required this.symbol,
    required Iterable<MutationSlotDefinition> slots,
    Iterable<MutationSequenceSelectorDefinition> sequenceSelectors = const [],
  }) : slots = List.unmodifiable(slots),
       sequenceSelectors = List.unmodifiable(sequenceSelectors);

  final MutationSymbol symbol;
  final int version;
  final List<MutationSlotDefinition> slots;
  final List<MutationSequenceSelectorDefinition> sequenceSelectors;
}

final class ModelGraph {
  factory ModelGraph(
    Iterable<ModelDefinition> models, {
    Iterable<EnumDefinition> enums = const [],
    Iterable<MutationDefinition> mutations = const [],
    Iterable<PrerequisiteDefinition> prerequisites = const [],
  }) {
    final frozenModels = models.toList()
      ..sort((left, right) => left.symbol.compareTo(right.symbol));
    final frozenEnums = enums.toList()
      ..sort((left, right) => left.symbol.compareTo(right.symbol));
    final frozenMutations = mutations.toList()
      ..sort((left, right) => left.symbol.compareTo(right.symbol));
    final frozenPrerequisites = prerequisites.toList()
      ..sort((left, right) => left.symbol.compareTo(right.symbol));
    return ModelGraph._(
      enums: List<EnumDefinition>.unmodifiable(frozenEnums),
      models: List<ModelDefinition>.unmodifiable(frozenModels),
      mutations: List<MutationDefinition>.unmodifiable(frozenMutations),
      prerequisites: List<PrerequisiteDefinition>.unmodifiable(
        frozenPrerequisites,
      ),
      enumsBySymbol: {for (final value in frozenEnums) value.symbol: value},
      modelsBySymbol: {for (final model in frozenModels) model.symbol: model},
      mutationsBySymbol: {
        for (final mutation in frozenMutations) mutation.symbol: mutation,
      },
    );
  }

  ModelGraph._({
    required this.enums,
    required this.models,
    required this.mutations,
    required this.prerequisites,
    required Map<EnumSymbol, EnumDefinition> enumsBySymbol,
    required Map<ModelSymbol, ModelDefinition> modelsBySymbol,
    required Map<MutationSymbol, MutationDefinition> mutationsBySymbol,
  }) : _enumsBySymbol = Map.unmodifiable(enumsBySymbol),
       _modelsBySymbol = Map.unmodifiable(modelsBySymbol),
       _mutationsBySymbol = Map.unmodifiable(mutationsBySymbol);

  final List<EnumDefinition> enums;
  final List<ModelDefinition> models;

  /// Every declared mutation, sorted by name.
  final List<MutationDefinition> mutations;
  final List<PrerequisiteDefinition> prerequisites;
  final Map<EnumSymbol, EnumDefinition> _enumsBySymbol;
  final Map<ModelSymbol, ModelDefinition> _modelsBySymbol;
  final Map<MutationSymbol, MutationDefinition> _mutationsBySymbol;

  EnumDefinition enumDefinition(EnumSymbol symbol) {
    final value = _enumsBySymbol[symbol];
    if (value == null) throw StateError('unknown enum "$symbol"');
    return value;
  }

  MutationDefinition mutation(MutationSymbol symbol) {
    final mutation = _mutationsBySymbol[symbol];
    if (mutation == null) throw StateError('unknown mutation "$symbol"');
    return mutation;
  }

  ModelDefinition model(ModelSymbol symbol) {
    final model = _modelsBySymbol[symbol];
    if (model == null) throw StateError('unknown Model "$symbol"');
    return model;
  }

  ModelFieldDefinition field(FieldSymbol symbol) =>
      model(symbol.model).field(symbol);

  RelationDefinition relation(RelationSymbol symbol) =>
      model(symbol.model).relation(symbol);
}
