import 'dart:convert';
import 'compiler.dart';
import 'semantic/model_graph.dart';
import 'emit/backend/backend_contract.dart';
import 'emit/backend/backend_contract_builder.dart';

/// Durable input definitions. Current storage/Downlink models are deliberately
/// excluded: each version carries only the model shapes its slots consume.
final class MutationHistory {
  MutationHistory(this.mutations);
  final Map<String, Map<String, dynamic>> mutations;

  factory MutationHistory.capture(ModelGraph graph) => MutationHistory({
    for (final mutation in buildBackendContract(graph).mutations)
      mutation.name: {
        '${mutation.version}': _capture(
          buildBackendContract(graph),
          mutation,
          graph,
        ),
      },
  });

  factory MutationHistory.fromContract(BackendContract contract) =>
      MutationHistory({
        for (final mutation in contract.mutations)
          mutation.name: {
            '${mutation.version}': _capture(contract, mutation, null),
          },
      });

  factory MutationHistory.decode(String source) {
    final value = jsonDecode(source) as Map<String, dynamic>;
    if (value['formatVersion'] != 1)
      throw const CompilerException('unsupported mutation history format');
    return MutationHistory({
      for (final entry in (value['mutations'] as Map<String, dynamic>).entries)
        entry.key: Map<String, dynamic>.from(entry.value as Map),
    });
  }

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert({'formatVersion': 1, 'mutations': mutations})}\n';

  MutationHistory reconcile(ModelGraph graph) {
    final next = MutationHistory.decode(encode());
    final current = MutationHistory.capture(graph);
    for (final name in mutations.keys) {
      if (!current.mutations.containsKey(name))
        throw CompilerException('retained mutation $name cannot be removed');
    }
    for (final entry in current.mutations.entries) {
      final version = entry.value.keys.single;
      final candidate = entry.value[version] as Map<String, dynamic>;
      final retained = next.mutations.putIfAbsent(entry.key, () => {});
      if (retained.isNotEmpty) {
        final latest = retained.keys
            .map(int.parse)
            .reduce((a, b) => a > b ? a : b);
        if (int.parse(version) < latest)
          throw CompilerException(
            '${entry.key}: mutation version cannot decrease from $latest',
          );
        if (retained.containsKey(version) &&
            !_compatible(
              retained[version] as Map<String, dynamic>,
              candidate,
            )) {
          throw CompilerException(
            '${entry.key} v$version input changed incompatibly; increase @@version',
          );
        }
      }
      retained[version] = candidate;
    }
    // Historical queue readiness invokes today's generated handler registry.
    // A declaration used by any retained version must therefore stay callable.
    for (final versions in next.mutations.values) {
      for (final raw in versions.values) {
        final mutation = raw as Map;
        for (final model in (mutation['input']['models'] as Map).values) {
          final fields = {
            for (final field in model['fields'] as List) field['name']: field,
          };
          for (final field in fields.values) {
            final requirement = field['prerequisite'] as Map?;
            if (requirement == null) continue;
            final declaration = graph.prerequisites
                .where((p) => p.symbol.name == requirement['name'])
                .firstOrNull;
            final arguments = requirement['arguments'] as Map;
            if (declaration == null ||
                declaration.parameters.length != arguments.length ||
                declaration.parameters.any((parameter) {
                  final source = fields[arguments[parameter.name]];
                  return source == null ||
                      source['type']['kind'] != 'scalar' ||
                      source['type']['name'] != parameter.type.name;
                })) {
              throw CompilerException(
                '${mutation['name']} v${mutation['version']} '
                'still requires prerequisite ${requirement['name']} with its original signature',
              );
            }
          }
        }
      }
    }
    return next;
  }
}

