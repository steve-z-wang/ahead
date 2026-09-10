import 'dart:convert';
import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';

/// The generated Dart runtime's own account of every Model, printed as
/// JSON so the shared matrix can compare it with the language-neutral contract
/// and the generated Backend bindings
/// (`model-generation/typescript/shared-model-contract.spec.ts`).
///
/// It is read out of the assembled sync registry rather than the declaration
/// files, because the registry is what the runtime actually consults: a Model
/// the compiler declared but never registered would be invisible here, which is
/// exactly the drift worth catching.
///
///     dart run model-generation/dart/model_manifest.dart
Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'local_sync_manifest_',
  );
  try {
    final database = await localSyncDatabaseDriver(
      path: '${directory.path}/local-sync.sqlite',
    ).open();
    try {
      stdout.writeln(
        jsonEncode({
          'models': modelManifest(
            buildModelRegistry(LocalDatabaseScope(database)),
          ),
        }),
      );
    } finally {
      await database.close();
    }
  } finally {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Every Model, by name, in the shape all three projections share.
///
/// Every generated Model is registered and none carries a mode: a Model
/// describes a row shape and says nothing about replication (CAP-488), so
/// there is nothing to filter here.
List<Map<String, Object?>> modelManifest(ModelRegistry registry) =>
    [for (final entry in registry.entries) _model(entry.schema)]..sort(
      (left, right) =>
          (left['name']! as String).compareTo(right['name']! as String),
    );

Map<String, Object?> _model(ModelSchema<ModelId> schema) => {
  'name': schema.name,
  // Identity order is the order the composite was declared in, and it is the
  // one order that carries meaning; fields are sorted because the generated
  // Backend contract sorts them and no consumer reads a field by position.
  'identity': schema.identity,
  'fields': [for (final field in schema.fields) _field(field)]
    ..sort(
      (left, right) =>
          (left['name']! as String).compareTo(right['name']! as String),
    ),
};

Map<String, Object?> _field(ModelFieldSchema field) => {
  'name': field.name,
  'type': _type(field.type),
  'nullable': field.nullable,
};

Map<String, Object?> _type(LocalValueType type) => switch (type) {
  LocalScalarType() => {'kind': 'scalar', 'name': type.name},
  LocalEnumType() => {
    'kind': 'enum',
    'name': type.name,
    'values': type.values.toList(),
  },
  LocalScalarListType() => {
    'kind': 'list',
    'element': {'kind': 'scalar', 'name': type.element.name},
  },
};
