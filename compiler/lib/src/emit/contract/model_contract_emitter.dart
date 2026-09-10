import 'dart:convert';

import '../../semantic/model_graph.dart';

String emitModelContract(ModelGraph graph) {
  final models = graph.models.toList();
  final reachableEnums = {
    for (final model in models)
      for (final field in model.fields)
        if (field.valueType case EnumValueType(:final enumSymbol)) enumSymbol,
  };
  final contract = {
    'enums': [
      for (final enumDefinition in graph.enums)
        if (reachableEnums.contains(enumDefinition.symbol))
          {
            'name': enumDefinition.symbol.name,
            'values': [for (final value in enumDefinition.values) value.name],
          },
    ],
    'models': [
      for (final model in models)
        {
          'name': model.symbol.name,
          'identity': [for (final field in model.identity.fields) field.name],
          'fields': [
            for (final field in model.fields)
              {
                'name': field.symbol.name,
                'type': _valueType(field.valueType),
                'nullable': field.nullable,
              },
          ],
        },
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(contract)}\n';
}

Object _valueType(FieldValueType type) => switch (type) {
  ScalarValueType(:final scalar) => {
    'kind': 'scalar',
    'name': _scalarName(scalar),
  },
  EnumValueType(:final enumSymbol) => {'kind': 'enum', 'name': enumSymbol.name},
  ScalarListValueType(:final element) => {
    'kind': 'list',
    'element': {'kind': 'scalar', 'name': _scalarName(element)},
  },
};

String _scalarName(ScalarType type) => switch (type) {
  ScalarType.string => 'string',
  ScalarType.boolean => 'boolean',
  ScalarType.int => 'int',
  ScalarType.float => 'float',
  ScalarType.dateTime => 'dateTime',
  ScalarType.uuid => 'uuid',
};
