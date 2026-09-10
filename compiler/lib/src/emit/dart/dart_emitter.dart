import 'dart:convert';
import '../../mutation_history.dart';
import '../../semantic/model_graph.dart';
import 'dart_names.dart';

Map<String, String> emitDart(ModelGraph graph, {MutationHistory? history}) {
  history ??= MutationHistory.capture(graph);
  final output = <String, String>{
    'composition.dart': _emitComposition(graph),
    'downlink_changes.dart': _emitDownlinkChanges(graph),
    'enums.dart': _emitEnums(graph),
    'local_sync.dart': _emitFacade(graph),
    'local_sync_database.dart': _emitDatabase(graph),
    'model_registry.dart': _emitModelRegistry(graph),
    'models.dart': _emitModelsComposition(graph),
    'mutations.dart': _emitMutations(graph),
    'mutation_input_contracts.dart': _emitMutationInputs(history),
  };
  for (final model in graph.models) {
    final file = dartFileName(model.symbol.name);
    output['models/$file.dart'] = _emitModel(graph, model);
    output['storage/$file.dart'] = _emitTable(model);
  }
  final entries = output.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  return Map.unmodifiable({
    for (final entry in entries) entry.key: entry.value,
  });
}

String _emitFacade(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'dart:async';")
    ..writeln("import 'dart:math';")
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';")
    ..writeln("import 'package:local_sync_database/local_sync_database.dart';")
    ..writeln()
    ..writeln("import 'composition.dart';")
    ..writeln("import 'downlink_changes.dart';")
    ..writeln("import 'model_registry.dart';")
    ..writeln("import 'models.dart';")
    ..writeln("import 'mutations.dart';");
  buffer
    ..writeln()
    ..writeln(
      "export 'package:local_sync/local_sync.dart' "
      'show UUID, FieldUpdate, ModelQuery, ReactiveModelQuery, '
      'LocalSyncTransaction, LocalSyncMutationScope, '
      'LocalSyncClientFailure, LocalSyncClientFailureBoundary, '
      'LocalSyncClientFailureFate, LocalSyncClientFailureObserver, '
      'LocalSyncMutations, LocalSyncMutationRejection, '
      'LocalSyncMutationRejectionId, LocalSyncRejectedOperation, '
      'LocalSyncRejectedScope, MutationOperation, '
      'LocalSyncOperationSnapshot, TransactionPrerequisites, TransactionMutationsInbox, '
      'LocalSyncPrerequisites, LocalSyncPrerequisiteFailure, '
      'LocalSyncPrerequisiteFailureId, LocalSyncFailedPrerequisite, '
      'LocalSyncPrerequisiteBinding, PrerequisiteInvocation;',
    )
    ..writeln("export 'enums.dart';")
    ..writeln(
      "export 'local_sync_database.dart' "
      'show localSyncCurrentSchemaStatements;',
    )
    ..writeln("export 'models.dart';")
    ..writeln("export 'mutations.dart';");
  buffer.writeln("export 'downlink_changes.dart';");
  for (final model in graph.models) {
    buffer.writeln("export 'models/${dartFileName(model.symbol.name)}.dart';");
  }
  if (graph.prerequisites.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('final class LocalSyncPrerequisiteHandlers {')
      ..writeln('  const LocalSyncPrerequisiteHandlers({');
    for (final prerequisite in graph.prerequisites) {
      buffer.writeln(
        '    required this.${lowerCamel(prerequisite.symbol.name)},',
      );
    }
    buffer.writeln('  });');
    for (final prerequisite in graph.prerequisites) {
      buffer
        ..writeln()
        ..writeln('  final Future<PrerequisiteAttemptResult> Function({');
      for (final parameter in prerequisite.parameters) {
        buffer.writeln(
          '    required ${_prerequisiteDartType(parameter.type)} ${parameter.name},',
        );
      }
      buffer.writeln('  }) ${lowerCamel(prerequisite.symbol.name)};');
    }
    buffer
      ..writeln('}')
      ..writeln()
      ..writeln('PrerequisiteHandlerRegistry buildPrerequisiteHandlers(')
      ..writeln('  LocalSyncPrerequisiteHandlers handlers,')
      ..writeln(') => PrerequisiteHandlerRegistry({');
    for (final prerequisite in graph.prerequisites) {
      buffer.writeln(
        "  '${prerequisite.symbol.name}': (arguments) => handlers.${lowerCamel(prerequisite.symbol.name)}(",
      );
      for (final parameter in prerequisite.parameters) {
        buffer.writeln(
          "    ${parameter.name}: arguments['${parameter.name}']! as ${_prerequisiteDartType(parameter.type)},",
        );
      }
      buffer.writeln('  ),');
    }
    buffer.writeln('});');
  }
  buffer
    ..writeln()
    ..writeln(
      'final class LocalSync '
      'extends LocalSyncRuntime<Models, TransactionModels, '
      'TransactionMutations> {',
    )
    ..writeln(
      '  LocalSync._(Database database, LocalDatabaseScope scope, '
      'ModelRegistry registry, GeneratedModelRuntimes runtimes, '
      'LocalSyncLifecycle lifecycle, '
      'TransactionContextFactory<TransactionModels, TransactionMutations> '
      'transactionContexts, ScopeReconciler scopeReconciler)',
    )
    ..writeln('      : super(')
    ..writeln('          models: buildModels(runtimes),')
    ..writeln('          database: scope,')
    ..writeln('          registry: registry,')
    ..writeln('          closeDatabase: () => lifecycle.close(database.close),')
    ..writeln('          transactionContexts: transactionContexts,')
    ..writeln('          scopeReconciler: scopeReconciler,')
    ..writeln('        );')
    ..writeln();
  buffer
    ..writeln('  static Future<LocalSync> open({')
    ..writeln('    required DatabaseDriver driver,')
    ..writeln('    required String clientId,')
    ..writeln('    required LocalSyncTransport transport,')
    ..writeln('    LocalSyncClientFailureObserver? failureObserver,')
    ..writeln('    FutureOr<void> Function(')
    ..writeln(
      '      LocalSyncTransaction<TransactionModels, TransactionMutations> tx,',
    )
    ..writeln('      LocalSyncDownlinkChanges changes,')
    ..writeln('    )? onDownlinkApplied,')
    ..write(
      graph.prerequisites.isEmpty
          ? ''
          : '    required LocalSyncPrerequisiteHandlers prerequisites,\n',
    )
    ..writeln('  }) async {')
    ..writeln('    final database = await driver.open();')
    ..writeln(
      graph.prerequisites.isEmpty
          ? '    return _open(database, clientId, transport, failureObserver, '
                'onDownlinkApplied);'
          : '    return _open(database, clientId, transport, failureObserver, '
                'prerequisites, '
                'onDownlinkApplied);',
    )
    ..writeln('  }')
    ..writeln()
    ..writeln(
      '  static Future<LocalSync> _open(Database database, ' +
          (graph.prerequisites.isEmpty
              ? 'String clientId, LocalSyncTransport transport, '
                    'LocalSyncClientFailureObserver? failureObserver, '
                    'FutureOr<void> Function('
                    'LocalSyncTransaction<TransactionModels, '
                    'TransactionMutations>, LocalSyncDownlinkChanges)? '
                    'onDownlinkApplied) async {'
              : 'String clientId, LocalSyncTransport transport, '
                    'LocalSyncClientFailureObserver? failureObserver, '
                    'LocalSyncPrerequisiteHandlers prerequisites, '
                    'FutureOr<void> Function('
                    'LocalSyncTransaction<TransactionModels, '
                    'TransactionMutations>, LocalSyncDownlinkChanges)? '
                    'onDownlinkApplied) async {'),
    )
    ..writeln('    final scope = LocalDatabaseScope(database);')
    ..writeln('    try {')
    ..writeln("      await database.query(DatabaseQuery(sql: 'SELECT 1')); ")
    ..writeln('      final registry = buildModelRegistry(scope);')
    ..writeln(
      '      final runtimes = '
      'buildModelRuntimes(scope, registry: registry);',
    )
    ..writeln('      final transactionContexts = buildTransactionContexts(')
    ..writeln('        scope, registry, runtimes,')
    ..writeln('      );')
    ..writeln('      final queue = MutationQueue(scope, registry: registry);')
    ..writeln('      await queue.initialize(clientId);')
    ..writeln('      final codec = LocalSyncJsonCodec(registry: registry);')
    ..writeln('      final prerequisiteRunner = PrerequisiteRunner(')
    ..writeln('        ledger: ReadinessLedger(scope),')
    ..writeln(
      graph.prerequisites.isEmpty
          ? '        handlers: PrerequisiteHandlerRegistry({}),'
          : '        handlers: buildPrerequisiteHandlers(prerequisites),',
    )
    ..writeln('        retryDelay: (attempt) => RetryPolicy.delayForAttempt(')
    ..writeln('          attempt: attempt,')
    ..writeln('          random: Random().nextDouble(),')
    ..writeln('        ),')
    ..writeln('        failureObserver: failureObserver,')
    ..writeln('      );')
    ..writeln('      final batchExecutor = BatchExecutor(')
    ..writeln('        codec: codec,')
    ..writeln('        transport: transport,')
    ..writeln('        retryPolicy: RetryPolicy(')
    ..writeln('          randomDouble: Random().nextDouble,')
    ..writeln('        ),')
    ..writeln('        failureObserver: failureObserver,')
    ..writeln('      );')
    ..writeln('      final downlinkProcessor = DownlinkPageProcessor(')
    ..writeln('        database: scope,')
    ..writeln('        registry: registry,')
    ..writeln('        decoder: ModelChangeDecoder(registry),')
    ..writeln('        onApplied: onDownlinkApplied == null')
    ..writeln('            ? null')
    ..writeln('            : (changes) => transactionContexts.run(')
    ..writeln('                (tx) async => onDownlinkApplied(')
    ..writeln('                  tx, materializeDownlinkChanges(changes),')
    ..writeln('                ),')
    ..writeln('              ),')
    ..writeln('      );')
    ..writeln('      final uplinkController = UplinkController(')
    ..writeln('        queue: queue,')
    ..writeln('        codec: codec,')
    ..writeln('        scheduler: const MutationScheduler(')
    ..writeln('          maxBytes: maximumUplinkBatchBytes,')
    ..writeln('        ),')
    ..writeln('        prerequisiteRunner: prerequisiteRunner,')
    ..writeln('        executor: batchExecutor,')
    ..writeln('        settleAccepted: downlinkProcessor.settleAccepted,')
    ..writeln('        failureObserver: failureObserver,')
    ..writeln('      );')
    ..writeln('      final downlinkWorker = DownlinkWorker(')
    ..writeln('        state: downlinkProcessor,')
    ..writeln('        processor: downlinkProcessor,')
    ..writeln('        transport: transport,')
    ..writeln('        codec: codec,')
    ..writeln('        retryPolicyFactory: () => RetryPolicy(')
    ..writeln('          randomDouble: Random().nextDouble,')
    ..writeln('        ),')
    ..writeln('        failureObserver: failureObserver,')
    ..writeln('      );')
    ..writeln('      final lifecycle = LocalSyncLifecycle(')
    ..writeln('        uplinkWorker: uplinkController,')
    ..writeln('        downlinkWorker: downlinkWorker,')
    ..writeln('        transport: transport,')
    ..writeln(
      '        bindLegacyCheckpointScope: queue.bindLegacyCheckpointScope,',
    )
    ..writeln('      );')
    ..writeln('      final scopeReconciler = ScopeReconciler(')
    ..writeln('        store: ScopeStore(scope),')
    ..writeln(
      '        replaceScopes: (scopes) => lifecycle.replaceScopes(scopes),',
    )
    ..writeln('        failureObserver: failureObserver,')
    ..writeln('      );')
    ..writeln(
      '      final localSync = '
      'LocalSync._(database, scope, registry, runtimes, lifecycle, '
      'transactionContexts, scopeReconciler);',
    )
    ..writeln('      return localSync;')
    ..writeln('    } catch (_) {')
    ..writeln('      await LocalSyncLifecycle.closeAfterOpenFailure(')
    ..writeln('        transport: transport,')
    ..writeln('        closeDatabase: database.close,')
    ..writeln('      );')
    ..writeln('      rethrow;')
    ..writeln('    }')
    ..writeln('  }')
    ..writeln('}');
  return buffer.toString();
}

