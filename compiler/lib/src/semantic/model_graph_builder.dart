import '../syntax/ast.dart';
import '../syntax/source.dart';
import 'model_graph.dart';

const _scalarTypes = <String, ScalarType>{
  'String': ScalarType.string,
  'Boolean': ScalarType.boolean,
  'Int': ScalarType.int,
  'Float': ScalarType.float,
  'DateTime': ScalarType.dateTime,
  'UUID': ScalarType.uuid,
};

ModelGraph buildModelGraph(Iterable<ModelDocumentSyntax> documents) {
  final frozenDocuments = documents.toList();
  final enumSyntaxByName = <String, EnumSyntax>{};
  final syntaxByName = <String, ModelSyntax>{};
  for (final document in frozenDocuments) {
    for (final enumSyntax in document.enums) {
      final name = enumSyntax.name.value;
      if (_scalarTypes.containsKey(name)) {
        throw _error(enumSyntax.name.span.start, 'reserved enum name "$name"');
      }
      if (enumSyntaxByName.containsKey(name)) {
        throw _error(enumSyntax.name.span.start, 'duplicate enum name "$name"');
      }
      if (syntaxByName.containsKey(name)) {
        throw _error(enumSyntax.name.span.start, 'duplicate type name "$name"');
      }
      enumSyntaxByName[name] = enumSyntax;
    }
    for (final model in document.models) {
      final name = model.name.value;
      if (_scalarTypes.containsKey(name)) {
        throw _error(model.name.span.start, 'reserved Model name "$name"');
      }
      if (syntaxByName.containsKey(name)) {
        throw _error(model.name.span.start, 'duplicate Model name "$name"');
      }
      if (enumSyntaxByName.containsKey(name)) {
        throw _error(model.name.span.start, 'duplicate type name "$name"');
      }
      syntaxByName[name] = model;
    }
  }

  final enumSymbols = {
    for (final name in enumSyntaxByName.keys) name: EnumSymbol(name),
  };
  final enumDefinitions = <EnumDefinition>[];
  for (final entry in enumSyntaxByName.entries) {
    final syntax = entry.value;
    if (syntax.values.isEmpty) {
      throw _error(
        syntax.name.span.start,
        'enum "${entry.key}" requires a value',
      );
    }
    final seen = <String>{};
    final symbol = enumSymbols[entry.key]!;
    final values = <EnumValueSymbol>[];
    for (final value in syntax.values) {
      if (!seen.add(value.value)) {
        throw _error(
          value.span.start,
          'duplicate value "${value.value}" in enum "${entry.key}"',
        );
      }
      values.add(EnumValueSymbol(owner: symbol, name: value.value));
    }
    enumDefinitions.add(EnumDefinition(symbol: symbol, values: values));
  }

  final symbols = {
    for (final name in syntaxByName.keys) name: ModelSymbol(name),
  };
  final prerequisites = _resolvePrerequisites(frozenDocuments);
  final prerequisitesByName = {
    for (final prerequisite in prerequisites)
      prerequisite.symbol.name: prerequisite,
  };
  final classified = <ModelSymbol, _ClassifiedModel>{};
  for (final entry in syntaxByName.entries) {
    final symbol = symbols[entry.key]!;
    classified[symbol] = _classifyModel(
      entry.value,
      symbol: symbol,
      symbols: symbols,
      enumSymbols: enumSymbols,
      prerequisites: prerequisitesByName,
    );
  }

  final annotations = <ModelSymbol, _ModelAnnotations>{};
  final identities = <ModelSymbol, ModelIdentity>{};
  for (final model in classified.values) {
    final modelAnnotations = _resolveModelAnnotations(model.syntax);
    annotations[model.symbol] = modelAnnotations;
    identities[model.symbol] = _resolveIdentity(model, modelAnnotations);
  }

  final uniqueConstraints = <ModelSymbol, List<UniqueConstraint>>{};
  for (final model in classified.values) {
    final modelAnnotations = annotations[model.symbol]!;
    uniqueConstraints[model.symbol] = _resolveUniqueConstraints(
      model,
      modelAnnotations.unique,
      identities[model.symbol]!,
    );
  }

  final deleteOnTargetLocations = <RelationSymbol, SourceLocation>{};
  final relationsByModel = <ModelSymbol, List<RelationDefinition>>{};
  final relationNameLocations = <RelationSymbol, SourceLocation>{};
  for (final model in classified.values) {
    final resolvedRelations = _resolveRelations(
      model,
      classified: classified,
      identities: identities,
    );
    for (final relation in resolvedRelations) {
      final location = relation.deleteOnTargetLocation;
      if (location != null) {
        deleteOnTargetLocations[relation.definition.symbol] = location;
      }
      final nameLocation = relation.relationNameLocation;
      if (nameLocation != null) {
        relationNameLocations[relation.definition.symbol] = nameLocation;
      }
    }
    relationsByModel[model.symbol] = resolvedRelations
        .map((relation) => relation.definition)
        .toList();
  }

  final inversesByModel = _resolveInverses(
    classified,
    relationsByModel: relationsByModel,
    relationNameLocations: relationNameLocations,
    identities: identities,
    uniqueConstraints: uniqueConstraints,
  );

  final definitions = [
    for (final model in classified.values)
      ModelDefinition(
        symbol: model.symbol,
        fields: model.fields,
        identity: identities[model.symbol]!,
        uniqueConstraints: uniqueConstraints[model.symbol]!,
        relations: relationsByModel[model.symbol]!,
        inverses: inversesByModel[model.symbol] ?? const [],
      ),
  ];

  final mutationDefinitions = _resolveMutations(
    frozenDocuments,
    symbols: symbols,
    enumSymbols: enumSymbols,
    fields: {for (final model in classified.values) model.symbol: model.fields},
    identities: identities,
    relations: relationsByModel,
  );

  final graph = ModelGraph(
    definitions,
    enums: enumDefinitions,
    mutations: mutationDefinitions,
    prerequisites: prerequisites,
  );
  _rejectDeleteOnTargetCycles(graph, deleteOnTargetLocations);
  return graph;
}

