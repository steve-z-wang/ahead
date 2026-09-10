import 'model_id.dart';
import 'model_schema.dart';

/// Retained wire input shapes. These create no tables and expose no Model writes.
final class MutationInputContracts {
  MutationInputContracts(Map<String, Map<int, Map<String, Object?>>> contracts)
    : _contracts = Map.unmodifiable({
        for (final act in contracts.entries)
          act.key: Map<int, Map<String, ModelSchema<ModelId>>>.unmodifiable({
            for (final version in act.value.entries)
              version.key: _models(version.value),
          }),
      });

  final Map<String, Map<int, Map<String, ModelSchema<ModelId>>>> _contracts;

  ModelSchema<ModelId> schema(String name, int version, String model) {
    final value = _contracts[name]?[version]?[model];
    if (value == null) {
      throw StateError('missing $name v$version input contract for $model');
    }
    return value;
  }

  static Map<String, ModelSchema<ModelId>> _models(Map<String, Object?> input) {
    final enums = input['enumValues']! as Map;
    return Map.unmodifiable({
      for (final raw in (input['models']! as Map).values)
        (raw as Map)['name']! as String: ModelSchema<ModelId>(
          name: raw['name']! as String,
          identity: (raw['identityFields']! as List).cast<String>(),
          fields: [
            for (final field in raw['fields']! as List)
              _field(field as Map, enums),
          ],
          uniqueConstraints: const [],
          relations: const [],
          createId: _InputIdentity.new,
        ),
    });
  }

  static ModelFieldSchema _field(Map field, Map enums) {
    final requirement = field['prerequisite'] as Map?;
    return ModelFieldSchema(
      name: field['name']! as String,
      nullable: field['nullable']! as bool,
      type: _type(field['type']! as Map, enums),
      prerequisite: requirement == null
          ? null
          : ModelPrerequisiteRequirementSchema(
              name: requirement['name']! as String,
              arguments: Map.unmodifiable(
                (requirement['arguments']! as Map).cast<String, String>(),
              ),
            ),
    );
  }

  static LocalValueType _type(Map type, Map enums) => switch (type['kind']) {
    'scalar' => LocalScalarType.values.byName(type['name']! as String),
    'list' => LocalScalarListType(
      LocalScalarType.values.byName(type['element']! as String),
    ),
    'enum' => LocalEnumType(
      name: type['name']! as String,
      values: Set.unmodifiable((enums[type['name']]! as List).cast<String>()),
      // Wire history uses strings, never a newer generated enum class.
      encode: (value) => value as String,
      decode: (wire) => wire,
    ),
    _ => throw StateError('unknown mutation input field type ${type['kind']}'),
  };
}

final class _InputIdentity extends ModelId {
  _InputIdentity(Map<String, Object> components)
    : components = Map.unmodifiable(components);

  @override
  final Map<String, Object> components;
}