String _emitEnums(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';");
  for (final definition in graph.enums) {
    final name = definition.symbol.name;
    final values = definition.values.map((value) => value.name).toList();
    buffer
      ..writeln()
      ..writeln('enum $name { ${values.join(', ')} }')
      ..writeln()
      ..writeln('String _encode$name(Object value) => (value as $name).name;')
      ..writeln()
      ..writeln(
        'Object _decode$name(String wire) => $name.values.byName(wire);',
      )
      ..writeln()
      ..writeln('const ${lowerCamel(name)}Type = LocalEnumType(')
      ..writeln("  name: '$name',")
      ..writeln("  values: {${values.map((value) => "'$value'").join(', ')}},")
      ..writeln('  encode: _encode$name,')
      ..writeln('  decode: _decode$name,')
      ..writeln(');');
  }
  return buffer.toString();
}

String _emitModel(ModelGraph graph, ModelDefinition model) {
  final name = model.symbol.name;
  final identityFields = model.identity.fields
      .map((symbol) => model.field(symbol))
      .toList();
  final valueFields = model.fields
      .where((field) => !_isHiddenIdentityField(model, field))
      .toList();
  final mutableFields = model.fields
      .where((field) => !model.identity.fields.contains(field.symbol))
      .toList();
  final listFields = valueFields
      .where((field) => field.valueType is ScalarListValueType)
      .toList();
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';");
  if (_usesEnums(model)) {
    buffer.writeln("import '../enums.dart';");
  }
  buffer..writeln();

  _writeId(buffer, name, identityFields);
  buffer.writeln();
  _writeSchema(buffer, model);
  buffer.writeln();
  _writeFields(buffer, model);
  buffer.writeln();

  buffer
    ..writeln('base class $name extends Model<${name}Id> {')
    ..write('  ${listFields.isEmpty ? 'const ' : ''}$name({required this.id');
  for (final field in valueFields) {
    final parameter = field.valueType is ScalarListValueType
        ? '${_dartType(field.valueType)} ${field.symbol.name}'
        : 'this.${field.symbol.name}';
    buffer.write(', required $parameter');
  }
  if (listFields.isEmpty) {
    buffer.writeln('});');
  } else {
    buffer
      ..writeln('})')
      ..writeln(
        '      : ${listFields.map((field) => '${field.symbol.name} = List.unmodifiable(${field.symbol.name})').join(', ')};',
      );
  }
  buffer
    ..writeln()
    ..writeln('  @override')
    ..writeln('  final ${name}Id id;');
  for (final field in valueFields) {
    buffer.writeln(
      '  final ${_dartType(field.valueType, nullable: field.nullable)} '
      '${field.symbol.name};',
    );
  }
  _writeCreateBuilder(buffer, model, mutableFields);
  _writeOperationBuilders(buffer, model, mutableFields);
  buffer.writeln('}');
  buffer.writeln();
  _writeOperationValues(buffer, model);
  _writeCollections(buffer, model, valueFields);
  return buffer.toString();
}

/// The static half of the operation vocabulary: `create` names an identity
/// that does not exist yet, so it cannot be an instance method.
void _writeCreateBuilder(
  StringBuffer buffer,
  ModelDefinition model,
  List<ModelFieldDefinition> mutableFields,
) {
  final name = model.symbol.name;
  buffer
    ..writeln()
    ..writeln('  static ${name}Create create({');
  for (final field in model.fields) {
    buffer.writeln(
      '    required ${_dartType(field.valueType, nullable: field.nullable)} '
      '${field.symbol.name},',
    );
  }
  buffer
    ..writeln('  }) => ${name}Create._(')
    ..writeln('    id: ${_identityExpression(model)},')
    ..writeln('    values: {')
    ..writeAll(
      mutableFields.map(
        (field) => "      '${field.symbol.name}': ${field.symbol.name},\n",
      ),
    )
    ..writeln('    },')
    ..writeln('  );');
}