List<PrerequisiteDefinition> _resolvePrerequisites(
  Iterable<ModelDocumentSyntax> documents,
) {
  final definitions = <PrerequisiteDefinition>[];
  final names = <String>{};
  for (final document in documents) {
    for (final syntax in document.prerequisites) {
      final name = syntax.name.value;
      if (!names.add(name)) {
        throw _error(
          syntax.name.span.start,
          'duplicate prerequisite name "$name"',
        );
      }
      final parameterNames = <String>{};
      final parameters = <PrerequisiteParameterDefinition>[];
      for (final parameter in syntax.parameters) {
        if (!parameterNames.add(parameter.name.value)) {
          throw _error(
            parameter.name.span.start,
            'duplicate prerequisite parameter "$name.${parameter.name.value}"',
          );
        }
        final type = _scalarTypes[parameter.typeName.value];
        if (type == null) {
          throw _error(
            parameter.typeName.span.start,
            'prerequisite parameter "$name.${parameter.name.value}" requires a scalar type',
          );
        }
        parameters.add(
          PrerequisiteParameterDefinition(
            name: parameter.name.value,
            type: type,
          ),
        );
      }
      definitions.add(
        PrerequisiteDefinition(
          symbol: PrerequisiteSymbol(name),
          parameters: parameters,
        ),
      );
    }
  }
  return definitions;
}

const _mutationOperations = <String, MutationOperationKind>{
  'create': MutationOperationKind.create,
  'update': MutationOperationKind.update,
  'delete': MutationOperationKind.delete,
};

/// Resolves every `mutation` block against the Models already classified.
///
/// Every declared mutation is a wire act (CAP-488). A Model describes a row
/// shape and nothing about replication, so device-only work is never declared
/// here — it is an ordinary direct transaction operation, and a companion is
/// an off-wire operation inside the act's own callback.
List<MutationDefinition> _resolveMutations(
  Iterable<ModelDocumentSyntax> documents, {
  required Map<String, ModelSymbol> symbols,
  required Map<String, EnumSymbol> enumSymbols,
  required Map<ModelSymbol, List<ModelFieldDefinition>> fields,
  required Map<ModelSymbol, ModelIdentity> identities,
  required Map<ModelSymbol, List<RelationDefinition>> relations,
}) {
  final syntaxByName = <String, MutationSyntax>{};
  for (final document in documents) {
    for (final mutation in document.mutations) {
      final name = mutation.name.value;
      if (syntaxByName.containsKey(name)) {
        throw _error(
          mutation.name.span.start,
          'duplicate mutation name "$name"',
        );
      }
      if (symbols.containsKey(name) || enumSymbols.containsKey(name)) {
        throw _error(
          mutation.name.span.start,
          'mutation "$name" duplicates a type name',
        );
      }
      syntaxByName[name] = mutation;
    }
  }

  final unresolved =
      <
        String,
        ({
          MutationSyntax syntax,
          MutationSymbol symbol,
          List<MutationSlotDefinition> slots,
        })
      >{};
  for (final entry in syntaxByName.entries) {
    final syntax = entry.value;
    final symbol = MutationSymbol(entry.key);
    if (syntax.slots.isEmpty) {
      throw _error(
        syntax.name.span.start,
        'mutation "${symbol.name}" requires a slot',
      );
    }

    final slots = <MutationSlotDefinition>[];
    final slotNames = <String>{};
    for (final slot in syntax.slots) {
      if (!slotNames.add(slot.name.value)) {
        throw _error(
          slot.name.span.start,
          'duplicate slot "${symbol.name}.${slot.name.value}"',
        );
      }
      final model = symbols[slot.modelName.value];
      if (model == null) {
        throw _error(
          slot.modelName.span.start,
          'slot "${symbol.name}.${slot.name.value}" names unknown Model '
          '"${slot.modelName.value}"',
        );
      }
      final operation = _mutationOperations[slot.operation.value];
      if (operation == null) {
        throw _error(
          slot.operation.span.start,
          'slot "${symbol.name}.${slot.name.value}" names unknown operation '
          '"${slot.operation.value}"; expected create, update, or delete',
        );
      }
      if (operation == MutationOperationKind.update &&
          const {'models', 'scopes'}.contains(slot.name.value)) {
        throw _error(
          slot.name.span.start,
          'update slot "${symbol.name}.${slot.name.value}" uses reserved '
          'scope member name "${slot.name.value}"',
        );
      }
      final bindings = _resolveSlotBindings(
        slot,
        mutation: symbol,
        model: model,
        declared: syntax.slots,
        earlier: slots,
        relations: relations[model] ?? const [],
      );
      slots.add(
        MutationSlotDefinition(
          mutation: symbol,
          name: slot.name.value,
          model: model,
          operation: operation,
          cardinality: switch (slot.cardinality) {
            MutationSlotCardinalitySyntax.single =>
              MutationSlotCardinality.single,
            MutationSlotCardinalitySyntax.optional =>
              MutationSlotCardinality.optional,
            MutationSlotCardinalitySyntax.list => MutationSlotCardinality.list,
          },
          allowedPatchFields: _resolveAllowedPatchFields(
            slot,
            mutation: symbol,
            model: model,
            operation: operation,
            fields: fields[model] ?? const [],
            identity: identities[model]!,
            relations: relations[model] ?? const [],
            bindings: bindings,
          ),
          bindings: bindings,
        ),
      );
    }

    unresolved[entry.key] = (syntax: syntax, symbol: symbol, slots: slots);
  }
  return [
    for (final entry in unresolved.values)
      MutationDefinition(
        symbol: entry.symbol,
        version: _mutationVersion(entry.syntax),
        slots: entry.slots,
        sequenceSelectors: _resolveMutationSequenceSelectors(
          entry.syntax,
          mutation: entry.symbol,
          slots: entry.slots,
          mutations: unresolved,
          identities: identities,
          relations: relations,
        ),
      ),
  ];
}

List<FieldSymbol> _resolveAllowedPatchFields(
  MutationSlotSyntax slot, {
  required MutationSymbol mutation,
  required ModelSymbol model,
  required MutationOperationKind operation,
  required List<ModelFieldDefinition> fields,
  required ModelIdentity identity,
  required List<RelationDefinition> relations,
  required List<MutationSlotBindingDefinition> bindings,
}) {
  if (operation != MutationOperationKind.update) return const [];

  final label = '"${mutation.name}.${slot.name.value}"';
  final fieldsByName = {
    for (final field in fields) field.symbol.name: field.symbol,
  };
  final identityNames = {for (final field in identity.fields) field.name};
  final relationsByName = {
    for (final relation in relations) relation.symbol.name: relation,
  };
  final seen = <String>{};
  final resolved = <FieldSymbol>[];
  for (final projected in slot.patchFields) {
    final name = projected.value;
    if (!seen.add(name)) {
      throw _error(
        projected.span.start,
        'slot $label patch projection names field "$name" twice',
      );
    }
    if (identityNames.contains(name)) {
      throw _error(
        projected.span.start,
        'slot $label patch projection cannot include identity field "$name"',
      );
    }
    if (relationsByName.containsKey(name)) {
      throw _error(
        projected.span.start,
        'slot $label patch projection names relation "$name"; use its stored '
        'fields instead',
      );
    }
    final field = fieldsByName[name];
    if (field == null) {
      throw _error(
        projected.span.start,
        'slot $label patch projection names unknown field "$name" on Model '
        '"${model.name}"',
      );
    }
    for (final binding in bindings) {
      if (binding.fields.contains(field)) {
        throw _error(
          projected.span.start,
          'slot $label patch projection field "$name" backs bound relation '
          '"${binding.relation.name}"; stored-row bindings cannot also be '
          'patched',
        );
      }
    }
    resolved.add(field);
  }
  return resolved;
}

