import 'package:local_sync_compiler/src/syntax/ast.dart';
import 'package:local_sync_compiler/src/syntax/parser.dart';
import 'package:local_sync_compiler/src/syntax/source.dart';
import 'package:test/test.dart';

void main() {
  test('parses a typed prerequisite declaration', () {
    const source = ModelSource(
      path: 'models/media.model',
      contents: '''prerequisite RemoteBlob(key UUID)

model Photo {
  id     UUID
  blobId UUID @requires(RemoteBlob(key: self))
  @@id(id)
  @@shape(version: 1)
}
''',
    );

    final document = parseModel(source);

    final prerequisite = document.prerequisites.single;
    expect(prerequisite.name.value, 'RemoteBlob');
    expect(prerequisite.parameters.single.name.value, 'key');
    expect(prerequisite.parameters.single.typeName.value, 'UUID');
    final requirement = document.models.single.fields[1].annotations.single;
    expect(requirement.name.value, 'requires');
    final invocation = requirement.arguments.single as InvocationArgumentSyntax;
    expect(invocation.name.value, 'RemoteBlob');
    final binding = invocation.arguments.single;
    expect(binding.name.value, 'key');
    expect((binding.value as IdentifierValueSyntax).value.value, 'self');
  });

  test('parses enums and scalar list fields without resolving them', () {
    const source = ModelSource(
      path: 'models/account.model',
      contents: '''enum SpaceKind {
  personal
  group
}

model AccountState {
  userId UUID
  spaceOrder UUID[]
  @@id(userId)
  @@shape(version: 1)
}
''',
    );

    final document = parseModel(source);

    expect(document.enums, hasLength(1));
    expect(document.enums.single.name.value, 'SpaceKind');
    expect(document.enums.single.values.map((value) => value.value), [
      'personal',
      'group',
    ]);
    expect(document.models, hasLength(1));
    expect(document.models.single.fields.map((field) => field.list), [
      false,
      true,
    ]);
  });

  test(
    'parses Models, fields, and annotations without resolving semantics',
    () {
      const source = ModelSource(
        path: 'models/star.model',
        contents: '''model Star {
  id     UUID
  userId UUID
  user   User @relation(
    fields: [userId],
    references: [id],
    onDelete: Cascade
  )
  @@id(id)
  @@shape(version: 1)
}
''',
      );

      final document = parseModel(source);

      expect(document.models, hasLength(1));
      final star = document.models.single;
      expect(star.name.value, 'Star');
      expect(star.fields.map((field) => field.name.value), [
        'id',
        'userId',
        'user',
      ]);
      expect(star.fields.map((field) => field.typeName.value), [
        'UUID',
        'UUID',
        'User',
      ]);
      expect(star.fields.map((field) => field.nullable), [false, false, false]);
      final relation = star.fields.last.annotations.single;
      expect(relation.name.value, 'relation');
      final relationArguments = relation.arguments
          .whereType<NamedArgumentSyntax>()
          .toList();
      expect(relationArguments, hasLength(3));
      expect(relationArguments.map((argument) => argument.name.value), [
        'fields',
        'references',
        'onDelete',
      ]);
      expect(
        (relationArguments[0].value as IdentifierListValueSyntax).values.map(
          (value) => value.value,
        ),
        ['userId'],
      );
      expect(
        (relationArguments[1].value as IdentifierListValueSyntax).values.map(
          (value) => value.value,
        ),
        ['id'],
      );
      expect(
        (relationArguments[2].value as IdentifierValueSyntax).value.value,
        'Cascade',
      );
      expect(star.annotations.map((annotation) => annotation.name.value), [
        'id',
        'shape',
      ]);
      expect(
        star.annotations.first.arguments
            .whereType<IdentifierArgumentSyntax>()
            .map((argument) => argument.value),
        ['id'],
      );
      expect(
        ((star.annotations.last.arguments.single as NamedArgumentSyntax).value
                as IntegerValueSyntax)
            .value,
        1,
      );
      expect(star.span.start.line, 1);
      expect(star.span.end.line, 11);
    },
  );

  test('rejects positional field annotation arguments', () {
    const source = ModelSource(
      path: 'models/space.model',
      contents: '''model Space {
  owner User @relation(cascade)
  @@id(owner)
  @@shape(version: 1)
}
''',
    );

    expect(
      () => parseModel(source),
      throwsA(
        isA<DefinitionException>()
            .having((error) => error.location.line, 'line', 2)
            .having((error) => error.location.column, 'column', 31)
            .having(
              (error) => error.message,
              'message',
              'expected ":" after field annotation argument name',
            ),
      ),
    );
  });

  test('parses slot bindings between the operation and the cardinality', () {
    const source = ModelSource(
      path: 'models/moment.model',
      contents: '''mutation CreateMoment {
  moment Moment.create
  photos MomentPhoto.create(moment: moment)[]
  tags   StarTag.create(star: star, moment: moment)

  @@version(1)
}
''',
    );

    final document = parseModel(source);

    final slots = document.mutations.single.slots;
    expect(slots.first.bindings, isEmpty);
    expect(slots[1].bindings, hasLength(1));
    expect(slots[1].bindings.single.relation.value, 'moment');
    expect(slots[1].bindings.single.slot.value, 'moment');
    expect(slots[1].cardinality, MutationSlotCardinalitySyntax.list);
    expect(slots.last.bindings.map((binding) => binding.relation.value), [
      'star',
      'moment',
    ]);
    expect(slots.last.cardinality, MutationSlotCardinalitySyntax.single);
  });

  test('parses update projections before bindings and cardinality', () {
    const source = ModelSource(
      path: 'models/moment.model',
      contents: '''mutation UpdateMoment {
  moment Moment.update<
    caption,
    spaceId
  >
  related Moment.update<caption>(space: moment)[]
}
''',
    );

    final slots = parseModel(source).mutations.single.slots;

    expect(slots.first.patchFields.map((field) => field.value), [
      'caption',
      'spaceId',
    ]);
    expect(slots.first.bindings, isEmpty);
    expect(slots.last.patchFields.map((field) => field.value), ['caption']);
    expect(slots.last.bindings.single.relation.value, 'space');
    expect(slots.last.cardinality, MutationSlotCardinalitySyntax.list);
  });

  test('parses mutation sequence selectors without resolving them', () {
    const source = ModelSource(
      path: 'models/moment.model',
      contents: '''mutation CreateMoment {
  moment Moment.create

  @@sequence(after: [
    SetSpaceVisibility(space: moment.space)
  ])
}
''',
    );

    final document = parseModel(source);
    final argument =
        document.mutations.single.annotations.single.arguments.single
            as NamedArgumentSyntax;
    final dynamic value = argument.value;
    expect(value.runtimeType.toString(), 'MutationSelectorListValueSyntax');
    expect(value.selectors.single.mutation.value, 'SetSpaceVisibility');
    expect(
      value.selectors.single.predecessor.components.map(
        (dynamic part) => part.value,
      ),
      ['space'],
    );
    expect(
      value.selectors.single.current.components.map(
        (dynamic part) => part.value,
      ),
      ['moment', 'space'],
    );
  });

  for (final invalid in <({String name, String source, String message})>[
    (
      name: 'bare update slot',
      source: '''mutation UpdateMoment {
  moment Moment.update
}
''',
      message: 'expected "<" after update operation',
    ),
    (
      name: 'empty update projection',
      source: '''mutation UpdateMoment {
  moment Moment.update<>
}
''',
      message: 'expected field in update projection',
    ),
    (
      name: 'create projection',
      source: '''mutation CreateMoment {
  moment Moment.create<caption>
}
''',
      message: 'only update slots may declare a patch projection',
    ),
    (
      name: 'delete projection',
      source: '''mutation DeleteMoment {
  moment Moment.delete<caption>
}
''',
      message: 'only update slots may declare a patch projection',
    ),
    (
      name: 'trailing update projection comma',
      source: '''mutation UpdateMoment {
  moment Moment.update<caption,>
}
''',
      message: 'expected field in update projection',
    ),
    (
      name: 'empty slot binding list',
      source: '''mutation CreateMoment {
  photos MomentPhoto.create()[]
}
''',
      message: 'expected a "relation: slot" binding',
    ),
    (
      name: 'slot binding without a colon',
      source: '''mutation CreateMoment {
  photos MomentPhoto.create(moment)[]
}
''',
      message: 'expected ":" after binding relation name',
    ),
    (
      name: 'unclosed slot binding list',
      source: '''mutation CreateMoment {
  photos MomentPhoto.create(moment: moment[]
}
''',
      message: 'expected ")" after bindings',
    ),
    (
      name: 'missing closing brace',
      source: 'model User {\n  id UUID\n',
      message: 'expected field, Model annotation, or "}"',
    ),
    (
      name: 'empty annotation arguments',
      source: 'model User { id UUID @@id() }',
      message: 'expected annotation argument',
    ),
    (
      name: 'trailing annotation comma',
      source: 'model User { id UUID @@id(id,) }',
      message: 'expected identifier or integer argument',
    ),
    (
      name: 'unsupported Model annotation scalar value',
      source: 'model User { id UUID @@shape(version: one) }',
      message: 'expected integer or "[" for Model annotation value',
    ),
    (
      name: 'oversized integer literal',
      source:
          'model User { id UUID @@shape(version: 99999999999999999999999999999999999999999999999999) }',
      message: 'integer literal is out of range',
    ),
    (
      name: 'external Model migration syntax',
      source: 'external model User',
      message:
          'expected "enum", "model", "mutation", or "prerequisite" declaration',
    ),
    (
      name: 'nullable list',
      source:
          'model AccountState { userId UUID spaceOrder UUID[]? @@id(userId) @@shape(version: 1) }',
      message: 'scalar lists cannot be nullable',
    ),
    (
      name: 'nested list',
      source:
          'model AccountState { userId UUID spaceOrder UUID[][] @@id(userId) @@shape(version: 1) }',
      message: 'nested lists are not supported',
    ),
  ]) {
    test('rejects ${invalid.name} with a source location', () {
      expect(
        () => parseModel(
          ModelSource(path: 'models/invalid.model', contents: invalid.source),
        ),
        throwsA(
          isA<DefinitionException>()
              .having(
                (error) => error.location.path,
                'path',
                'models/invalid.model',
              )
              .having((error) => error.location.line, 'line', greaterThan(0))
              .having(
                (error) => error.location.column,
                'column',
                greaterThan(0),
              )
              .having((error) => error.message, 'message', invalid.message),
        ),
      );
    });
  }
}