/// The instance half — `row.update(...)` and `row.delete()`, building values
/// from a row that was necessarily read first.
void _writeOperationBuilders(
  StringBuffer buffer,
  ModelDefinition model,
  List<ModelFieldDefinition> mutableFields,
) {
  final name = model.symbol.name;
  if (mutableFields.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('  ${name}Update update({');
    for (final field in mutableFields) {
      final type = _dartType(field.valueType, nullable: field.nullable);
      if (field.nullable) {
        buffer.writeln('    FieldUpdate<$type>? ${field.symbol.name},');
      } else {
        buffer.writeln('    $type? ${field.symbol.name},');
      }
    }
    buffer
      ..writeln('  }) => ${name}Update._(')
      ..writeln('    id: id,')
      ..writeln('    patch: {')
      ..writeAll(
        mutableFields.map((field) {
          final field_ = field.symbol.name;
          return field.nullable
              ? "      if ($field_ != null) '$field_': $field_.value,\n"
              : "      if ($field_ != null) '$field_': $field_,\n";
        }),
      )
      ..writeln('    },')
      ..writeln('  );');
  }
  buffer
    ..writeln()
    ..writeln('  ${name}Delete delete() => ${name}Delete._(id: id);');
}

/// One exact type per `(Model, op)` pair. A slot declared `MomentPhoto.create`
/// accepts nothing else, which is what makes a resolver's slot field precise
/// without an `op` discriminator anywhere.
void _writeOperationValues(StringBuffer buffer, ModelDefinition model) {
  final name = model.symbol.name;
  buffer
    ..writeln('final class ${name}Create extends ModelCreateOperation {')
    ..writeln(
      '  ${name}Create._({required ${name}Id id, '
      'required Map<String, Object?> values})',
    )
    ..writeln("      : super(model: '$name', id: id, values: values);")
    ..writeln('}')
    ..writeln()
    ..writeln('final class ${name}Update extends ModelUpdateOperation {')
    ..writeln(
      '  ${name}Update._({required ${name}Id id, '
      'required Map<String, Object?> patch})',
    )
    ..writeln("      : super(model: '$name', id: id, patch: patch);")
    ..writeln('}')
    ..writeln()
    ..writeln('final class ${name}Delete extends ModelDeleteOperation {')
    ..writeln('  const ${name}Delete._({required ${name}Id id})')
    ..writeln("      : super(model: '$name', id: id);")
    ..writeln('}')
    ..writeln();
}

/// Builds the generated identity from the create call's raw components.
String _identityExpression(ModelDefinition model) {
  final name = model.symbol.name;
  if (model.identity.fields.length == 1) {
    return '${name}Id(${model.identity.fields.single.name})';
  }
  final components = model.identity.fields
      .map((field) => '      ${field.name}: ${field.name},')
      .join('\n');
  return '${name}Id(\n$components\n    )';
}

void _writeId(
  StringBuffer buffer,
  String modelName,
  List<ModelFieldDefinition> identity,
) {
  buffer.writeln('final class ${modelName}Id extends ModelId {');
  if (identity.length == 1) {
    final field = identity.single;
    buffer
      ..writeln('  const ${modelName}Id(this.value);')
      ..writeln()
      ..writeln('  final ${_dartType(field.valueType)} value;')
      ..writeln()
      ..writeln('  @override')
      ..writeln(
        "  Map<String, Object> get components => {'${field.symbol.name}': value};",
      )
      ..writeln()
      ..writeln('  @override')
      ..writeln('  bool operator ==(Object other) =>')
      ..writeln('      other is ${modelName}Id && other.value == value;')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  int get hashCode => value.hashCode;');
  } else {
    buffer
      ..writeln('  const ${modelName}Id({')
      ..writeAll(
        identity.map((field) => '    required this.${field.symbol.name},\n'),
      )
      ..writeln('  });')
      ..writeln();
    for (final field in identity) {
      buffer.writeln(
        '  final ${_dartType(field.valueType)} ${field.symbol.name};',
      );
    }
    buffer
      ..writeln()
      ..writeln('  @override')
      ..writeln('  Map<String, Object> get components => {')
      ..writeAll(
        identity.map(
          (field) => "    '${field.symbol.name}': ${field.symbol.name},\n",
        ),
      )
      ..writeln('  };')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  bool operator ==(Object other) =>')
      ..writeln('      other is ${modelName}Id &&')
      ..writeln(
        identity
            .map(
              (field) =>
                  '          other.${field.symbol.name} == ${field.symbol.name}',
            )
            .join(' &&\n'),
      )
      ..writeln(';')
      ..writeln()
      ..writeln('  @override')
      ..writeln(
        '  int get hashCode => Object.hash('
        '${identity.map((field) => field.symbol.name).join(', ')});',
      );
  }
  buffer.writeln('}');
}

void _writeSchema(StringBuffer buffer, ModelDefinition model) {
  final name = model.symbol.name;
  for (final relation in model.relations) {
    buffer
      ..writeln(
        'const ${_relationSchemaName(model, relation)} = ModelRelationSchema(',
      )
      ..writeln("  name: '${relation.symbol.name}',")
      ..writeln("  targetModel: '${relation.target.name}',");
    if (relation.relationName != null) {
      buffer.writeln("  relationName: '${relation.relationName}',");
    }
    buffer
      ..writeln(
        '  localFields: [${relation.localFields.map((field) => "'${field.name}'").join(', ')}],',
      )
      ..writeln(
        '  referencedFields: [${relation.referencedFields.map((field) => "'${field.name}'").join(', ')}],',
      )
      ..writeln('  nullable: ${relation.nullable},')
      ..writeln('  deleteOnTarget: ${relation.deleteOnTarget},')
      ..writeln(');')
      ..writeln();
  }
  // The reverse halves are metadata and nothing else: they are emitted here,
  // beside the references, and they appear in no table, no wire field, and no
  // migration — `model.fields` never held them (CAP-437).
  for (final inverse in model.inverses) {
    buffer
      ..writeln(
        'const ${_inverseSchemaName(model, inverse)} = '
        'ModelInverseRelationSchema(',
      )
      ..writeln("  name: '${inverse.symbol.name}',")
      ..writeln("  sourceModel: '${inverse.target.name}',")
      ..writeln("  reference: '${inverse.reference.name}',");
    if (inverse.relationName != null) {
      buffer.writeln("  relationName: '${inverse.relationName}',");
    }
    buffer
      ..writeln(
        '  cardinality: ModelRelationCardinality.${inverse.cardinality.name},',
      )
      ..writeln(');')
      ..writeln();
  }
  buffer
    ..writeln('final ${lowerCamel(name)}Schema = ModelSchema<${name}Id>(')
    ..writeln("  name: '$name',")
    ..writeln(
      '  identity: const [${model.identity.fields.map((field) => "'${field.name}'").join(', ')}],',
    )
    ..writeln('  fields: const [');
  for (final field in model.fields) {
    buffer
      ..writeln('    ModelFieldSchema(')
      ..writeln("      name: '${field.symbol.name}',")
      ..writeln('      type: ${_schemaValueType(field.valueType)},')
      ..writeln('      nullable: ${field.nullable},')
      ..write(
        field.prerequisite == null ? '' : _prerequisiteRequirementSchema(field),
      )
      ..writeln('    ),');
  }
  buffer
    ..writeln('  ],')
    ..writeln('  uniqueConstraints: const [');
  for (final constraint in model.uniqueConstraints) {
    buffer.writeln(
      '    ModelUniqueConstraintSchema('
      '[${constraint.fields.map((field) => "'${field.name}'").join(', ')}]),',
    );
  }
  buffer
    ..writeln('  ],')
    ..writeln('  relations: const [');
  for (final relation in model.relations) {
    buffer.writeln('    ${_relationSchemaName(model, relation)},');
  }
  buffer
    ..writeln('  ],')
    ..writeln('  inverseRelations: const [');
  for (final inverse in model.inverses) {
    buffer.writeln('    ${_inverseSchemaName(model, inverse)},');
  }
  buffer
    ..writeln('  ],')
    ..writeln('  createId: (components) => ${name}Id(');
  if (model.identity.fields.length == 1) {
    final field = model.field(model.identity.fields.single);
    buffer.writeln(
      "    components['${field.symbol.name}']! as ${_dartType(field.valueType)},",
    );
  } else {
    for (final symbol in model.identity.fields) {
      final field = model.field(symbol);
      buffer.writeln(
        "    ${field.symbol.name}: components['${field.symbol.name}']! "
        'as ${_dartType(field.valueType)},',
      );
    }
  }
  buffer
    ..writeln('  ),')
    ..writeln(');');
}