/// Resolves one slot's `(relation: slot, …)` bindings — the act-level wiring
/// (spec 2026-08-16-slot-bindings).
///
/// Each argument name must be a relation field on the slot's Model; each
/// bound slot must be a `(single)`-cardinality slot of the same act declared
/// earlier, holding the relation's target Model. Several relations may bind
/// (multi-parent), each to a different slot. Modes cannot clash here because
/// a relation already cannot cross them.
List<MutationSlotBindingDefinition> _resolveSlotBindings(
  MutationSlotSyntax slot, {
  required MutationSymbol mutation,
  required ModelSymbol model,
  required List<MutationSlotSyntax> declared,
  required List<MutationSlotDefinition> earlier,
  required List<RelationDefinition> relations,
}) {
  if (slot.bindings.isEmpty) return const [];
  final resolved = <MutationSlotBindingDefinition>[];
  final boundRelations = <String>{};
  final boundSlots = <String>{};
  for (final binding in slot.bindings) {
    final label = '"${mutation.name}.${slot.name.value}"';
    final relationName = binding.relation.value;
    if (!boundRelations.add(relationName)) {
      throw _error(
        binding.relation.span.start,
        'slot $label binds relation "$relationName" twice',
      );
    }
    RelationDefinition? relation;
    for (final candidate in relations) {
      if (candidate.symbol.name == relationName) {
        relation = candidate;
        break;
      }
    }
    if (relation == null) {
      throw _error(
        binding.relation.span.start,
        'slot $label binds unknown relation "$relationName" — expected a '
        'relation field declared on Model "${model.name}"',
      );
    }
    if (relation.nullable) {
      // The check holds bound fields against a parent identity, and an
      // identity is never null — so a nullable relation's legitimate null is
      // an unconditional runtime failure. Refusing here states the intent the
      // binding would otherwise only imply: in this act, the relation is
      // required.
      throw _error(
        binding.relation.span.start,
        'slot $label binds nullable relation "$relationName" — a binding '
        'asserts equality with the bound slot\'s identity, which null can '
        'never satisfy',
      );
    }
    final slotName = binding.slot.value;
    if (!boundSlots.add(slotName)) {
      throw _error(
        binding.slot.span.start,
        'slot $label binds slot "$slotName" twice',
      );
    }
    MutationSlotDefinition? bound;
    for (final candidate in earlier) {
      if (candidate.name == slotName) {
        bound = candidate;
        break;
      }
    }
    if (bound == null) {
      final declaredLater = declared.any(
        (candidate) =>
            candidate.name.value == slotName &&
            candidate.name.value != slot.name.value,
      );
      throw _error(
        binding.slot.span.start,
        declaredLater
            ? 'slot $label binds slot "$slotName", which must be declared '
                  'before it — declaration order is execution order'
            : 'slot $label binds unknown slot "$slotName"',
      );
    }
    if (bound.model != relation.target) {
      throw _error(
        binding.slot.span.start,
        'slot $label binds relation "$relationName" (targeting Model '
        '"${relation.target.name}") to slot "$slotName", which holds Model '
        '"${bound.model.name}"',
      );
    }
    if (bound.cardinality != MutationSlotCardinality.single) {
      throw _error(
        binding.slot.span.start,
        'slot $label binds slot "$slotName", which is not single-cardinality '
        '— binding to an optional or list slot is ambiguous',
      );
    }
    resolved.add(
      MutationSlotBindingDefinition(
        relation: relation.symbol,
        fields: relation.localFields,
        slot: bound.name,
      ),
    );
  }
  return resolved;
}

List<MutationSequenceSelectorDefinition> _resolveMutationSequenceSelectors(
  MutationSyntax syntax, {
  required MutationSymbol mutation,
  required List<MutationSlotDefinition> slots,
  required Map<
    String,
    ({
      MutationSyntax syntax,
      MutationSymbol symbol,
      List<MutationSlotDefinition> slots,
    })
  >
  mutations,
  required Map<ModelSymbol, ModelIdentity> identities,
  required Map<ModelSymbol, List<RelationDefinition>> relations,
}) {
  AnnotationSyntax? sequence;
  for (final annotation in syntax.annotations) {
    if (annotation.name.value == 'version') continue;
    if (annotation.name.value != 'sequence') {
      throw _error(
        annotation.name.span.start,
        'unknown mutation annotation "@@${annotation.name.value}"',
      );
    }
    if (sequence != null) {
      throw _error(
        annotation.name.span.start,
        'duplicate @@sequence on mutation "${mutation.name}"',
      );
    }
    sequence = annotation;
  }
  if (sequence == null) return const [];

  if (sequence.arguments.length != 1) {
    if (sequence.arguments.isEmpty) {
      throw _error(
        sequence.name.span.start,
        '@@sequence on mutation "${mutation.name}" requires after',
      );
    }
    throw _error(
      sequence.arguments[1].span.start,
      '@@sequence on mutation "${mutation.name}" takes exactly one '
      'argument: after',
    );
  }
  final argument = sequence.arguments.single;
  if (argument is! NamedArgumentSyntax || argument.name.value != 'after') {
    throw _error(
      argument.span.start,
      '@@sequence on mutation "${mutation.name}" requires after',
    );
  }
  final value = argument.value;
  if (value is! MutationSelectorListValueSyntax) {
    throw _error(
      value.span.start,
      '@@sequence after on mutation "${mutation.name}" must be a selector '
      'list',
    );
  }

  final seen = <String>{};
  final resolved = <MutationSequenceSelectorDefinition>[];
  for (final selector in value.selectors) {
    final predecessorName = selector.mutation.value;
    final predecessorMutation = mutations[predecessorName];
    if (predecessorMutation == null) {
      throw _error(
        selector.mutation.span.start,
        '@@sequence on mutation "${mutation.name}" names unknown predecessor '
        'Mutation "$predecessorName"',
      );
    }
    final predecessor = _resolveMutationSequenceEndpoint(
      selector.predecessor,
      owner: predecessorMutation.symbol,
      slots: predecessorMutation.slots,
      relations: relations,
    );
    if (selector.predecessor.components.length > 2) {
      throw _error(
        selector.predecessor.span.start,
        'predecessor path in @@sequence on mutation "${mutation.name}" may '
        'name at most one relation',
      );
    }
    final predecessorSlot = predecessorMutation.slots.singleWhere(
      (slot) => slot.name == predecessor.slot,
    );
    if (predecessor.relations.isNotEmpty &&
        predecessorSlot.operation != MutationOperationKind.create) {
      final relation = (relations[predecessorSlot.model] ?? const [])
          .singleWhere(
            (candidate) => candidate.symbol == predecessor.relations.single,
          );
      final identityFields = identities[predecessorSlot.model]!.fields.toSet();
      if (!identityFields.containsAll(relation.localFields)) {
        throw _error(
          selector.predecessor.span.start,
          'predecessor path in @@sequence on mutation "${mutation.name}" '
          'cannot be recovered from queued ${predecessorMutation.symbol.name}.'
          '${predecessorSlot.name} identity values',
        );
      }
    }
    final current = _resolveMutationSequenceEndpoint(
      selector.current,
      owner: mutation,
      slots: slots,
      relations: relations,
    );
    if (predecessor.model != current.model) {
      throw _error(
        selector.current.span.start,
        '@@sequence on mutation "${mutation.name}" compares '
        '${predecessor.model.name} with ${current.model.name}',
      );
    }
    final label =
        '$predecessorName('
        '${_pathLabel(selector.predecessor)}:'
        '${_pathLabel(selector.current)})';
    if (!seen.add(label)) {
      throw _error(
        selector.span.start,
        'duplicate sequence selector "$label" in mutation '
        '"${mutation.name}"',
      );
    }
    resolved.add(
      MutationSequenceSelectorDefinition(
        predecessorMutation: predecessorMutation.symbol,
        predecessor: predecessor,
        current: current,
      ),
    );
  }
  return resolved;
}

