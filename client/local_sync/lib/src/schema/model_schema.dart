import 'model_id.dart';

sealed class LocalValueType {
  const LocalValueType();
}

enum LocalScalarType implements LocalValueType {
  string,
  boolean,
  int,
  float,
  dateTime,
  uuid,
}

final class LocalEnumType extends LocalValueType {
  const LocalEnumType({
    required this.name,
    required this.values,
    required this.encode,
    required this.decode,
  });

  final String name;
  final Set<String> values;
  final String Function(Object value) encode;
  final Object Function(String wire) decode;
}

final class LocalScalarListType extends LocalValueType {
  const LocalScalarListType(this.element);

  final LocalScalarType element;
}

final class ModelFieldSchema {
  const ModelFieldSchema({
    required this.name,
    required this.type,
    required this.nullable,
    this.prerequisite,
  });

  final String name;
  final LocalValueType type;
  final bool nullable;
  final ModelPrerequisiteRequirementSchema? prerequisite;
}

final class ModelPrerequisiteRequirementSchema {
  const ModelPrerequisiteRequirementSchema({
    required this.name,
    required this.arguments,
  });

  final String name;

  /// Prerequisite parameter name to source field name.
  final Map<String, String> arguments;
}

final class ModelUniqueConstraintSchema {
  const ModelUniqueConstraintSchema(this.fields);

  final List<String> fields;
}

/// One Model referencing another, and the rules the reference imposes.
///
/// [localFields] is the key as the source declared it — `@reference(via:
/// [...])` — positionally matched to [referencedFields], the target's identity.
/// A reference is structure: which local fields identify which target. It does
/// not order the Uplink and does not give two rows common fate — the two flags
/// below are the only things a declaration may add on top of it (CAP-437).
final class ModelRelationSchema {
  const ModelRelationSchema({
    required this.name,
    required this.targetModel,
    required this.localFields,
    required this.referencedFields,
    required this.nullable,
    required this.deleteOnTarget,
    this.relationName,
  });

  final String name;
  final String targetModel;
  final List<String> localFields;
  final List<String> referencedFields;
  final bool nullable;

  /// The name both directions share when the pair needs one, and null when one
  /// reference between the two Models makes the pairing obvious.
  final String? relationName;

  /// When the referenced target row is deleted, this row is deleted with it —
  /// locally in the same action, remotely on the target's absence.
  final bool deleteOnTarget;
}

/// How many rows an inverse relation stands for.
enum ModelRelationCardinality { many, one, optionalOne }

/// The reverse half of a relation, declared on the Model the reference points
/// at: `photos MomentPhoto[]` beside `MomentPhoto.moment`.
///
/// It is virtual — the key is stored on [sourceModel], never here — so nothing
/// about it reaches a table, the wire, or a migration. It exists so the graph
/// can be read from the side that owns the aggregate, which is what a nested
/// write needs (CAP-438).
final class ModelInverseRelationSchema {
  const ModelInverseRelationSchema({
    required this.name,
    required this.sourceModel,
    required this.reference,
    required this.cardinality,
    this.relationName,
  });

  final String name;

  /// The Model whose rows point back at this one.
  final String sourceModel;

  /// The name of the reference on [sourceModel] this field is the other half
  /// of.
  final String reference;
  final ModelRelationCardinality cardinality;
  final String? relationName;
}

abstract interface class ModelSchemaFacts {
  String get name;
  List<String> get identity;
  List<ModelFieldSchema> get fields;
  List<ModelUniqueConstraintSchema> get uniqueConstraints;
  List<ModelRelationSchema> get relations;
  List<ModelInverseRelationSchema> get inverseRelations;

  Map<String, ModelFieldSchema> get fieldsByName;

  ModelId createIdentity(Map<String, Object> components);

  bool isIdentityField(String name);
}

final class ModelSchema<I extends ModelId> implements ModelSchemaFacts {
  ModelSchema({
    required this.name,
    required List<String> identity,
    required List<ModelFieldSchema> fields,
    required List<ModelUniqueConstraintSchema> uniqueConstraints,
    required List<ModelRelationSchema> relations,
    List<ModelInverseRelationSchema> inverseRelations = const [],
    required this.createId,
  }) : identity = List.unmodifiable(identity),
       fields = List.unmodifiable(fields),
       uniqueConstraints = List.unmodifiable(uniqueConstraints),
       relations = List.unmodifiable(relations),
       inverseRelations = List.unmodifiable(inverseRelations),
       fieldsByName = Map.unmodifiable({
         for (final field in fields) field.name: field,
       });

  final String name;
  final List<String> identity;
  final List<ModelFieldSchema> fields;
  final List<ModelUniqueConstraintSchema> uniqueConstraints;
  final List<ModelRelationSchema> relations;

  @override
  final List<ModelInverseRelationSchema> inverseRelations;

  final I Function(Map<String, Object> components) createId;
  final Map<String, ModelFieldSchema> fieldsByName;

  @override
  ModelId createIdentity(Map<String, Object> components) =>
      createId(components);

  @override
  bool isIdentityField(String name) => identity.contains(name);
}