String _prerequisiteRequirementSchema(ModelFieldDefinition field) {
  final requirement = field.prerequisite!;
  return '''      prerequisite: ModelPrerequisiteRequirementSchema(
        name: '${requirement.prerequisite.name}',
        arguments: const {
${requirement.arguments.keys.map((name) => "          '$name': '${field.symbol.name}',").join('\n')}
        },
      ),
''';
}

String _prerequisiteDartType(ScalarType type) => switch (type) {
  ScalarType.string => 'String',
  ScalarType.boolean => 'bool',
  ScalarType.int => 'int',
  ScalarType.float => 'double',
  ScalarType.dateTime => 'DateTime',
  ScalarType.uuid => 'UUID',
};

String _relationSchemaName(
  ModelDefinition model,
  RelationDefinition relation,
) =>
    '${lowerCamel(model.symbol.name)}'
    '${_upperFirst(relation.symbol.name)}Relation';

String _inverseSchemaName(
  ModelDefinition model,
  InverseRelationDefinition inverse,
) =>
    '${lowerCamel(model.symbol.name)}'
    '${_upperFirst(inverse.symbol.name)}Inverse';

String _upperFirst(String value) =>
    '${value.substring(0, 1).toUpperCase()}${value.substring(1)}';

void _writeFields(StringBuffer buffer, ModelDefinition model) {
  final name = model.symbol.name;
  buffer
    ..writeln('final class ${name}Fields {')
    ..writeln('  const ${name}Fields();')
    ..writeln()
    ..writeln(
      '  ModelField<${name}Id> get id => const ModelIdentityField<${name}Id>();',
    );
  for (final field in model.fields) {
    if (_isHiddenIdentityField(model, field)) continue;
    buffer.writeln(
      "  ModelField<${_dartType(field.valueType, nullable: field.nullable)}> "
      "get ${field.symbol.name} => const SchemaModelField('${field.symbol.name}');",
    );
  }
  buffer.writeln('}');
}

void _writeCollections(
  StringBuffer buffer,
  ModelDefinition model,
  List<ModelFieldDefinition> valueFields,
) {
  final name = model.symbol.name;
  buffer
    ..writeln(
      '$name _materialize$name(ModelRecord<${name}Id> record) => $name(',
    )
    ..writeln('  id: record.id,');
  for (final field in valueFields) {
    buffer.writeln(
      '  ${field.symbol.name}: ${_recordFieldExpression(model, field)},',
    );
  }
  buffer
    ..writeln(');')
    ..writeln()
    ..writeln('final class ${name}Collection extends ')
    ..writeln('    ReactiveModelCollection<$name, ${name}Id, ${name}Fields> {')
    ..writeln('  ${name}Collection({required ModelReader<${name}Id> reader})')
    ..writeln('      : super(')
    ..writeln('          reader: reader,')
    ..writeln('          materialize: _materialize$name,')
    ..writeln('          fields: const ${name}Fields(),')
    ..writeln('        );')
    ..writeln('}')
    ..writeln();
  _writeTransactionCollection(buffer, model, valueFields);
}

/// The Model as a write callback holds it: transaction-scoped reads plus the
/// three typed write verbs, with no `watch` (CAP-488).
///
/// Which scope the write takes is selected at the operation boundary — direct
/// on the outer transaction, a companion while a named act callback is active
/// — so the call site states intent by its transaction scope, never by a flag.
void _writeTransactionCollection(
  StringBuffer buffer,
  ModelDefinition model,
  List<ModelFieldDefinition> valueFields,
) {
  final name = model.symbol.name;
  final mutableFields = valueFields
      .where((field) => !model.identity.fields.contains(field.symbol))
      .toList();
  buffer
    ..writeln('final class ${name}TransactionCollection extends ')
    ..writeln(
      '    TransactionModelCollection<$name, ${name}Id, ${name}Fields> {',
    )
    ..writeln('  ${name}TransactionCollection({')
    ..writeln('    required TransactionModelReader<${name}Id> reader,')
    ..writeln('    required ModelWriter<${name}Id> writer,')
    ..writeln('  }) : super(')
    ..writeln('          reader: reader,')
    ..writeln('          writer: writer,')
    ..writeln('          materialize: _materialize$name,')
    ..writeln('          fields: const ${name}Fields(),')
    ..writeln('        );')
    ..writeln()
    ..writeln('  Future<void> create({');
  for (final field in model.fields) {
    buffer.writeln(
      '    required ${_dartType(field.valueType, nullable: field.nullable)} '
      '${field.symbol.name},',
    );
  }
  buffer
    ..writeln('  }) => writer.create(')
    ..writeln('    ${_identityExpression(model)},')
    ..writeln('    {')
    ..writeAll(
      mutableFields.map(
        (field) => "      '${field.symbol.name}': ${field.symbol.name},\n",
      ),
    )
    ..writeln('    },')
    ..writeln('  );');
  if (mutableFields.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('  Future<void> update({')
      ..writeln('    required ${name}Id id,');
    for (final field in mutableFields) {
      final type = _dartType(field.valueType, nullable: field.nullable);
      if (field.nullable) {
        buffer.writeln('    FieldUpdate<$type>? ${field.symbol.name},');
      } else {
        buffer.writeln('    $type? ${field.symbol.name},');
      }
    }
    buffer
      ..writeln('  }) => writer.update(id, {')
      ..writeAll(
        mutableFields.map((field) {
          final field_ = field.symbol.name;
          return field.nullable
              ? "      if ($field_ != null) '$field_': $field_.value,\n"
              : "      if ($field_ != null) '$field_': $field_,\n";
        }),
      )
      ..writeln('  });');
  }
  buffer
    ..writeln()
    ..writeln('  Future<void> delete(${name}Id id) => writer.delete(id);')
    ..writeln('}');
}

String _recordFieldExpression(
  ModelDefinition model,
  ModelFieldDefinition field,
) {
  if (model.identity.fields.contains(field.symbol)) {
    return 'record.id.components[\'${field.symbol.name}\']! as '
        '${_dartType(field.valueType, nullable: field.nullable)}';
  }
  if (field.valueType case ScalarListValueType(:final element)) {
    return 'List<${_dartScalarType(element)}>.unmodifiable('
        "(record.fields['${field.symbol.name}']! as List)"
        '.cast<${_dartScalarType(element)}>())';
  }
  return 'record.fields[\'${field.symbol.name}\'] as '
      '${_dartType(field.valueType, nullable: field.nullable)}';
}