MutationSequenceEndpointDefinition _resolveMutationSequenceEndpoint(
  IdentifierPathSyntax path, {
  required MutationSymbol owner,
  required List<MutationSlotDefinition> slots,
  required Map<ModelSymbol, List<RelationDefinition>> relations,
}) {
  final slotName = path.components.first.value;
  final slot = slots
      .where((candidate) => candidate.name == slotName)
      .firstOrNull;
  if (slot == null) {
    throw _error(
      path.components.first.span.start,
      'sequence path "${_pathLabel(path)}" names unknown slot '
      '"${owner.name}.$slotName"',
    );
  }
  var model = slot.model;
  final resolved = <RelationSymbol>[];
  for (final component in path.components.skip(1)) {
    final relation = (relations[model] ?? const [])
        .where((candidate) => candidate.symbol.name == component.value)
        .firstOrNull;
    if (relation == null) {
      throw _error(
        component.span.start,
        'sequence path "${_pathLabel(path)}" crosses '
        '"${model.name}.${component.value}", which is not a forward relation',
      );
    }
    resolved.add(relation.symbol);
    model = relation.target;
  }
  return MutationSequenceEndpointDefinition(
    slot: slotName,
    relations: resolved,
    model: model,
  );
}

String _pathLabel(IdentifierPathSyntax path) =>
    path.components.map((component) => component.value).join('.');

_ClassifiedModel _classifyModel(
  ModelSyntax syntax, {
  required ModelSymbol symbol,
  required Map<String, ModelSymbol> symbols,
  required Map<String, EnumSymbol> enumSymbols,
  required Map<String, PrerequisiteDefinition> prerequisites,
}) {
  final fields = <ModelFieldDefinition>[];
  final fieldsByName = <String, ModelFieldDefinition>{};
  final fieldSyntaxByName = <String, FieldSyntax>{};
  final relations = <FieldSyntax>[];
  final inverses = <FieldSyntax>[];
  final relationsByName = <String, FieldSyntax>{};
  final memberNames = <String>{};

  for (final member in syntax.fields) {
    final name = member.name.value;
    if (!memberNames.add(name)) {
      throw _error(
        member.name.span.start,
        'duplicate member "${symbol.name}.$name"',
      );
    }
    final scalar = _scalarTypes[member.typeName.value];
    if (scalar != null) {
      final prerequisite = _resolveValueFieldAnnotations(
        member,
        symbol,
        prerequisites: prerequisites,
        scalar: scalar,
      );
      final field = ModelFieldDefinition(
        symbol: FieldSymbol(model: symbol, name: name),
        valueType: member.list
            ? ScalarListValueType(scalar)
            : ScalarValueType(scalar),
        nullable: member.nullable,
        prerequisite: prerequisite,
      );
      fields.add(field);
      fieldsByName[name] = field;
      fieldSyntaxByName[name] = member;
    } else if (enumSymbols.containsKey(member.typeName.value)) {
      if (member.list) {
        throw _error(
          member.typeName.span.start,
          'enum lists are not supported',
        );
      }
      _resolveValueFieldAnnotations(
        member,
        symbol,
        prerequisites: prerequisites,
      );
      final field = ModelFieldDefinition(
        symbol: FieldSymbol(model: symbol, name: name),
        valueType: EnumValueType(enumSymbols[member.typeName.value]!),
        nullable: member.nullable,
      );
      fields.add(field);
      fieldsByName[name] = field;
      fieldSyntaxByName[name] = member;
    } else if (symbols.containsKey(member.typeName.value)) {
      // Which direction a Model-typed member is, is decided by one thing: the
      // side that stores the key says `@reference`. Everything else is the
      // virtual reverse half.
      if (member.annotations.any(_declaresReference)) {
        if (member.list) {
          throw _error(
            member.typeName.span.start,
            'relation "${symbol.name}.$name" holds the stored key, so it '
            'cannot be a list',
          );
        }
        relations.add(member);
        relationsByName[name] = member;
      } else {
        inverses.add(member);
        relationsByName[name] = member;
      }
    } else {
      throw _error(
        member.typeName.span.start,
        'unknown field type "${member.typeName.value}"',
      );
    }
  }

  return _ClassifiedModel(
    syntax: syntax,
    symbol: symbol,
    fields: fields,
    fieldsByName: fieldsByName,
    fieldSyntaxByName: fieldSyntaxByName,
    relations: relations,
    inverses: inverses,
    relationsByName: relationsByName,
  );
}

/// Whether this annotation claims the stored-key side of a relation.
///
/// The retired spellings count: a member written `@parent` is a reference the
/// author has not migrated yet, and it must reach the reference resolver to be
/// told so rather than be mistaken for a reverse half.
bool _declaresReference(AnnotationSyntax annotation) =>
    const {'reference', 'parent', 'relation'}.contains(annotation.name.value);

