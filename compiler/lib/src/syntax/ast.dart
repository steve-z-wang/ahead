import 'source.dart';

final class ModelDocumentSyntax {
  const ModelDocumentSyntax({
    required this.source,
    required this.enums,
    required this.models,
    this.mutations = const [],
    this.prerequisites = const [],
  });

  final ModelSource source;
  final List<EnumSyntax> enums;
  final List<ModelSyntax> models;
  final List<MutationSyntax> mutations;
  final List<PrerequisiteSyntax> prerequisites;
}

/// One product-supplied preparation capability declared by the schema.
final class PrerequisiteSyntax {
  const PrerequisiteSyntax({
    required this.name,
    required this.parameters,
    required this.span,
  });

  final LocatedIdentifier name;
  final List<PrerequisiteParameterSyntax> parameters;
  final SourceSpan span;
}

final class PrerequisiteParameterSyntax {
  const PrerequisiteParameterSyntax({
    required this.name,
    required this.typeName,
    required this.span,
  });

  final LocatedIdentifier name;
  final LocatedIdentifier typeName;
  final SourceSpan span;
}

/// A named group of operations — the product's write vocabulary (CAP-439).
///
/// The block carries slots in declaration order, which is execution order,
/// plus client-only act policy such as `@@sequence`. Every declared mutation
/// remains a wire act (CAP-488).
final class MutationSyntax {
  const MutationSyntax({
    required this.name,
    required this.slots,
    required this.annotations,
    required this.span,
  });

  final LocatedIdentifier name;
  final List<MutationSlotSyntax> slots;
  final List<AnnotationSyntax> annotations;
  final SourceSpan span;
}

/// How many rows of one `(Model, op)` pair a slot stands for.
enum MutationSlotCardinalitySyntax { single, optional, list }

/// One `fieldName Model.op` line, with an update patch projection, optional
/// bindings, and an optional `?` or `[]`.
final class MutationSlotSyntax {
  const MutationSlotSyntax({
    required this.name,
    required this.modelName,
    required this.operation,
    required this.patchFields,
    required this.bindings,
    required this.cardinality,
    required this.span,
  });

  final LocatedIdentifier name;
  final LocatedIdentifier modelName;
  final LocatedIdentifier operation;
  final List<LocatedIdentifier> patchFields;
  final List<MutationSlotBindingSyntax> bindings;
  final MutationSlotCardinalitySyntax cardinality;
  final SourceSpan span;
}

/// One `relation: slot` pair in a slot's parenthesized binding list —
/// this slot's rows point at the row another slot of the act carries.
final class MutationSlotBindingSyntax {
  const MutationSlotBindingSyntax({
    required this.relation,
    required this.slot,
    required this.span,
  });

  final LocatedIdentifier relation;
  final LocatedIdentifier slot;
  final SourceSpan span;
}

final class EnumSyntax {
  const EnumSyntax({
    required this.name,
    required this.values,
    required this.span,
  });

  final LocatedIdentifier name;
  final List<LocatedIdentifier> values;
  final SourceSpan span;
}

final class LocatedIdentifier {
  const LocatedIdentifier({required this.value, required this.span});

  final String value;
  final SourceSpan span;
}

final class ModelSyntax {
  const ModelSyntax({
    required this.name,
    required this.fields,
    required this.annotations,
    required this.span,
  });

  final LocatedIdentifier name;
  final List<FieldSyntax> fields;
  final List<AnnotationSyntax> annotations;
  final SourceSpan span;
}

final class FieldSyntax {
  const FieldSyntax({
    required this.name,
    required this.typeName,
    required this.list,
    required this.nullable,
    required this.annotations,
    required this.span,
  });

  final LocatedIdentifier name;
  final LocatedIdentifier typeName;
  final bool list;
  final bool nullable;
  final List<AnnotationSyntax> annotations;
  final SourceSpan span;
}

final class AnnotationSyntax {
  const AnnotationSyntax({
    required this.name,
    required this.arguments,
    required this.span,
  });

  final LocatedIdentifier name;
  final List<AnnotationArgumentSyntax> arguments;
  final SourceSpan span;
}

sealed class AnnotationArgumentSyntax {
  const AnnotationArgumentSyntax({required this.span});

  final SourceSpan span;
}

final class IdentifierArgumentSyntax extends AnnotationArgumentSyntax {
  const IdentifierArgumentSyntax({required this.value, required super.span});

  final String value;
}

final class IntegerArgumentSyntax extends AnnotationArgumentSyntax {
  const IntegerArgumentSyntax({required this.value, required super.span});

  final int value;
}

/// A quoted positional argument — the relation name on `@reference`/`@inverse`.
final class StringArgumentSyntax extends AnnotationArgumentSyntax {
  const StringArgumentSyntax({required this.value, required super.span});

  final String value;
}

/// A typed invocation such as `RemoteBlob(key: self)` inside `@requires`.
final class InvocationArgumentSyntax extends AnnotationArgumentSyntax {
  const InvocationArgumentSyntax({
    required this.name,
    required this.arguments,
    required super.span,
  });

  final LocatedIdentifier name;
  final List<NamedArgumentSyntax> arguments;
}

final class NamedArgumentSyntax extends AnnotationArgumentSyntax {
  const NamedArgumentSyntax({
    required this.name,
    required this.value,
    required super.span,
  });

  final LocatedIdentifier name;
  final AnnotationValueSyntax value;
}

sealed class AnnotationValueSyntax {
  const AnnotationValueSyntax({required this.span});

  final SourceSpan span;
}

final class IdentifierValueSyntax extends AnnotationValueSyntax {
  const IdentifierValueSyntax({required this.value, required super.span});

  final LocatedIdentifier value;
}

final class IntegerValueSyntax extends AnnotationValueSyntax {
  const IntegerValueSyntax({required this.value, required super.span});

  final int value;
}

final class IdentifierListValueSyntax extends AnnotationValueSyntax {
  IdentifierListValueSyntax({
    required Iterable<LocatedIdentifier> values,
    required super.span,
  }) : values = List.unmodifiable(values);

  final List<LocatedIdentifier> values;
}

final class IdentifierPathSyntax {
  IdentifierPathSyntax({
    required Iterable<LocatedIdentifier> components,
    required this.span,
  }) : components = List.unmodifiable(components);

  final List<LocatedIdentifier> components;
  final SourceSpan span;
}

final class IdentifierPathListValueSyntax extends AnnotationValueSyntax {
  IdentifierPathListValueSyntax({
    required Iterable<IdentifierPathSyntax> paths,
    required super.span,
  }) : paths = List.unmodifiable(paths);

  final List<IdentifierPathSyntax> paths;
}

/// One `TargetMutation(target.path: current.path)` entry in `@@sequence`.
final class MutationSelectorSyntax {
  const MutationSelectorSyntax({
    required this.mutation,
    required this.predecessor,
    required this.current,
    required this.span,
  });

  final LocatedIdentifier mutation;
  final IdentifierPathSyntax predecessor;
  final IdentifierPathSyntax current;
  final SourceSpan span;
}

final class MutationSelectorListValueSyntax extends AnnotationValueSyntax {
  MutationSelectorListValueSyntax({
    required Iterable<MutationSelectorSyntax> selectors,
    required super.span,
  }) : selectors = List.unmodifiable(selectors);

  final List<MutationSelectorSyntax> selectors;
}