String _emitTable(ModelDefinition model) {
  final name = model.symbol.name;
  final file = dartFileName(name);
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';")
    ..writeln("import 'package:local_sync_database/local_sync_database.dart';")
    ..writeln()
    ..writeln("import '../models/$file.dart';")
    ..writeln()
    ..writeln('final ${lowerCamel(name)}DatabaseDescriptor =')
    ..writeln('    ModelDatabaseDescriptor<${name}Id>(')
    ..writeln('      schema: ${lowerCamel(name)}Schema,')
    ..writeln("      tableName: 'model_$file',")
    ..writeln('      columns: const {');
  for (final field in model.fields) {
    buffer.writeln(
      "        '${field.symbol.name}': '${dartFileName(field.symbol.name)}',",
    );
  }
  buffer
    ..writeln('      },')
    ..writeln('    );');
  {
    // The before-image twin (CAP-393 spec §2): the truth to restore on
    // rejection, held for exactly the rows that currently carry pending
    // edits. Every Model carries one: any row a named act touches — as a
    // returned slot or as a companion — rolls back with it, and rollback
    // needs the value the act found (CAP-488).
    buffer
      ..writeln()
      ..writeln('final ${lowerCamel(name)}BeforeDatabaseDescriptor =')
      ..writeln('    ModelDatabaseDescriptor<${name}Id>(')
      ..writeln('      schema: ${lowerCamel(name)}Schema,')
      ..writeln("      tableName: 'model_${file}_before',")
      ..writeln('      columns: const {');
    for (final field in model.fields) {
      buffer.writeln(
        "        '${field.symbol.name}': '${dartFileName(field.symbol.name)}',",
      );
    }
    buffer
      ..writeln('      },')
      ..writeln('    );');
  }
  buffer
    ..writeln()
    ..writeln(
      'final ${lowerCamel(name)}DatabaseStatements = <DatabaseStatement>[',
    )
    ..writeln('  DatabaseStatement(')
    ..writeln("    sql: '''")
    ..writeln('      CREATE TABLE "model_$file" (');
  for (final field in model.fields) {
    final nullability = field.nullable ? '' : ' NOT NULL';
    buffer.writeln(
      '        "${dartFileName(field.symbol.name)}" '
      '${_sqliteType(field.valueType)}$nullability,',
    );
  }
  // No reference emits a constraint at all (CAP-407 spec §2, extending the
  // CAP-393 §6.1 cascade ruling to every edge): declarations drive framework
  // semantics, never database enforcement. The local store is a replica, and
  // a replica must tolerate arrival order — a row whose target has not been
  // claimed yet is a legal transient state, and a constraint that must be
  // violated transiently is not a constraint. `onTargetDelete: delete` is
  // apply code walking declared references and a bare `@reference` changes
  // nothing at all — the queue stays FIFO; neither ever reads the constraint.
  // Referential integrity is the server's: a write naming nothing is rejected
  // there and the before-image rolls it back, the settlement every rejection
  // gets.
  buffer
    ..writeln(
      '        PRIMARY KEY '
      '(${model.identity.fields.map((field) => '"${dartFileName(field.name)}"').join(', ')})',
    )
    ..writeln('      )')
    ..writeln("    ''',")
    ..writeln('  ),');
  {
    buffer
      ..writeln('  DatabaseStatement(')
      ..writeln("    sql: '''")
      ..writeln('      CREATE TABLE "model_${file}_before" (');
    for (final field in model.fields) {
      final nullability = field.nullable ? '' : ' NOT NULL';
      buffer.writeln(
        '        "${dartFileName(field.symbol.name)}" '
        '${_sqliteType(field.valueType)}$nullability,',
      );
    }
    buffer
      ..writeln(
        '        PRIMARY KEY '
        '(${model.identity.fields.map((field) => '"${dartFileName(field.name)}"').join(', ')})',
      )
      ..writeln('      )')
      ..writeln("    ''',")
      ..writeln('  ),');
  }
  for (final constraint in model.uniqueConstraints) {
    final fields = constraint.fields
        .map((field) => dartFileName(field.name))
        .toList();
    buffer
      ..writeln('  DatabaseStatement(')
      ..writeln("    sql: '''")
      ..writeln(
        '      CREATE UNIQUE INDEX '
        '"model_${file}_${fields.join('_')}_unique"',
      )
      ..writeln('      ON "model_$file" ')
      ..writeln('      (${fields.map((field) => '"$field"').join(', ')})')
      ..writeln("    ''',")
      ..writeln('  ),');
  }
  buffer.writeln('];');
  return buffer.toString();
}

/// One immutable class per declared mutation: one typed field per slot, and
/// one member carrying what the runtime needs to apply, queue and encode it.
String _emitMutations(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';")
    ..writeln()
    ..writeln("import 'models.dart';");
  final projectedFields = [
    for (final mutation in graph.mutations)
      for (final slot in mutation.slots)
        for (final field in slot.allowedPatchFields)
          graph.model(slot.model).field(field),
  ];
  if (projectedFields.any((field) => field.valueType is EnumValueType)) {
    buffer.writeln("import 'enums.dart';");
  }
  final files = {
    for (final mutation in graph.mutations)
      for (final slot in mutation.slots) dartFileName(slot.model.name),
  }.toList()..sort();
  for (final file in files) {
    buffer.writeln("import 'models/$file.dart';");
  }
  buffer.writeln();
  for (final mutation in graph.mutations) {
    final name = mutation.symbol.name;
    final updateSlots = mutation.slots
        .where((slot) => slot.operation == MutationOperationKind.update)
        .toList();
    for (final slot in updateSlots) {
      _writeProjectedUpdateBuilder(buffer, graph, mutation, slot);
    }
    if (updateSlots.isNotEmpty) {
      _writeProjectedMutationScope(buffer, mutation, updateSlots);
    }
    buffer
      ..writeln(
        '/// Exactly what $name\'s callback must return: its declared slots,',
      )
      ..writeln(
        '/// so an omitted slot, a wrong operation, a wrong Model or a wrong',
      )
      ..writeln('/// cardinality is a compile error rather than a rejection.')
      ..writeln('typedef ${name}Result = ({');
    for (final slot in mutation.slots) {
      buffer.writeln('  ${_slotType(mutation, slot)} ${slot.name},');
    }
    buffer
      ..writeln('});')
      ..writeln();
  }
  buffer
    ..writeln('/// What each declared act sends, as a fact (CAP-488).')
    ..writeln('///')
    ..writeln(
      '/// One method per act, from its exact returned record to the wire',
    )
    ..writeln(
      '/// operations that record spells — the slots flattened in declaration',
    )
    ..writeln(
      '/// order, list slots in element order, with the act\'s declared',
    )
    ..writeln('/// bindings and client-only sequence selectors beside them.')
    ..writeln('final class MutationRecords {')
    ..writeln('  const MutationRecords();');
  for (final mutation in graph.mutations) {
    final name = mutation.symbol.name;
    buffer
      ..writeln()
      ..writeln('  MutationRecord ${lowerCamel(name)}(${name}Result result) =>')
      ..writeln('      MutationRecord(')
      ..writeln("        name: '$name',")
      ..writeln('        version: ${mutation.version},')
      ..writeln('        slotOperations: [');
    for (final slot in mutation.slots) {
      for (final line in _slotOperationFacts(slot)) {
        buffer.writeln('          $line');
      }
    }
    buffer.writeln('        ],');
    final bound = mutation.slots
        .where((slot) => slot.bindings.isNotEmpty)
        .toList();
    if (bound.isNotEmpty) {
      buffer.writeln('        bindings: [');
      for (final slot in bound) {
        for (final line in _slotBindings(slot)) {
          buffer.writeln('          $line');
        }
      }
      buffer.writeln('        ],');
    }
    if (mutation.sequenceSelectors.isNotEmpty) {
      buffer.writeln('        sequenceSelectors: [');
      for (final selector in mutation.sequenceSelectors) {
        for (final line in _sequenceSelector(mutation, selector)) {
          buffer.writeln('          $line');
        }
      }
      buffer.writeln('        ],');
    }
    buffer.writeln('      );');
  }
  buffer
    ..writeln('}')
    ..writeln()
    ..writeln('const mutationRecords = MutationRecords();')
    ..writeln()
    ..writeln('/// The declared product acts, one method each (CAP-488).')
    ..writeln('///')
    ..writeln(
      '/// Each takes one callback that reads inside the act\'s own '
      'transaction',
    )
    ..writeln(
      '/// and returns its wire slots. A direct write made through the same',
    )
    ..writeln(
      '/// `tx` is a device-only companion: off the wire, but sharing the',
    )
    ..writeln('/// act\'s fate. Returning null is a deliberate atomic no-op.')
    ..writeln('final class TransactionMutations {')
    ..writeln('  const TransactionMutations(this._executor);')
    ..writeln()
    ..writeln('  final MutationScopeExecutor<TransactionModels> _executor;');
  for (final mutation in graph.mutations) {
    final name = mutation.symbol.name;
    final hasUpdate = mutation.slots.any(
      (slot) => slot.operation == MutationOperationKind.update,
    );
    final scopeType = hasUpdate
        ? '${name}MutationScope'
        : 'LocalSyncMutationScope<TransactionModels>';
    buffer
      ..writeln()
      ..writeln('  Future<void> ${lowerCamel(name)}(')
      ..writeln('    Future<${name}Result?> Function(')
      ..writeln('      $scopeType mutation,')
      ..writeln('    ) build,')
      ..writeln('  ) => _executor.run(')
      ..writeln("    name: '$name',");
    if (hasUpdate) {
      buffer
        ..writeln('    build: (mutation) =>')
        ..writeln('        build(${name}MutationScope(mutation)),');
    } else {
      buffer.writeln('    build: build,');
    }
    buffer
      ..writeln('    record: mutationRecords.${lowerCamel(name)},')
      ..writeln('  );');
  }
  buffer.writeln('}');
  return buffer.toString();
}