/// Resolves one typed prerequisite on a scalar value field.
PrerequisiteRequirementDefinition? _resolveValueFieldAnnotations(
  FieldSyntax field,
  ModelSymbol model, {
  required Map<String, PrerequisiteDefinition> prerequisites,
  ScalarType? scalar,
}) {
  PrerequisiteRequirementDefinition? prerequisite;
  for (final annotation in field.annotations) {
    final name = annotation.name.value;
    final member = '${model.name}.${field.name.value}';
    if (name == 'sendWhenReady') {
      throw _error(annotation.name.span.start, _retiredSendWhenReady);
    }
    if (name == 'requires') {
      if (prerequisite != null) {
        throw _error(annotation.name.span.start, 'duplicate @requires');
      }
      if (field.list || scalar == null) {
        throw _error(
          annotation.name.span.start,
          '@requires requires a non-list scalar field, and "$member" is not one',
        );
      }
      if (annotation.arguments.length != 1 ||
          annotation.arguments.single is! InvocationArgumentSyntax) {
        throw _error(
          annotation.span.start,
          '@requires expects one prerequisite invocation',
        );
      }
      final invocation =
          annotation.arguments.single as InvocationArgumentSyntax;
      final declaration = prerequisites[invocation.name.value];
      if (declaration == null) {
        throw _error(
          invocation.name.span.start,
          'unknown prerequisite "${invocation.name.value}"',
        );
      }
      final parameters = {
        for (final parameter in declaration.parameters)
          parameter.name: parameter,
      };
      final arguments = <String, PrerequisiteBinding>{};
      for (final argument in invocation.arguments) {
        final parameter = parameters[argument.name.value];
        if (parameter == null) {
          throw _error(
            argument.name.span.start,
            'unknown prerequisite argument "${argument.name.value}"',
          );
        }
        if (arguments.containsKey(argument.name.value)) {
          throw _error(
            argument.name.span.start,
            'duplicate prerequisite argument "${argument.name.value}"',
          );
        }
        final value = argument.value;
        if (value is! IdentifierValueSyntax || value.value.value != 'self') {
          throw _error(
            value.span.start,
            'prerequisite arguments must bind self',
          );
        }
        if (parameter.type != scalar) {
          throw _error(
            value.span.start,
            'prerequisite argument "${argument.name.value}" expects ${parameter.type.name} but "$member" is ${scalar.name}',
          );
        }
        arguments[argument.name.value] = PrerequisiteBinding.self;
      }
      for (final parameter in declaration.parameters) {
        if (!arguments.containsKey(parameter.name)) {
          throw _error(
            invocation.span.end,
            'missing prerequisite argument "${parameter.name}"',
          );
        }
      }
      prerequisite = PrerequisiteRequirementDefinition(
        prerequisite: declaration.symbol,
        arguments: arguments,
      );
      continue;
    }
    throw _error(
      annotation.name.span.start,
      name == 'readyToSend'
          ? _retiredReadyToSend
          : name == 'parent'
          ? _retiredParent
          : name == 'relation'
          ? _retiredRelation
          : name == 'reference'
          ? 'value field "$member" cannot use @reference'
          : 'unknown field annotation "@$name"',
    );
  }
  return prerequisite;
}

_ModelAnnotations _resolveModelAnnotations(ModelSyntax syntax) {
  AnnotationSyntax? identity;
  final unique = <AnnotationSyntax>[];
  for (final annotation in syntax.annotations) {
    switch (annotation.name.value) {
      case 'id':
        if (identity != null) {
          throw _error(annotation.name.span.start, 'duplicate @@id annotation');
        }
        identity = annotation;
      case 'unique':
        unique.add(annotation);
      default:
        throw _error(
          annotation.name.span.start,
          'unknown Model annotation "@@${annotation.name.value}"',
        );
    }
  }
  return _ModelAnnotations(identity: identity, unique: unique);
}

ModelIdentity _resolveIdentity(
  _ClassifiedModel model,
  _ModelAnnotations annotations,
) {
  final identitySyntax = annotations.identity;
  if (identitySyntax == null) {
    throw _error(
      model.syntax.name.span.start,
      'Model "${model.symbol.name}" requires @@id(field, ...)',
    );
  }
  if (identitySyntax.arguments.isEmpty) {
    throw _error(
      identitySyntax.name.span.start,
      '@@id requires at least one scalar field',
    );
  }

  final fields = _resolveScalarFieldArguments(
    identitySyntax,
    model: model,
    annotationName: 'id',
  );
  for (var index = 0; index < fields.length; index += 1) {
    if (fields[index].nullable) {
      throw _error(
        identitySyntax.arguments[index].span.start,
        'identity field "${fields[index].symbol}" cannot be nullable',
      );
    }
  }
  return ModelIdentity(fields.map((field) => field.symbol));
}

List<UniqueConstraint> _resolveUniqueConstraints(
  _ClassifiedModel model,
  List<AnnotationSyntax> syntaxes,
  ModelIdentity identity,
) {
  final constraints = <UniqueConstraint>[];
  final fieldsBySet = <String, List<ModelFieldDefinition>>{};
  for (final syntax in syntaxes) {
    final fields = _resolveScalarFieldArguments(
      syntax,
      model: model,
      annotationName: 'unique',
    );
    if (fields.isEmpty) {
      throw _error(
        syntax.name.span.start,
        '@@unique requires at least one scalar field',
      );
    }
    for (var index = 0; index < fields.length; index += 1) {
      final field = fields[index];
      if (field.nullable) {
        throw _error(
          syntax.arguments[index].span.start,
          'unique field "${field.symbol}" cannot be nullable',
        );
      }
    }

    final sortedNames = fields.map((field) => field.symbol.name).toList()
      ..sort();
    final key = sortedNames.join('\u0000');
    final identityNames = identity.fields.map((field) => field.name).toList()
      ..sort();
    if (key == identityNames.join('\u0000')) {
      throw _error(
        syntax.name.span.start,
        '@@unique duplicates the primary identity of ${model.symbol.name}',
      );
    }
    final previous = fieldsBySet[key];
    if (previous != null) {
      throw _error(
        syntax.name.span.start,
        'duplicate @@unique constraint on ${model.symbol.name}'
        '(${previous.map((field) => field.symbol.name).join(', ')})',
      );
    }
    fieldsBySet[key] = fields;
    constraints.add(UniqueConstraint(fields.map((field) => field.symbol)));
  }
  return constraints;
}