Map<String, dynamic> _capture(
  BackendContract contract,
  BackendMutationContract mutation,
  ModelGraph? graph,
) {
  final names = mutation.slots.map((s) => s.model).toSet();
  final models = [
    for (final model in contract.models.where((m) => names.contains(m.name)))
      BackendModelContract(
        name: model.name,
        identity: model.identity,
        fields: model.fields.where(
          (field) =>
              model.identity.contains(field) ||
              mutation.slots.any(
                (slot) =>
                    slot.model == model.name &&
                    (slot.operation == MutationOperationKind.create ||
                        (slot.allowedPatchFields?.contains(field.name) ??
                            false)),
              ),
        ),
      ),
  ];
  final enumNames = {
    for (final model in models)
      for (final field in model.fields)
        if (field.type case BackendEnumFieldType(:final name)) name,
  };
  return {
    'name': mutation.name,
    'version': mutation.version,
    'slots': [
      for (final slot in mutation.slots)
        {
          'name': slot.name,
          'model': slot.model,
          'operation': slot.operation.name,
          'cardinality': slot.cardinality.name,
          if (slot.allowedPatchFields != null)
            'allowedPatchFields': slot.allowedPatchFields,
          if (slot.bindings.isNotEmpty)
            'bindings': [
              for (final b in slot.bindings)
                {'relation': b.relation, 'fields': b.fields, 'slot': b.slot},
            ],
        },
    ],
    'input': {
      'enumValues': {
        for (final e in contract.enums)
          if (enumNames.contains(e.name)) e.name: e.values,
      },
      'models': {
        for (final model in models)
          _lower(model.name): {
            'name': model.name,
            'identityFields': model.identity.map((f) => f.name).toList(),
            'knownFields': contract.models
                .singleWhere((m) => m.name == model.name)
                .fields
                .map((f) => f.name)
                .toList(),
            'fields': [
              for (final field in model.fields)
                {
                  'name': field.name,
                  'nullable': field.nullable,
                  'identity': model.identity.contains(field),
                  'type': switch (field.type) {
                    BackendScalarFieldType(:final scalar) => {
                      'kind': 'scalar',
                      'name': scalar.name,
                    },
                    BackendEnumFieldType(:final name) => {
                      'kind': 'enum',
                      'name': name,
                    },
                    BackendScalarListFieldType(:final element) => {
                      'kind': 'list',
                      'element': element.name,
                    },
                  },
                  if (graph?.models
                          .singleWhere((m) => m.symbol.name == model.name)
                          .fields
                          .singleWhere((f) => f.symbol.name == field.name)
                          .prerequisite
                      case final requirement?)
                    'prerequisite': {
                      'name': requirement.prerequisite.name,
                      'arguments': {
                        for (final key in requirement.arguments.keys)
                          key: field.name,
                      },
                    },
                },
            ],
          },
      },
    },
  };
}

bool _compatible(Map<String, dynamic> old, Map<String, dynamic> next) {
  // Slot execution order and bindings are meaning, not merely validation.
  final aSlots = old['slots'] as List;
  final bSlots = next['slots'] as List;
  if (aSlots.length != bSlots.length) return false;
  for (var i = 0; i < aSlots.length; i++) {
    final a = Map<String, dynamic>.from(aSlots[i] as Map),
        b = Map<String, dynamic>.from(bSlots[i] as Map);
    final aPatch = a.remove('allowedPatchFields') as List?,
        bPatch = b.remove('allowedPatchFields') as List?;
    if (jsonEncode(a) != jsonEncode(b)) return false;
    if (aPatch != null && (bPatch == null || !aPatch.every(bPatch.contains)))
      return false;
  }
  final a = old['input'] as Map, b = next['input'] as Map;
  for (final entry in (a['enumValues'] as Map).entries) {
    final values = (b['enumValues'] as Map)[entry.key] as List?;
    if (values == null || !(entry.value as List).every(values.contains))
      return false;
  }
  for (final entry in (a['models'] as Map).entries) {
    final before = entry.value as Map,
        after = (b['models'] as Map)[entry.key] as Map?;
    if (after == null ||
        jsonEncode(before['identityFields']) !=
            jsonEncode(after['identityFields']))
      return false;
    final fields = {
      for (final f in before['fields'] as List) (f as Map)['name']: f,
    };
    final updated = {
      for (final f in after['fields'] as List) (f as Map)['name']: f,
    };
    for (final f in fields.entries) {
      if (jsonEncode(f.value) != jsonEncode(updated[f.key])) return false;
    }
    final createsModel = bSlots.any(
      (slot) => slot['model'] == after['name'] && slot['operation'] == 'create',
    );
    for (final f in updated.entries) {
      if (createsModel &&
          !fields.containsKey(f.key) &&
          f.value['nullable'] != true)
        return false;
    }
  }
  return true;
}

String _lower(String name) => name[0].toLowerCase() + name.substring(1);