void _writeProjectedUpdateBuilder(
  StringBuffer buffer,
  ModelGraph graph,
  MutationDefinition mutation,
  MutationSlotDefinition slot,
) {
  final mutationName = mutation.symbol.name;
  final model = graph.model(slot.model);
  final modelName = model.symbol.name;
  final operationType = _projectedOperationTypeName(mutation, slot);
  final slotType = _projectedSlotTypeName(mutation, slot);
  final fields = slot.allowedPatchFields
      .map(model.field)
      .toList(growable: false);
  buffer
    ..writeln('final class $operationType extends ModelUpdateOperation {')
    ..writeln(
      '  $operationType._({required ${modelName}Id id, '
      'required Map<String, Object?> patch})',
    )
    ..writeln("      : super(model: '$modelName', id: id, patch: patch);")
    ..writeln('}')
    ..writeln()
    ..writeln('final class $slotType {')
    ..writeln('  const $slotType();')
    ..writeln()
    ..writeln('  $operationType update(')
    ..writeln('    $modelName row, {');
  for (final field in fields) {
    final type = _dartType(field.valueType, nullable: field.nullable);
    buffer.writeln(
      field.nullable
          ? '    FieldUpdate<$type>? ${field.symbol.name},'
          : '    $type? ${field.symbol.name},',
    );
  }
  buffer
    ..writeln('  }) {')
    ..writeln('    final patch = <String, Object?>{');
  for (final field in fields) {
    final name = field.symbol.name;
    buffer.writeln(
      field.nullable
          ? "      if ($name != null) '$name': $name.value,"
          : "      if ($name != null) '$name': $name,",
    );
  }
  buffer
    ..writeln('    };')
    ..writeln('    if (patch.isEmpty) {')
    ..writeln(
      "      throw ArgumentError('mutation \"$mutationName\" slot "
      "\"${slot.name}\" update requires at least one field');",
    )
    ..writeln('    }')
    ..writeln('    return $operationType._(id: row.id, patch: patch);')
    ..writeln('  }')
    ..writeln('}')
    ..writeln();
}

void _writeProjectedMutationScope(
  StringBuffer buffer,
  MutationDefinition mutation,
  List<MutationSlotDefinition> updateSlots,
) {
  final mutationName = mutation.symbol.name;
  buffer
    ..writeln('final class ${mutationName}MutationScope {')
    ..writeln('  const ${mutationName}MutationScope(this._scope);')
    ..writeln()
    ..writeln('  final LocalSyncMutationScope<TransactionModels> _scope;')
    ..writeln()
    ..writeln('  TransactionModels get models => _scope.models;')
    ..writeln('  MutationScopes get scopes => _scope.scopes;');
  for (final slot in updateSlots) {
    final slotType = _projectedSlotTypeName(mutation, slot);
    buffer
      ..writeln('  $slotType get ${slot.name} =>')
      ..writeln('      const $slotType();');
  }
  buffer
    ..writeln('}')
    ..writeln();
}

/// The act-level wiring as generated facts: one [SlotBinding] per bound row,
/// pairing it with the operation in the slot it binds (spec
/// 2026-08-16-slot-bindings). Facts only — the check that consumes them is
/// the handwritten SlotBindingVerifier.
List<String> _slotBindings(MutationSlotDefinition slot) {
  String entry(String operation, MutationSlotBindingDefinition binding) {
    final fields = binding.fields.map((field) => "'${field.name}'").join(', ');
    return 'SlotBinding(operation: $operation, '
        'fields: const [$fields], parent: result.${binding.slot}),';
  }

  final read = 'result.${slot.name}';
  return switch (slot.cardinality) {
    MutationSlotCardinality.single => [
      for (final binding in slot.bindings) entry(read, binding),
    ],
    MutationSlotCardinality.optional => [
      for (final binding in slot.bindings)
        'if ($read != null) ${entry('$read!', binding)}',
    ],
    MutationSlotCardinality.list => [
      'for (final operation in $read) ...[',
      for (final binding in slot.bindings) '  ${entry('operation', binding)}',
      '],',
    ],
  };
}

List<String> _sequenceSelector(
  MutationDefinition mutation,
  MutationSequenceSelectorDefinition selector,
) {
  final predecessorRelations = selector.predecessor.relations
      .map((relation) => "'${relation.name}'")
      .join(', ');
  final currentSlot = mutation.slots.singleWhere(
    (slot) => slot.name == selector.current.slot,
  );
  return [
    'MutationSequenceSelector(',
    "  predecessorMutation: '${selector.predecessorMutation.name}',",
    "  predecessorSlot: '${selector.predecessor.slot}',",
    '  predecessorRelations: const [$predecessorRelations],',
    '  currentPaths: [',
    for (final line in _slotCurrentPaths(currentSlot, selector.current))
      '    $line',
    '  ],',
    '),',
  ];
}

List<String> _slotCurrentPaths(
  MutationSlotDefinition slot,
  MutationSequenceEndpointDefinition endpoint,
) {
  final relations = endpoint.relations
      .map((relation) => "'${relation.name}'")
      .join(', ');

  List<String> entry(String operation) => [
    'MutationSequenceCurrentPath(',
    '  source: $operation,',
    '  relations: const [$relations],',
    '),',
  ];

  final read = 'result.${slot.name}';
  return switch (slot.cardinality) {
    MutationSlotCardinality.single => entry(read),
    MutationSlotCardinality.optional => [
      'if ($read != null)',
      for (final line in entry('$read!')) '  $line',
    ],
    MutationSlotCardinality.list => [
      'for (final operation in $read)',
      for (final line in entry('operation')) '  $line',
    ],
  };
}

String _operationTypeName(MutationSlotDefinition slot) =>
    '${slot.model.name}${_upperFirst(slot.operation.name)}';

String _projectedOperationTypeName(
  MutationDefinition mutation,
  MutationSlotDefinition slot,
) => '${mutation.symbol.name}${_upperFirst(slot.name)}Update';

String _projectedSlotTypeName(
  MutationDefinition mutation,
  MutationSlotDefinition slot,
) => '${mutation.symbol.name}${_upperFirst(slot.name)}Slot';

String _slotType(MutationDefinition mutation, MutationSlotDefinition slot) {
  final operation = slot.operation == MutationOperationKind.update
      ? _projectedOperationTypeName(mutation, slot)
      : _operationTypeName(slot);
  return switch (slot.cardinality) {
    MutationSlotCardinality.single => operation,
    MutationSlotCardinality.optional => '$operation?',
    MutationSlotCardinality.list => 'List<$operation>',
  };
}

List<String> _slotOperationFacts(MutationSlotDefinition slot) {
  final read = 'result.${slot.name}';
  final allowedPatchFields = slot.operation == MutationOperationKind.update
      ? ', allowedPatchFields: const '
            '[${slot.allowedPatchFields.map((field) => "'${field.name}'").join(', ')}]'
      : '';
  String entry(String operation) =>
      "MutationSlotOperation(slotName: '${slot.name}', "
      'operation: $operation$allowedPatchFields),';
  return switch (slot.cardinality) {
    MutationSlotCardinality.single => [entry(read)],
    MutationSlotCardinality.optional => [
      'if ($read != null)',
      '  ${entry('$read!')}',
    ],
    MutationSlotCardinality.list => [
      'for (final operation in $read)',
      '  ${entry('operation')}',
    ],
  };
}

