import '../../semantic/model_graph.dart';
import 'backend_contract.dart';

BackendContract buildBackendContract(ModelGraph graph) {
  final models = <BackendModelContract>[];
  final reachableEnums = <EnumSymbol>{};

  for (final model in graph.models) {
    final fields = [for (final field in model.fields) _projectField(field)]
      ..sort((left, right) => left.name.compareTo(right.name));
    final fieldsByName = {for (final field in fields) field.name: field};
    final identity = <BackendFieldContract>[];
    if (model.identity.fields.isEmpty) {
      throw StateError('Model "${model.symbol.name}" has no identity');
    }
    final seenIdentityFields = <String>{};
    for (final identitySymbol in model.identity.fields) {
      if (identitySymbol.model != model.symbol) {
        throw StateError(
          'identity field "$identitySymbol" does not belong to "${model.symbol.name}"',
        );
      }
      final field = fieldsByName[identitySymbol.name];
      if (field == null) {
        throw StateError('unknown identity field "$identitySymbol"');
      }
      if (!seenIdentityFields.add(field.name)) {
        throw StateError('duplicate identity field "$identitySymbol"');
      }
      if (field.nullable || field.type is! BackendScalarFieldType) {
        throw StateError(
          'identity field "$identitySymbol" must be a non-null scalar',
        );
      }
      identity.add(field);
    }

    for (final field in model.fields) {
      if (field.valueType case EnumValueType(:final enumSymbol)) {
        reachableEnums.add(enumSymbol);
      }
    }
    models.add(
      BackendModelContract(
        name: model.symbol.name,
        identity: identity,
        fields: fields,
      ),
    );
  }

  final enums = [
    for (final definition in graph.enums)
      if (reachableEnums.contains(definition.symbol))
        BackendEnumContract(
          name: definition.symbol.name,
          values: definition.values.map((value) => value.name),
        ),
  ]..sort((left, right) => left.name.compareTo(right.name));
  models.sort((left, right) => left.name.compareTo(right.name));

  final modelNames = {for (final model in models) model.name};
  final mutations = <BackendMutationContract>[];
  for (final mutation in graph.mutations) {
    mutations.add(
      BackendMutationContract(
        name: mutation.symbol.name,
        version: mutation.version,
        slots: [
          for (final slot in mutation.slots)
            if (modelNames.contains(slot.model.name))
              BackendMutationSlotContract(
                name: slot.name,
                model: slot.model.name,
                operation: slot.operation,
                cardinality: slot.cardinality,
                allowedPatchFields:
                    slot.operation == MutationOperationKind.update
                    ? slot.allowedPatchFields.map((field) => field.name)
                    : null,
                bindings: [
                  for (final binding in slot.bindings)
                    BackendSlotBindingContract(
                      relation: binding.relation.name,
                      fields: binding.fields.map((field) => field.name),
                      slot: binding.slot,
                    ),
                ],
              ),
        ],
      ),
    );
  }
  mutations.sort((left, right) => left.name.compareTo(right.name));

  return BackendContract(enums: enums, models: models, mutations: mutations);
}

BackendFieldContract _projectField(
  ModelFieldDefinition field,
) => BackendFieldContract(
  name: field.symbol.name,
  type: switch (field.valueType) {
    ScalarValueType(:final scalar) => BackendScalarFieldType(scalar),
    EnumValueType(:final enumSymbol) => BackendEnumFieldType(enumSymbol.name),
    ScalarListValueType(:final element) => BackendScalarListFieldType(element),
  },
  nullable: field.nullable,
);