List<ModelFieldDefinition> _resolveScalarFieldArguments(
  AnnotationSyntax annotation, {
  required _ClassifiedModel model,
  required String annotationName,
}) {
  final fields = <ModelFieldDefinition>[];
  final seen = <String>{};
  for (final argument in annotation.arguments) {
    if (argument is! IdentifierArgumentSyntax) {
      throw _error(
        argument.span.start,
        '@@$annotationName requires field names',
      );
    }
    final name = argument.value;
    final field = model.fieldsByName[name];
    if (field == null) {
      if (model.relationsByName.containsKey(name)) {
        throw _error(
          argument.span.start,
          'relation "${model.symbol.name}.$name" cannot be used in '
          '@@$annotationName',
        );
      }
      throw _error(
        argument.span.start,
        'unknown field "$name" in @@$annotationName',
      );
    }
    if (!seen.add(name)) {
      throw _error(
        argument.span.start,
        'duplicate field "$name" in @@$annotationName',
      );
    }
    if (!field.isScalar) {
      throw _error(
        argument.span.start,
        'field "${field.symbol}" must be a scalar in @@$annotationName',
      );
    }
    fields.add(field);
  }
  return fields;
}

List<_ResolvedRelation> _resolveRelations(
  _ClassifiedModel model, {
  required Map<ModelSymbol, _ClassifiedModel> classified,
  required Map<ModelSymbol, ModelIdentity> identities,
}) {
  final relations = <_ResolvedRelation>[];
  SourceLocation? firstDeleteOnTarget;
  for (final syntax in model.relations) {
    final targetSymbol = ModelSymbol(syntax.typeName.value);
    final target = classified[targetSymbol]!;
    final relationName = '${model.symbol.name}.${syntax.name.value}';
    final annotation = _resolveReferenceAnnotation(syntax, relationName);
    final arguments = _resolveReferenceArguments(annotation, relationName);

    // The declaration is the whole of the key: the listed fields map
    // positionally onto the target's identity, in the order both were written.
    final targetIdentity = identities[target.symbol]!;
    if (arguments.via.length != targetIdentity.fields.length) {
      throw _error(
        arguments.viaLocation,
        'relation "$relationName" lists ${arguments.via.length} field(s) '
        'for the ${targetIdentity.fields.length}-field identity of '
        '"${target.symbol.name}"',
      );
    }
    final localFields = <ModelFieldDefinition>[];
    final referencedFields = <ModelFieldDefinition>[];
    final seenLocal = <String>{};
    for (var index = 0; index < arguments.via.length; index += 1) {
      final declared = arguments.via[index];
      final localName = declared.value;
      final referenced =
          target.fieldsByName[targetIdentity.fields[index].name]!;
      final local = model.fieldsByName[localName];
      if (local == null || !local.isScalar) {
        throw _error(
          declared.span.start,
          'relation "$relationName" requires a scalar field "$localName" '
          'for "${referenced.symbol}"',
        );
      }
      if (!seenLocal.add(localName)) {
        throw _error(
          declared.span.start,
          'duplicate field "$localName" in relation "$relationName"',
        );
      }
      if (local.valueType != referenced.valueType) {
        throw _error(
          declared.span.start,
          'relation "$relationName" field "$localName" must match '
          'the type of "${referenced.symbol}"',
        );
      }
      if (local.nullable != syntax.nullable) {
        throw _error(
          declared.span.start,
          'relation "$relationName" and field "$localName" '
          'must have matching nullability',
        );
      }
      localFields.add(local);
      referencedFields.add(referenced);
    }

    if (arguments.deleteLocation != null) {
      if (syntax.nullable) {
        throw _error(
          arguments.deleteLocation!,
          'relation "$relationName" cannot be nullable and '
          'onTargetDelete: delete',
        );
      }
      if (firstDeleteOnTarget != null) {
        throw _error(
          arguments.deleteLocation!,
          'Model "${model.symbol.name}" may declare at most one '
          'onTargetDelete: delete relation',
        );
      }
      firstDeleteOnTarget = arguments.deleteLocation;
    }
    relations.add(
      _ResolvedRelation(
        definition: RelationDefinition(
          symbol: RelationSymbol(model: model.symbol, name: syntax.name.value),
          target: target.symbol,
          localFields: localFields.map((field) => field.symbol),
          referencedFields: referencedFields.map((field) => field.symbol),
          nullable: syntax.nullable,
          deleteOnTarget: arguments.deleteLocation != null,
          relationName: arguments.name,
        ),
        deleteOnTargetLocation: arguments.deleteLocation,
        relationNameLocation: arguments.nameLocation,
      ),
    );
  }
  return relations;
}

AnnotationSyntax _resolveReferenceAnnotation(
  FieldSyntax syntax,
  String relationName,
) {
  for (final annotation in syntax.annotations) {
    final name = annotation.name.value;
    if (name == 'relation') {
      throw _error(annotation.name.span.start, _retiredRelation);
    }
    if (name == 'parent') {
      throw _error(annotation.name.span.start, _retiredParent);
    }
    if (name == 'readyToSend') {
      throw _error(annotation.name.span.start, _retiredReadyToSend);
    }
    if (name != 'reference') {
      throw _error(
        annotation.name.span.start,
        'unknown field annotation "@$name"',
      );
    }
  }
  if (syntax.annotations.isEmpty) {
    throw _error(
      syntax.name.span.start,
      'relation "$relationName" requires @reference(via: [...])',
    );
  }
  if (syntax.annotations.length != 1) {
    throw _error(
      syntax.annotations[1].name.span.start,
      'relation "$relationName" requires exactly one @reference',
    );
  }
  return syntax.annotations.single;
}