String _emitDatabase(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';")
    ..writeln("import 'package:local_sync_database/local_sync_database.dart';");
  for (final model in graph.models) {
    buffer.writeln("import 'storage/${dartFileName(model.symbol.name)}.dart';");
  }
  buffer
    ..writeln()
    ..writeln(
      '/// Every table the current models imply — the framework\'s '
      'infrastructure',
    )
    ..writeln(
      '/// plus one statement list per Model. Consumers build their own',
    )
    ..writeln('/// migration ladder over this fact (CAP-387): the product')
    ..writeln('/// freezes shipped versions in a handwritten ladder whose')
    ..writeln('/// equivalence test compares against this.')
    ..writeln('final localSyncCurrentSchemaStatements = <DatabaseStatement>[')
    ..writeln('  ...localSyncInfrastructureStatements,');
  for (final model in graph.models) {
    buffer.writeln('  ...${lowerCamel(model.symbol.name)}DatabaseStatements,');
  }
  buffer.writeln('];');
  return buffer.toString();
}

String _emitModelRegistry(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';")
    ..writeln("import 'mutation_input_contracts.dart';");
  for (final model in graph.models) {
    final file = dartFileName(model.symbol.name);
    buffer
      ..writeln("import 'models/$file.dart';")
      ..writeln("import 'storage/$file.dart';");
  }
  buffer
    ..writeln()
    ..writeln(
      'ModelRegistry buildModelRegistry(LocalDatabaseScope database) =>',
    )
    ..writeln('    ModelRegistry([');
  // Every Model. A Model describes a row shape and says nothing about
  // replication (CAP-488), so there is no side of the wire for an entry to be
  // on and nothing to filter here.
  for (final model in graph.models) {
    final name = model.symbol.name;
    buffer
      ..writeln('      TypedModelRegistryEntry<${name}Id>(')
      ..writeln('        schema: ${lowerCamel(name)}Schema,');
    buffer
      ..writeln('        canonical: SqlCanonicalStore<${name}Id>(')
      ..writeln('          database: database,')
      ..writeln('          descriptor: ${lowerCamel(name)}DatabaseDescriptor,')
      ..writeln('        ),')
      ..writeln('        before: BeforeImageStore<${name}Id>(')
      ..writeln('          database: database,')
      ..writeln('          main: ${lowerCamel(name)}DatabaseDescriptor,')
      ..writeln(
        '          before: ${lowerCamel(name)}BeforeDatabaseDescriptor,',
      )
      ..writeln('        ),')
      ..writeln('        mutations: SqlMutationStore<${name}Id>(')
      ..writeln('          database: database,')
      ..writeln('          schema: ${lowerCamel(name)}Schema,');
    buffer
      ..writeln('        ),')
      ..writeln('      ),');
  }
  buffer.writeln(
    '    ], mutationInputs: MutationInputContracts(mutationInputContracts));',
  );
  return buffer.toString();
}

String _emitModelsComposition(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln();
  for (final model in graph.models) {
    buffer.writeln("import 'models/${dartFileName(model.symbol.name)}.dart';");
  }
  buffer
    ..writeln()
    ..writeln('final class Models {')
    ..writeln('  const Models({');
  for (final model in graph.models) {
    buffer.writeln('    required this.${lowerCamel(model.symbol.name)},');
  }
  buffer.writeln('  });');
  for (final model in graph.models) {
    buffer.writeln(
      '  final ${model.symbol.name}Collection '
      '${lowerCamel(model.symbol.name)};',
    );
  }
  buffer
    ..writeln('}')
    ..writeln()
    ..writeln('/// The Models as a write callback sees them: reads and writes')
    ..writeln('/// inside the callback\'s own transaction, and no `watch`.')
    ..writeln('final class TransactionModels {')
    ..writeln('  const TransactionModels({');
  for (final model in graph.models) {
    buffer.writeln('    required this.${lowerCamel(model.symbol.name)},');
  }
  buffer.writeln('  });');
  for (final model in graph.models) {
    buffer.writeln(
      '  final ${model.symbol.name}TransactionCollection '
      '${lowerCamel(model.symbol.name)};',
    );
  }
  buffer.writeln('}');
  return buffer.toString();
}

String _emitDownlinkChanges(ModelGraph graph) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';");
  if (graph.enums.isNotEmpty) {
    buffer.writeln("import 'enums.dart';");
  }
  for (final model in graph.models) {
    buffer.writeln("import 'models/${dartFileName(model.symbol.name)}.dart';");
  }
  buffer
    ..writeln()
    ..writeln('sealed class LocalSyncDownlinkChange {')
    ..writeln('  const LocalSyncDownlinkChange({')
    ..writeln('    required this.scope,')
    ..writeln('    required this.syncId,')
    ..writeln('  });')
    ..writeln()
    ..writeln('  final String scope;')
    ..writeln('  final int syncId;')
    ..writeln('}');
  for (final model in graph.models) {
    final name = model.symbol.name;
    buffer
      ..writeln()
      ..writeln('final class ${name}DownlinkUpsert ')
      ..writeln('    extends LocalSyncDownlinkChange {')
      ..writeln('  const ${name}DownlinkUpsert({')
      ..writeln('    required super.scope,')
      ..writeln('    required super.syncId,')
      ..writeln('    required this.previous,')
      ..writeln('    required this.row,')
      ..writeln('  });')
      ..writeln()
      ..writeln('  final $name? previous;')
      ..writeln('  final $name row;')
      ..writeln('}')
      ..writeln()
      ..writeln('final class ${name}DownlinkDelete ')
      ..writeln('    extends LocalSyncDownlinkChange {')
      ..writeln('  const ${name}DownlinkDelete({')
      ..writeln('    required super.scope,')
      ..writeln('    required super.syncId,')
      ..writeln('    required this.row,')
      ..writeln('  });')
      ..writeln()
      ..writeln('  final $name row;')
      ..writeln('}');
  }
  buffer
    ..writeln()
    ..writeln(
      'typedef LocalSyncDownlinkChanges = List<LocalSyncDownlinkChange>;',
    )
    ..writeln()
    ..writeln('LocalSyncDownlinkChanges materializeDownlinkChanges(')
    ..writeln('  List<CanonicalDownlinkChange> changes,')
    ..writeln(
      ') => List.unmodifiable(changes.map(_materializeDownlinkChange));',
    )
    ..writeln()
    ..writeln('LocalSyncDownlinkChange _materializeDownlinkChange(')
    ..writeln('  CanonicalDownlinkChange change,')
    ..writeln(') {')
    ..writeln('  if (change is CanonicalDownlinkUpsert) {')
    ..writeln('    switch (change.entry.schema.name) {');
  for (final model in graph.models) {
    final name = model.symbol.name;
    buffer
      ..writeln("      case '$name':")
      ..writeln('        return ${name}DownlinkUpsert(')
      ..writeln('          scope: change.scope,')
      ..writeln('          syncId: change.syncId,')
      ..writeln('          previous: change.previous == null')
      ..writeln('              ? null')
      ..writeln('              : _materialize$name(change.previous!),')
      ..writeln('          row: _materialize$name(change.row),')
      ..writeln('        );');
  }
  buffer
    ..writeln('    }')
    ..writeln('  } else if (change is CanonicalDownlinkDelete) {')
    ..writeln('    switch (change.entry.schema.name) {');
  for (final model in graph.models) {
    final name = model.symbol.name;
    buffer
      ..writeln("      case '$name':")
      ..writeln('        return ${name}DownlinkDelete(')
      ..writeln('          scope: change.scope,')
      ..writeln('          syncId: change.syncId,')
      ..writeln('          row: _materialize$name(change.row),')
      ..writeln('        );');
  }
  buffer
    ..writeln('    }')
    ..writeln('  }')
    ..writeln("  throw StateError('unknown canonical Downlink Model');")
    ..writeln('}');
  for (final model in graph.models) {
    final name = model.symbol.name;
    final valueFields = model.fields
        .where((field) => !_isHiddenIdentityField(model, field))
        .toList();
    buffer
      ..writeln()
      ..writeln('$name _materialize$name(ModelRecord<ModelId> record) =>')
      ..writeln('    $name(')
      ..writeln('      id: record.id as ${name}Id,');
    for (final field in valueFields) {
      buffer.writeln(
        '      ${field.symbol.name}: '
        '${_recordFieldExpression(model, field)},',
      );
    }
    buffer.writeln('    );');
  }
  return buffer.toString();
}

String _emitComposition(ModelGraph graph) {
  final ordered = _cascadeBuildOrder(graph);
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln()
    ..writeln("import 'package:local_sync/local_sync.dart';")
    ..writeln()
    ..writeln("import 'models.dart';")
    ..writeln("import 'mutations.dart';");
  for (final model in graph.models) {
    final file = dartFileName(model.symbol.name);
    buffer
      ..writeln("import 'models/$file.dart';")
      ..writeln("import 'storage/$file.dart';");
  }
  buffer
    ..writeln()
    ..writeln('final class GeneratedModelRuntimes {')
    ..writeln('  const GeneratedModelRuntimes({');
  for (final model in graph.models) {
    buffer.writeln('    required this.${lowerCamel(model.symbol.name)},');
  }
  buffer.writeln('  });');
  for (final model in graph.models) {
    buffer.writeln(
      '  final ModelRuntime<${model.symbol.name}Id> '
      '${lowerCamel(model.symbol.name)};',
    );
  }
  buffer
    ..writeln('}')
    ..writeln()
    ..writeln('GeneratedModelRuntimes buildModelRuntimes(')
    ..writeln('  LocalDatabaseScope database, {')
    ..writeln('  required ModelRegistry registry,')
    ..writeln('}) {');
  for (final model in ordered) {
    final name = model.symbol.name;
    final variable = lowerCamel(name);
    const runtime = 'ModelRuntime';
    buffer
      ..writeln('  final $variable = $runtime<${name}Id>(')
      ..writeln('    database: database,')
      ..writeln('    descriptor: ${lowerCamel(name)}DatabaseDescriptor,')
      ..writeln(
        '    beforeDescriptor: ${lowerCamel(name)}BeforeDatabaseDescriptor,',
      );
    buffer.writeln('    registry: registry,');
    buffer.writeln('  );');
  }
  buffer
    ..writeln('  return GeneratedModelRuntimes(')
    ..writeAll(
      graph.models.map(
        (model) =>
            '    ${lowerCamel(model.symbol.name)}: '
            '${lowerCamel(model.symbol.name)},\n',
      ),
    )
    ..writeln('  );')
    ..writeln('}')
    ..writeln()
    ..writeln('Models buildModels(GeneratedModelRuntimes runtimes) {')
    ..writeln('  return Models(');
  for (final model in graph.models) {
    final name = model.symbol.name;
    final variable = lowerCamel(name);
    buffer.writeln(
      '    $variable: ${name}Collection(reader: runtimes.$variable.reader),',
    );
  }
  buffer
    ..writeln('  );')
    ..writeln('}')
    ..writeln()
    ..writeln('/// The Models bound to one transaction (CAP-488).')
    ..writeln('///')
    ..writeln('/// Every operation chooses direct or Mutation companion fate')
    ..writeln('/// when it enters, so a captured outer collection cannot')
    ..writeln('/// escape the active named act.')
    ..writeln('TransactionModels buildTransactionModels(')
    ..writeln('  GeneratedModelRuntimes runtimes,')
    ..writeln('  TransactionFateContext context,')
    ..writeln(') {')
    ..writeln('  return TransactionModels(');
  for (final model in graph.models) {
    final name = model.symbol.name;
    final variable = lowerCamel(name);
    buffer
      ..writeln('    $variable: ${name}TransactionCollection(')
      ..writeln('      reader: runtimes.$variable.reader,')
      ..writeln('      writer: TransactionModelWriter<${name}Id>(')
      ..writeln('        context: context,')
      ..writeln('        direct: runtimes.$variable.direct,')
      ..writeln('        queued: runtimes.$variable.queued,')
      ..writeln('      ),')
      ..writeln('    ),');
  }
  buffer
    ..writeln('  );')
    ..writeln('}')
    ..writeln()
    ..writeln('/// One queued write path per Model, by name — what a named')
    ..writeln('/// act applies each of its returned slots through.')
    ..writeln('Map<String, MutationTarget> buildMutationTargets(')
    ..writeln('  GeneratedModelRuntimes runtimes,')
    ..writeln(') {')
    ..writeln('  return Map.fromEntries([');
  for (final model in graph.models) {
    final name = model.symbol.name;
    buffer.writeln(
      "    mutationTarget<${name}Id>('$name', "
      'runtimes.${lowerCamel(name)}.queued),',
    );
  }
  buffer
    ..writeln('  ]);')
    ..writeln('}')
    ..writeln()
    ..writeln(
      'TransactionContextFactory<TransactionModels, TransactionMutations> '
      'buildTransactionContexts(',
    )
    ..writeln('  LocalDatabaseScope database,')
    ..writeln('  ModelRegistry registry,')
    ..writeln('  GeneratedModelRuntimes runtimes,')
    ..writeln(') => TransactionContextFactory(')
    ..writeln('  database: database,')
    ..writeln('  registry: registry,')
    ..writeln('  targets: buildMutationTargets(runtimes),')
    ..writeln(
      '  buildModels: (context) => '
      'buildTransactionModels(runtimes, context),',
    )
    ..writeln('  buildTransactionScopes: (context) => FateAwareScopeWriter(')
    ..writeln('    store: ScopeStore(database),')
    ..writeln('    context: context,')
    ..writeln('  ),')
    ..writeln('  buildMutationScopes: (context) => FateAwareScopeWriter(')
    ..writeln('    store: ScopeStore(database),')
    ..writeln('    context: context,')
    ..writeln('  ),')
    ..writeln('  buildMutations: TransactionMutations.new,')
    ..writeln(');');
  return buffer.toString();
}

List<ModelDefinition> _cascadeBuildOrder(ModelGraph graph) {
  final result = <ModelDefinition>[];
  final seen = <ModelSymbol>{};
  void visit(ModelDefinition model) {
    if (!seen.add(model.symbol)) return;
    for (final relation in model.relations) {
      if (relation.deleteOnTarget) {
        visit(graph.model(relation.target));
      }
    }
    result.add(model);
  }

  for (final model in graph.models) {
    visit(model);
  }
  return result;
}

bool _isHiddenIdentityField(
  ModelDefinition model,
  ModelFieldDefinition field,
) => field.symbol.name == 'id' && model.identity.fields.contains(field.symbol);

bool _usesEnums(ModelDefinition model) =>
    model.fields.any((field) => field.valueType is EnumValueType);

String _schemaValueType(FieldValueType type) => switch (type) {
  ScalarValueType(:final scalar) => 'LocalScalarType.${scalar.name}',
  EnumValueType(:final enumSymbol) => '${lowerCamel(enumSymbol.name)}Type',
  ScalarListValueType(:final element) =>
    'LocalScalarListType(LocalScalarType.${element.name})',
};

String _dartType(FieldValueType type, {bool nullable = false}) {
  final base = switch (type) {
    ScalarValueType(:final scalar) => _dartScalarType(scalar),
    EnumValueType(:final enumSymbol) => enumSymbol.name,
    ScalarListValueType(:final element) => 'List<${_dartScalarType(element)}>',
  };
  return nullable ? '$base?' : base;
}

String _dartScalarType(ScalarType type) => switch (type) {
  ScalarType.string => 'String',
  ScalarType.boolean => 'bool',
  ScalarType.int => 'int',
  ScalarType.float => 'double',
  ScalarType.dateTime => 'DateTime',
  ScalarType.uuid => 'UUID',
};

String _sqliteType(FieldValueType type) => switch (type) {
  ScalarValueType(scalar: ScalarType.boolean || ScalarType.int) => 'INTEGER',
  ScalarValueType(scalar: ScalarType.float) => 'REAL',
  ScalarValueType() || EnumValueType() || ScalarListValueType() => 'TEXT',
};

String _emitMutationInputs(MutationHistory history) {
  final output = StringBuffer(
    '// GENERATED CODE - DO NOT MODIFY BY HAND.\n\nconst mutationInputContracts = <String, Map<int, Map<String, Object?>>>{\n',
  );
  for (final entry in history.mutations.entries) {
    output.writeln('  ${jsonEncode(entry.key)}: {');
    for (final version in entry.value.entries) {
      // JSON's maps/lists are Dart constant literals as well; escape dollar
      // signs to prevent interpolation in generated string literals.
      final input = jsonEncode(
        (version.value as Map)['input'],
      ).replaceAll(r'$', r'\$');
      output.writeln('    ${version.key}: $input,');
    }
    output.writeln('  },');
  }
  output.writeln('};');
  return output.toString();
}