/// What `@reference` declares: the stored key, and the rules it may impose.
///
/// `via` is required and ordered. An optional quoted name in first position is
/// the shared relation name the reverse half repeats. `onTargetDelete: delete`
/// propagates the target's deletion to this row.
_ResolvedReference _resolveReferenceArguments(
  AnnotationSyntax annotation,
  String relationName,
) {
  final locations = <String, SourceLocation>{};
  List<LocatedIdentifier>? via;
  SourceLocation? viaLocation;
  String? name;
  SourceLocation? nameLocation;
  for (var index = 0; index < annotation.arguments.length; index += 1) {
    final rawArgument = annotation.arguments[index];
    if (rawArgument is StringArgumentSyntax) {
      // The parser only admits a quoted argument in first place, so reaching
      // here at any other index is impossible.
      name = _relationName(rawArgument, '@reference', relationName);
      nameLocation = rawArgument.span.start;
      continue;
    }
    if (rawArgument is! NamedArgumentSyntax) {
      throw _error(
        rawArgument.span.start,
        '@reference takes a quoted relation name and named arguments',
      );
    }
    final argument = rawArgument.name.value;
    if (argument == 'delete') {
      throw _error(
        rawArgument.name.span.start,
        'relation "$relationName" argument "delete" is retired; use '
        'onTargetDelete: delete',
      );
    }
    if (argument == 'fields') {
      throw _error(
        rawArgument.name.span.start,
        'relation "$relationName" argument "fields" is retired; use via',
      );
    }
    if (argument == 'send') {
      throw _error(
        rawArgument.name.span.start,
        'relation "$relationName" argument "send" is retired; declare a '
        'mutation naming the writes that share fate',
      );
    }
    if (argument != 'via' && argument != 'onTargetDelete') {
      throw _error(
        rawArgument.name.span.start,
        'unknown @reference argument "$argument"',
      );
    }
    if (locations.containsKey(argument)) {
      throw _error(
        rawArgument.name.span.start,
        'duplicate @reference argument "$argument"',
      );
    }
    final value = rawArgument.value;
    locations[argument] = value.span.start;
    switch (argument) {
      case 'via':
        if (value is! IdentifierListValueSyntax) {
          throw _error(
            value.span.start,
            'relation "$relationName" via must be a list of field names',
          );
        }
        via = value.values;
        viaLocation = value.span.start;
      case 'onTargetDelete':
        if (value is! IdentifierValueSyntax || value.value.value != 'delete') {
          throw _error(
            value.span.start,
            'relation "$relationName" onTargetDelete must be "delete"',
          );
        }
    }
  }
  if (via == null || viaLocation == null) {
    throw _error(
      annotation.name.span.start,
      'relation "$relationName" requires @reference(via: [...])',
    );
  }
  return _ResolvedReference(
    via: via,
    viaLocation: viaLocation,
    name: name,
    nameLocation: nameLocation,
    deleteLocation: locations['onTargetDelete'],
  );
}

/// The quoted name shared by the two directions of one relation.
String _relationName(
  StringArgumentSyntax argument,
  String annotation,
  String member,
) {
  final value = argument.value;
  if (value.isEmpty) {
    throw _error(
      argument.span.start,
      '$annotation on "$member" requires a non-empty relation name',
    );
  }
  return value;
}

/// Pairs every virtual reverse field with the reference it is the other half of.
///
/// The rule is one sentence: an inverse pairs with the reference declared on
/// the type it names, pointing back at the Model it sits on. When exactly one
/// such reference exists the pairing needs no help; when several do, both
/// directions carry the same quoted name and the match is by that.
Map<ModelSymbol, List<InverseRelationDefinition>> _resolveInverses(
  Map<ModelSymbol, _ClassifiedModel> classified, {
  required Map<ModelSymbol, List<RelationDefinition>> relationsByModel,
  required Map<RelationSymbol, SourceLocation> relationNameLocations,
  required Map<ModelSymbol, ModelIdentity> identities,
  required Map<ModelSymbol, List<UniqueConstraint>> uniqueConstraints,
}) {
  _rejectDuplicateRelationNames(relationsByModel, relationNameLocations);

  final resolved = <ModelSymbol, List<InverseRelationDefinition>>{};
  final pairedBy = <RelationSymbol, RelationSymbol>{};
  for (final model in classified.values) {
    final inverses = <InverseRelationDefinition>[];
    final declaredNames = <String, String>{};
    for (final syntax in model.inverses) {
      final targetSymbol = ModelSymbol(syntax.typeName.value);
      final member = '${model.symbol.name}.${syntax.name.value}';
      final name = _resolveInverseAnnotation(syntax, member);
      if (name != null) {
        final previous = declaredNames[name];
        if (previous != null) {
          throw _error(
            syntax.name.span.start,
            'Model "${model.symbol.name}" declares relation "$name" twice, '
            'on "$previous" and "${syntax.name.value}"',
          );
        }
        declaredNames[name] = syntax.name.value;
      }

      final back = relationsByModel[targetSymbol]!
          .where((relation) => relation.target == model.symbol)
          .toList();
      final candidates = back
          .where((relation) => relation.relationName == name)
          .toList();
      if (candidates.isEmpty) {
        throw _error(
          syntax.name.span.start,
          _noCandidateMessage(member, model.symbol, targetSymbol, name, back),
        );
      }
      if (candidates.length > 1) {
        throw _error(
          syntax.name.span.start,
          'inverse "$member" matches ${candidates.length} references from '
          '"${targetSymbol.name}" '
          '(${candidates.map((relation) => relation.symbol.name).join(', ')}); '
          'give each direction the same quoted relation name',
        );
      }

      final reference = candidates.single;
      final claimed = pairedBy[reference.symbol];
      if (claimed != null) {
        throw _error(
          syntax.name.span.start,
          'reference "${reference.symbol}" already has the inverse '
          '"$claimed"',
        );
      }
      pairedBy[reference.symbol] = RelationSymbol(
        model: model.symbol,
        name: syntax.name.value,
      );

      final cardinality = syntax.list
          ? InverseCardinality.many
          : syntax.nullable
          ? InverseCardinality.optionalOne
          : InverseCardinality.one;
      if (cardinality != InverseCardinality.many &&
          !_isUniqueOn(
            reference.localFields,
            identity: identities[targetSymbol]!,
            uniqueConstraints: uniqueConstraints[targetSymbol]!,
          )) {
        throw _error(
          syntax.typeName.span.start,
          'inverse "$member" is to-one, and "${reference.symbol}" does not '
          'store its key in a unique field set of "${targetSymbol.name}" — '
          'declare it as "${targetSymbol.name}[]"',
        );
      }

      inverses.add(
        InverseRelationDefinition(
          symbol: RelationSymbol(model: model.symbol, name: syntax.name.value),
          target: targetSymbol,
          cardinality: cardinality,
          reference: reference.symbol,
          relationName: name,
        ),
      );
    }
    resolved[model.symbol] = inverses;
  }

  // A name is a promise of two halves. An unnamed reference may stand alone;
  // a named one that nothing answers is a typo waiting to be read as a feature.
  for (final relations in relationsByModel.values) {
    for (final relation in relations) {
      if (relation.relationName == null) continue;
      if (pairedBy.containsKey(relation.symbol)) continue;
      throw _error(
        relationNameLocations[relation.symbol]!,
        'reference "${relation.symbol}" names relation '
        '"${relation.relationName}", and "${relation.target.name}" declares no '
        'matching @inverse("${relation.relationName}")',
      );
    }
  }
  return resolved;
}

String _noCandidateMessage(
  String member,
  ModelSymbol model,
  ModelSymbol target,
  String? name,
  List<RelationDefinition> back,
) {
  if (name == null) {
    return back.isEmpty
        ? 'inverse "$member" has no reference: "${target.name}" declares no '
              '@reference to "${model.name}"'
        : 'inverse "$member" has no unnamed reference to pair with; '
              '"${target.name}" names '
              '${back.map((relation) => '"${relation.relationName}"').join(', ')}, '
              'so the inverse must name one too';
  }
  return 'inverse "$member" names relation "$name", and "${target.name}" '
      'declares no @reference("$name") to "${model.name}"';
}

void _rejectDuplicateRelationNames(
  Map<ModelSymbol, List<RelationDefinition>> relationsByModel,
  Map<RelationSymbol, SourceLocation> relationNameLocations,
) {
  for (final relations in relationsByModel.values) {
    final seen = <String, RelationSymbol>{};
    for (final relation in relations) {
      final name = relation.relationName;
      if (name == null) continue;
      final key = '${relation.target.name}\u0000$name';
      final previous = seen[key];
      if (previous != null) {
        throw _error(
          relationNameLocations[relation.symbol]!,
          'relation "$name" is declared twice on '
          '"${relation.symbol.model.name}", by "${previous.name}" and '
          '"${relation.symbol.name}"',
        );
      }
      seen[key] = relation.symbol;
    }
  }
}

/// Whether a key stored in [localFields] can name at most one row of its Model.
bool _isUniqueOn(
  List<FieldSymbol> localFields, {
  required ModelIdentity identity,
  required List<UniqueConstraint> uniqueConstraints,
}) {
  final key = localFields.map((field) => field.name).toSet();
  bool matches(List<FieldSymbol> fields) =>
      fields.length == key.length &&
      fields.every((field) => key.contains(field.name));
  return matches(identity.fields) ||
      uniqueConstraints.any((constraint) => matches(constraint.fields));
}

/// Reads `@inverse("Name")` off a virtual reverse field, rejecting all else.
String? _resolveInverseAnnotation(FieldSyntax syntax, String member) {
  String? name;
  for (final annotation in syntax.annotations) {
    final annotationName = annotation.name.value;
    if (annotationName == 'relation') {
      throw _error(annotation.name.span.start, _retiredRelation);
    }
    if (annotationName == 'parent') {
      throw _error(annotation.name.span.start, _retiredParent);
    }
    if (annotationName == 'readyToSend') {
      throw _error(annotation.name.span.start, _retiredReadyToSend);
    }
    if (annotationName != 'inverse') {
      throw _error(
        annotation.name.span.start,
        'unknown field annotation "@$annotationName"',
      );
    }
    if (name != null) {
      throw _error(annotation.name.span.start, 'duplicate @inverse');
    }
    if (annotation.arguments.length != 1 ||
        annotation.arguments.single is! StringArgumentSyntax) {
      throw _error(
        annotation.name.span.start,
        '@inverse on "$member" takes exactly one quoted relation name',
      );
    }
    name = _relationName(
      annotation.arguments.single as StringArgumentSyntax,
      '@inverse',
      member,
    );
  }
  return name;
}

void _rejectDeleteOnTargetCycles(
  ModelGraph graph,
  Map<RelationSymbol, SourceLocation> deleteOnTargetLocations,
) {
  for (final start in graph.models) {
    final trail = <ModelSymbol>[start.symbol];
    var current = start;
    while (true) {
      RelationDefinition? owner;
      for (final relation in current.relations) {
        if (relation.deleteOnTarget) {
          owner = relation;
          break;
        }
      }
      if (owner == null) break;
      final cycleStart = trail.indexOf(owner.target);
      if (cycleStart >= 0) {
        final cycle = [...trail.sublist(cycleStart), owner.target];
        throw _error(
          deleteOnTargetLocations[owner.symbol]!,
          'onTargetDelete: delete cycle: ${cycle.join(' -> ')}',
        );
      }
      trail.add(owner.target);
      current = graph.model(owner.target);
    }
  }
}

const _retiredRelation = '@relation is retired; use @reference(via: [...])';

const _retiredParent = '@parent is retired; use @reference(via: [...])';

const _retiredReadyToSend = '@readyToSend is retired; use @requires';

const _retiredSendWhenReady = '@sendWhenReady is retired; use @requires';

final class _ClassifiedModel {
  const _ClassifiedModel({
    required this.syntax,
    required this.symbol,
    required this.fields,
    required this.fieldsByName,
    required this.fieldSyntaxByName,
    required this.relations,
    required this.inverses,
    required this.relationsByName,
  });

  final ModelSyntax syntax;
  final ModelSymbol symbol;
  final List<ModelFieldDefinition> fields;
  final Map<String, ModelFieldDefinition> fieldsByName;
  final Map<String, FieldSyntax> fieldSyntaxByName;
  final List<FieldSyntax> relations;
  final List<FieldSyntax> inverses;
  final Map<String, FieldSyntax> relationsByName;
}

final class _ModelAnnotations {
  const _ModelAnnotations({required this.identity, required this.unique});

  final AnnotationSyntax? identity;
  final List<AnnotationSyntax> unique;
}

final class _ResolvedRelation {
  const _ResolvedRelation({
    required this.definition,
    required this.deleteOnTargetLocation,
    required this.relationNameLocation,
  });

  final RelationDefinition definition;
  final SourceLocation? deleteOnTargetLocation;
  final SourceLocation? relationNameLocation;
}

final class _ResolvedReference {
  const _ResolvedReference({
    required this.via,
    required this.viaLocation,
    required this.name,
    required this.nameLocation,
    required this.deleteLocation,
  });

  final List<LocatedIdentifier> via;
  final SourceLocation viaLocation;
  final String? name;
  final SourceLocation? nameLocation;
  final SourceLocation? deleteLocation;
}

DefinitionException _error(SourceLocation location, String message) =>
    DefinitionException(location: location, message: message);

int _mutationVersion(MutationSyntax syntax) {
  final annotations = syntax.annotations
      .where((a) => a.name.value == 'version')
      .toList();
  if (annotations.isEmpty) return 1;
  final annotation = annotations.first;
  if (annotations.length != 1 ||
      annotation.arguments.length != 1 ||
      annotation.arguments.single is! IntegerArgumentSyntax) {
    throw _error(
      annotation.name.span.start,
      '@@version requires one positive safe integer',
    );
  }
  final value = (annotation.arguments.single as IntegerArgumentSyntax).value;
  if (value < 1 || value > 9007199254740991) {
    throw _error(
      annotation.name.span.start,
      '@@version requires one positive safe integer',
    );
  }
  return value;
}
