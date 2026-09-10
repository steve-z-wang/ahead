import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  test('resolves a typed prerequisite requirement on a scalar field', () {
    final graph = compileModelSources({
      'models/photo.model': '''prerequisite RemoteBlob(key UUID)

model MomentPhoto {
  id     UUID
  blobId UUID @requires(RemoteBlob(key: self))
  @@id(id)
}
''',
    });

    final prerequisite = graph.prerequisites.single;
    expect(prerequisite.symbol.name, 'RemoteBlob');
    expect(prerequisite.parameters.single.name, 'key');
    expect(prerequisite.parameters.single.type, ScalarType.uuid);
    final photo = graph.model(const ModelSymbol('MomentPhoto'));
    final requirement = photo.fields
        .singleWhere((field) => field.symbol.name == 'blobId')
        .prerequisite!;
    expect(requirement.prerequisite, prerequisite.symbol);
    expect(requirement.arguments, {'key': PrerequisiteBinding.self});
  });

  test('resolves cross-file enums and scalar lists', () {
    final graph = compileModelSources({
      'models/account.model': '''enum SpaceKind {
  personal
  group
}

model AccountState {
  userId UUID
  spaceOrder UUID[]
  @@id(userId)
}
''',
      'models/space.model': '''model Space {
  id UUID
  kind SpaceKind
  previousKind SpaceKind?
  @@id(id)
}
''',
    });

    expect(graph.enums.single.symbol.name, 'SpaceKind');
    expect(graph.enums.single.values.map((value) => value.name), [
      'personal',
      'group',
    ]);
    final account = graph.model(const ModelSymbol('AccountState'));
    expect(
      account.fields
          .singleWhere((field) => field.symbol.name == 'spaceOrder')
          .valueType,
      const ScalarListValueType(ScalarType.uuid),
    );
    final space = graph.model(const ModelSymbol('Space'));
    expect(
      space.fields
          .singleWhere((field) => field.symbol.name == 'kind')
          .valueType,
      const EnumValueType(EnumSymbol('SpaceKind')),
    );
    expect(
      space.fields
          .singleWhere((field) => field.symbol.name == 'previousKind')
          .nullable,
      isTrue,
    );
  });

  for (final invalid in <({String name, String source, String message})>[
    (
      name: 'empty enum',
      source: 'enum Empty {} model Item { id UUID @@id(id) }',
      message: 'enum "Empty" requires a value',
    ),
    (
      name: 'duplicate enum value',
      source: 'enum State { open open } model Item { id UUID @@id(id) }',
      message: 'duplicate value "open" in enum "State"',
    ),
    (
      name: 'enum and Model collision',
      source: 'enum State { open } model State { id UUID @@id(id) }',
      message: 'duplicate type name "State"',
    ),
    (
      name: 'enum identity',
      source: 'enum State { open } model Item { state State @@id(state) }',
      message: 'field "Item.state" must be a scalar in @@id',
    ),
    (
      name: 'list unique',
      source: 'model Item { id UUID tags String[] @@id(id) @@unique(tags) }',
      message: 'field "Item.tags" must be a scalar in @@unique',
    ),
    (
      name: 'enum list',
      source:
          'enum State { open } model Item { id UUID states State[] @@id(id) }',
      message: 'enum lists are not supported',
    ),
    (
      name: 'a list holding the stored key',
      source:
          'model User { id UUID @@id(id) } '
          'model Item { id UUID userId UUID users User[] '
          '@reference(via: [userId]) @@id(id) }',
      message:
          'relation "Item.users" holds the stored key, so it cannot be a list',
    ),
  ]) {
    test('rejects ${invalid.name}', () {
      expect(
        () => compileModelSources({'models/invalid.model': invalid.source}),
        throwsA(
          isA<DefinitionException>().having(
            (error) => error.message,
            'message',
            invalid.message,
          ),
        ),
      );
    });
  }

  test('maps a composite field list onto the target identity in order', () {
    final graph = compileModelSources({
      'models/parent.model': '''model Parent {
  tenantId UUID
  number Int
  @@id(tenantId, number)
}
''',
      'models/child.model': '''model Child {
  id UUID
  branchId UUID
  ordinal Int
  parent Parent @reference(via: [branchId, ordinal])
  @@id(id)
}
''',
    });

    expect(
      graph
          .model(const ModelSymbol('Parent'))
          .identity
          .fields
          .map((field) => field.name),
      ['tenantId', 'number'],
    );
    final relation = graph.model(const ModelSymbol('Child')).relations.single;
    // The declaration is the key, and its order is the target identity's:
    // nothing here shares a name with what it points at.
    expect(relation.localFields.map((field) => field.name), [
      'branchId',
      'ordinal',
    ]);
    expect(relation.referencedFields.map((field) => field.name), [
      'tenantId',
      'number',
    ]);
  });

  test('takes the stored key from the declaration, never the name', () {
    final graph = compileModelSources({
      'models/space.model': 'model Space { id UUID @@id(id) }',
      'models/moment.model': '''model Moment {
  id UUID
  spaceId UUID
  book Space @reference(via: [spaceId])
  @@id(id)
}
''',
    });

    final relation = graph.model(const ModelSymbol('Moment')).relations.single;
    expect(relation.symbol.name, 'book');
    expect(relation.localFields.single.name, 'spaceId');
    expect(relation.referencedFields.single.name, 'id');
  });

  test('pairs a reverse half with the one reference that points back', () {
    final graph = compileModelSources({
      'moment.model': '''model Moment {
  id     UUID
  photos MomentPhoto[]
  @@id(id)
}
''',
      'photo.model': '''model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId], onTargetDelete: delete)
  @@id(id)
}
''',
    });

    final moment = graph.model(const ModelSymbol('Moment'));
    // Virtual, and provably so: the reverse half is not among the Model's
    // fields, so nothing downstream can turn it into a column.
    expect(moment.fields.map((field) => field.symbol.name), ['id']);
    expect(moment.relations, isEmpty);
    final inverse = moment.inverses.single;
    expect(inverse.symbol.name, 'photos');
    expect(inverse.target, const ModelSymbol('MomentPhoto'));
    expect(inverse.cardinality, InverseCardinality.many);
    expect(inverse.reference.toString(), 'MomentPhoto.moment');
    expect(inverse.relationName, isNull);
  });

  test('reads cardinality off the reverse half\'s own type', () {
    final graph = compileModelSources({
      'user.model': '''model User {
  id      UUID
  state   AccountState?
  places  Place[]
  @@id(id)
}
''',
      // Its identity IS the key, so at most one row can point back.
      'account.model': '''model AccountState {
  userId UUID
  user User @reference(via: [userId], onTargetDelete: delete)
  @@id(userId)
}
''',
      'place.model': '''model Place {
  id     UUID
  userId UUID
  user User @reference(via: [userId])
  @@id(id)
}
''',
    });

    final user = graph.model(const ModelSymbol('User'));
    expect(user.inverses.map((inverse) => inverse.cardinality), [
      InverseCardinality.optionalOne,
      InverseCardinality.many,
    ]);
  });

  test('tells two relations between the same pair apart by name', () {
    final graph = compileModelSources({
      'moment.model': '''model Moment {
  id            UUID
  outgoingLinks MomentLink[] @inverse("Source")
  incomingLinks MomentLink[] @inverse("Target")
  @@id(id)
}
''',
      'link.model': '''model MomentLink {
  id       UUID
  sourceId UUID
  targetId UUID
  source Moment @reference("Source", via: [sourceId])
  target Moment @reference("Target", via: [targetId])
  @@id(id)
}
''',
    });

    final link = graph.model(const ModelSymbol('MomentLink'));
    expect(
      link.relations.map(
        (relation) => (relation.relationName, relation.localFields.single.name),
      ),
      [('Source', 'sourceId'), ('Target', 'targetId')],
    );
    final moment = graph.model(const ModelSymbol('Moment'));
    expect(
      moment.inverses.map(
        (inverse) =>
            (inverse.symbol.name, inverse.relationName, inverse.reference.name),
      ),
      [
        ('outgoingLinks', 'Source', 'source'),
        ('incomingLinks', 'Target', 'target'),
      ],
    );
  });

  test('lets one field carry more than one reference', () {
    final graph = compileModelSources({
      'models/user.model': 'model User { id UUID @@id(id) }',
      'models/note.model': '''model Note {
  id UUID
  userId UUID
  author User @reference(via: [userId])
  keeper User @reference(via: [userId])
  @@id(id)
}
''',
    });

    final note = graph.model(const ModelSymbol('Note'));
    expect(note.relations.map((relation) => relation.symbol.name), [
      'author',
      'keeper',
    ]);
    for (final relation in note.relations) {
      expect(relation.localFields.single.name, 'userId');
      expect(relation.referencedFields.single.name, 'id');
    }
  });

  test('declares field prerequisites beside reference delete policy', () {
    final graph = compileModelSources({
      'models/moment.model': '''prerequisite RemoteObject(key String)

model Moment {
  id UUID
  @@id(id)
}
''',
      'models/photo.model': '''model MomentPhoto {
  id UUID
  momentId UUID
  key String @requires(RemoteObject(key: self))
  moment Moment @reference(via: [momentId], onTargetDelete: delete)
  @@id(id)
}
''',
      'models/reply.model': '''model Reply {
  id UUID
  momentId UUID
  moment Moment @reference(via: [momentId], onTargetDelete: delete)
  @@id(id)
}
''',
    });

    final photo = graph.model(const ModelSymbol('MomentPhoto'));
    expect(photo.relations.single.localFields.single.name, 'momentId');
    expect(photo.relations.single.deleteOnTarget, isTrue);
    expect(
      photo.fields
          .singleWhere((field) => field.symbol.name == 'key')
          .prerequisite,
      isNotNull,
    );

    final reply = graph.model(const ModelSymbol('Reply'));
    expect(reply.relations.single.deleteOnTarget, isTrue);
    expect(reply.fields.every((field) => field.prerequisite == null), isTrue);
  });

  test('a readiness key may be optional', () {
    final graph = compileModelSources({
      'models/space.model': '''prerequisite RemoteObject(key String)

model Space {
  id        UUID
  name      String
  avatarKey String? @requires(RemoteObject(key: self))
  @@id(id)
}
''',
    });

    final space = graph.model(const ModelSymbol('Space'));
    final gated = space.fields.singleWhere(
      (field) => field.symbol.name == 'avatarKey',
    );
    expect(gated.prerequisite, isNotNull);
    expect(
      gated.symbol,
      space.fields.singleWhere((field) => field.nullable).symbol,
    );
  });

  test('a readiness key may be a UUID', () {
    final graph = compileModelSources({
      'models/photo.model': '''prerequisite RemoteBlob(key UUID)

model MomentPhoto {
  id     UUID
  blobId UUID @requires(RemoteBlob(key: self))
  @@id(id)
}
''',
    });

    final photo = graph.model(const ModelSymbol('MomentPhoto'));
    final gated = photo.fields.singleWhere(
      (field) => field.symbol.name == 'blobId',
    );
    expect(gated.prerequisite!.prerequisite.name, 'RemoteBlob');
    expect(gated.valueType, const ScalarValueType(ScalarType.uuid));
  });

  test('resolves valid cross-file definitions', () {
    final graph = compileModelSources({
      'models/user.model': '''model User {
  id   UUID
  name String
  @@id(id)
}
''',
      'models/space.model': '''model Space {
  id      UUID
  ownerId UUID
  name    String
  owner User @reference(via: [ownerId])
  @@id(id)
  @@unique(ownerId, name)
}
''',
      'models/moment.model': '''model Moment {
  id      UUID
  spaceId UUID
  space Space @reference(via: [spaceId], onTargetDelete: delete)
  @@id(id)
}
''',
      'models/star.model': '''model Star {
  id       UUID
  userId   UUID
  momentId UUID
  user User @reference(via: [userId])
  moment Moment @reference(via: [momentId])
  @@id(id)
  @@unique(userId, momentId)
}
''',
    });

    expect(graph.models.map((model) => model.symbol.name), [
      'Moment',
      'Space',
      'Star',
      'User',
    ]);

    final user = graph.model(const ModelSymbol('User'));
    expect(user.identity.fields.single.name, 'id');
    expect(user.fields.map((field) => field.symbol.name), ['id', 'name']);
    expect(user.relations, isEmpty);

    final space = graph.model(const ModelSymbol('Space'));
    expect(space.identity.fields.single.name, 'id');
    expect(space.fields.map((field) => field.symbol.name), [
      'id',
      'ownerId',
      'name',
    ]);
    expect(space.relations.map((relation) => relation.symbol.name), ['owner']);
    expect(space.relations.single.target, const ModelSymbol('User'));
    expect(space.relations.single.localFields.single.name, 'ownerId');
    expect(space.relations.single.referencedFields.single.name, 'id');
    expect(space.relations.single.nullable, isFalse);
    expect(space.relations.single.deleteOnTarget, isFalse);
    expect(space.uniqueConstraints.single.fields.map((field) => field.name), [
      'ownerId',
      'name',
    ]);

    final moment = graph.model(const ModelSymbol('Moment'));
    expect(moment.identity.fields.single.name, 'id');
    expect(moment.fields.map((field) => field.symbol.name), ['id', 'spaceId']);
    expect(moment.relations.map((relation) => relation.symbol.name), ['space']);
    expect(moment.relations.single.localFields.single.name, 'spaceId');
    expect(moment.relations.single.referencedFields.single.name, 'id');
    expect(moment.relations.single.deleteOnTarget, isTrue);

    final star = graph.model(const ModelSymbol('Star'));
    expect(star.identity.fields.single.name, 'id');
    expect(star.fields.map((field) => field.symbol.name), [
      'id',
      'userId',
      'momentId',
    ]);
    expect(star.relations.map((relation) => relation.symbol.name), [
      'user',
      'moment',
    ]);
    expect(star.relations[0].target, const ModelSymbol('User'));
    expect(star.relations[0].localFields.single.name, 'userId');
    expect(star.relations[0].referencedFields.single.name, 'id');
    expect(star.relations[0].nullable, isFalse);
    expect(star.relations[0].deleteOnTarget, isFalse);
    expect(star.relations[1].target, const ModelSymbol('Moment'));
    expect(star.relations[1].localFields.single.name, 'momentId');
    expect(star.relations[1].referencedFields.single.name, 'id');
    expect(star.relations[1].nullable, isFalse);
    expect(star.relations[1].deleteOnTarget, isFalse);
    expect(star.uniqueConstraints.single.fields.map((field) => field.name), [
      'userId',
      'momentId',
    ]);
  });

  test('resolves optional relations and ordered unique constraints', () {
    final graph = compileModelSources({
      'models/parent.model': 'model Parent { id UUID @@id(id) }',
      'models/child.model': '''model Child {
  id UUID
  parentId UUID?
  code String
  scope String
  parent Parent? @reference(via: [parentId])
  @@id(id)
  @@unique(code)
  @@unique(scope, code)
}
''',
    });

    final child = graph.model(const ModelSymbol('Child'));
    final parent = child.relations.single;
    expect(parent.target, const ModelSymbol('Parent'));
    expect(parent.localFields.single.name, 'parentId');
    expect(parent.referencedFields.single.name, 'id');
    expect(parent.nullable, isTrue);
    expect(parent.deleteOnTarget, isFalse);
    expect(
      child.uniqueConstraints
          .map((constraint) => constraint.fields.map((field) => field.name))
          .toList(),
      [
        ['code'],
        ['scope', 'code'],
      ],
    );
  });

  for (final invalid in <({String name, String source, String message})>[
    (
      name: 'missing identity annotation',
      source: 'model Star { id UUID }',
      message: 'Model "Star" requires @@id(field, ...)',
    ),
    (
      name: 'duplicate identity annotation',
      source: 'model Star { id UUID @@id(id) @@id(id) }',
      message: 'duplicate @@id annotation',
    ),
    (
      name: 'duplicate identity component',
      source: 'model Star { id UUID @@id(id, id) }',
      message: 'duplicate field "id" in @@id',
    ),
    (
      name: 'missing id UUID field',
      source: 'model Star { other UUID @@id(id) }',
      message: 'unknown field "id" in @@id',
    ),
    (
      name: 'nullable id',
      source: 'model Star { id UUID? @@id(id) }',
      message: 'identity field "Star.id" cannot be nullable',
    ),
    (
      name: 'nullable composite identity component',
      source:
          'model Star { userId UUID momentId UUID? @@id(userId, momentId) }',
      message: 'identity field "Star.momentId" cannot be nullable',
    ),
    (
      name: 'relation identity',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId])
  @@id(parent)
}''',
      message: 'relation "Child.parent" cannot be used in @@id',
    ),
    (
      name: 'relation unique component',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId])
  @@id(id)
  @@unique(parent)
}''',
      message: 'relation "Child.parent" cannot be used in @@unique',
    ),
    (
      name: 'unknown unique field',
      source: 'model Star { id UUID @@id(id) @@unique(other) }',
      message: 'unknown field "other" in @@unique',
    ),
    (
      name: 'duplicate unique component',
      source: '''model Star {
  id UUID
  code String
  @@id(id)
  @@unique(code, code)
}''',
      message: 'duplicate field "code" in @@unique',
    ),
    (
      name: 'nullable unique component',
      source: '''model Star {
  id UUID
  code String?
  @@id(id)
  @@unique(code)
}''',
      message: 'unique field "Star.code" cannot be nullable',
    ),
    (
      name: 'unique duplicates primary identity',
      source: '''model Star {
  userId UUID
  momentId UUID
  @@id(userId, momentId)
  @@unique(momentId, userId)
}''',
      message: '@@unique duplicates the primary identity of Star',
    ),
    (
      name: 'duplicate unordered unique field set',
      source: '''model Star {
  id UUID
  userId UUID
  momentId UUID
  @@id(id)
  @@unique(userId, momentId)
  @@unique(momentId, userId)
}''',
      message: 'duplicate @@unique constraint on Star(userId, momentId)',
    ),
    (
      name: 'retired @relation on a value field',
      source: '''model Star {
  id UUID @relation(fields: [id], references: [id])
  @@id(id)
}''',
      message: '@relation is retired; use @reference(via: [...])',
    ),
    (
      name: 'retired @relation on a relation field',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @relation(fields: [parentId], references: [id])
  @@id(id)
}''',
      message: '@relation is retired; use @reference(via: [...])',
    ),
    (
      name: 'retired @parent on a value field',
      source: '''model Star {
  id UUID @parent
  @@id(id)
}''',
      message: '@parent is retired; use @reference(via: [...])',
    ),
    (
      name: 'retired @parent on a relation field',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @parent(delete: together)
  @@id(id)
}''',
      message: '@parent is retired; use @reference(via: [...])',
    ),
    (
      name: 'retired @readyToSend on a value field',
      source: '''model Item {
  id  UUID
  key String @readyToSend
  @@id(id)
}''',
      message: '@readyToSend is retired; use @requires',
    ),
    (
      name: 'retired @readyToSend on a relation field',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @readyToSend
  @@id(id)
}''',
      message: '@readyToSend is retired; use @requires',
    ),
    (
      name: '@reference on a value field',
      source: '''model Star {
  id UUID @reference(via: [id])
  @@id(id)
}''',
      message: 'value field "Star.id" cannot use @reference',
    ),
    (
      name: 'a reverse half nothing points back with',
      source: '''model Parent { id UUID @@id(id) }
model Child { id UUID parent Parent @@id(id) }''',
      message:
          'inverse "Child.parent" has no reference: "Parent" declares no '
          '@reference to "Child"',
    ),
    (
      name: '@reference without a via argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(onTargetDelete: delete)
  @@id(id)
}''',
      message: 'relation "Child.parent" requires @reference(via: [...])',
    ),
    (
      name: 'bare @reference',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference
  @@id(id)
}''',
      message: 'relation "Child.parent" requires @reference(via: [...])',
    ),
    (
      name: 'duplicate reference annotations',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId]) @reference(via: [parentId])
  @@id(id)
}''',
      message: 'relation "Child.parent" requires exactly one @reference',
    ),
    (
      name: 'unknown field annotation',
      source: '''model Parent { id UUID @@id(id) }
model Child { id UUID parent Parent @owner @@id(id) }''',
      message: 'unknown field annotation "@owner"',
    ),
    (
      name: 'retired onDelete argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], onDelete: Cascade)
  @@id(id)
}''',
      message: 'unknown @reference argument "onDelete"',
    ),
    (
      name: 'retired delete argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], delete: together)
  @@id(id)
}''',
      message:
          'relation "Child.parent" argument "delete" is retired; use '
          'onTargetDelete: delete',
    ),
    (
      name: 'references argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], references: [id])
  @@id(id)
}''',
      message: 'unknown @reference argument "references"',
    ),
    (
      name: 'unknown reference argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], through: [parentId])
  @@id(id)
}''',
      message: 'unknown @reference argument "through"',
    ),
    (
      name: 'duplicate via argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], via: [parentId])
  @@id(id)
}''',
      message: 'duplicate @reference argument "via"',
    ),
    (
      name: 'retired fields argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(fields: [parentId])
  @@id(id)
}''',
      message: 'relation "Child.parent" argument "fields" is retired; use via',
    ),
    (
      name: 'duplicate onTargetDelete argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(
    via: [parentId],
    onTargetDelete: delete,
    onTargetDelete: delete
  )
  @@id(id)
}''',
      message: 'duplicate @reference argument "onTargetDelete"',
    ),
    (
      name: 'via as a bare identifier',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: parentId)
  @@id(id)
}''',
      message: 'relation "Child.parent" via must be a list of field names',
    ),
    (
      name: 'empty via list',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [])
  @@id(id)
}''',
      message: 'expected identifier in field annotation argument list',
    ),
    (
      name: 'onTargetDelete value other than delete',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], onTargetDelete: Cascade)
  @@id(id)
}''',
      message: 'relation "Child.parent" onTargetDelete must be "delete"',
    ),
    (
      name: 'positional reference argument',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference([parentId])
  @@id(id)
}''',
      message: 'expected field annotation argument name',
    ),
  ]) {
    test('rejects ${invalid.name} with a source location', () {
      expect(
        () => compileModelSources({'models/invalid.model': invalid.source}),
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

  test('locates missing scalar id at the identity argument', () {
    _expectExactFailure(
      '''model Star {
  other UUID
  @@id(id)
}''',
      line: 3,
      column: 8,
      message: 'unknown field "id" in @@id',
    );
  });

  test('locates relation-valued id at the identity argument', () {
    _expectExactFailure(
      '''model Parent { id UUID @@id(id) }
model Child {
  parentId UUID
  id Parent @reference(via: [parentId])
  @@id(id)
}''',
      line: 5,
      column: 8,
      message: 'relation "Child.id" cannot be used in @@id',
    );
  });

  test('locates an unknown local field at the name that named it', () {
    _expectExactFailure(
      '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  otherId UUID
  parent Parent @reference(via: [parentId])
  @@id(id)
}''',
      line: 5,
      column: 34,
      message:
          'relation "Child.parent" requires a scalar field "parentId" '
          'for "Parent.id"',
    );
  });

  test('locates the offending member of a composite field list', () {
    _expectExactFailure(
      '''model Parent {
  tenantId UUID
  number Int
  @@id(tenantId, number)
}
model Child {
  id UUID
  tenantId UUID
  parent Parent @reference(via: [tenantId, number])
  @@id(id)
}''',
      line: 9,
      column: 44,
      message:
          'relation "Child.parent" requires a scalar field "number" '
          'for "Parent.number"',
    );
  });

  test('locates an arity mismatch at the field list', () {
    _expectExactFailure(
      '''model Parent {
  tenantId UUID
  number Int
  @@id(tenantId, number)
}
model Child {
  id UUID
  tenantId UUID
  number Int
  parent Parent @reference(via: [tenantId])
  @@id(id)
}''',
      line: 10,
      column: 33,
      message:
          'relation "Child.parent" lists 1 field(s) for the 2-field identity '
          'of "Parent"',
    );
  });

  test('locates relation unique use at the relation identifier', () {
    _expectExactFailure(
      '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId])
  @@id(id)
  @@unique(parent)
}''',
      line: 7,
      column: 12,
      message: 'relation "Child.parent" cannot be used in @@unique',
    );
  });

  for (final invalid in <({String name, String source, String message})>[
    (
      name: 'unknown composite local field',
      source: '''model Parent {
  tenantId UUID
  number Int
  @@id(tenantId, number)
}
model Child {
  id UUID
  number Int
  parent Parent @reference(via: [tenantId, number])
  @@id(id)
}''',
      message:
          'relation "Child.parent" requires a scalar field "tenantId" '
          'for "Parent.tenantId"',
    ),
    (
      name: 'unknown local field',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parent Parent @reference(via: [parentId])
  @@id(id)
}''',
      message:
          'relation "Child.parent" requires a scalar field "parentId" '
          'for "Parent.id"',
    ),
    (
      name: 'relation-valued local field',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  otherId UUID
  other Parent @reference(via: [otherId])
  parent Parent @reference(via: [other])
  @@id(id)
}''',
      message:
          'relation "Child.parent" requires a scalar field "other" '
          'for "Parent.id"',
    ),
    (
      name: 'enum-valued local field',
      source: '''enum State { open }
model Parent { id UUID @@id(id) }
model Child {
  id UUID
  state State
  parent Parent @reference(via: [state])
  @@id(id)
}''',
      message:
          'relation "Child.parent" requires a scalar field "state" '
          'for "Parent.id"',
    ),
    (
      name: 'repeated local field in one reference',
      source: '''model Parent {
  tenantId UUID
  number UUID
  @@id(tenantId, number)
}
model Child {
  id UUID
  tenantId UUID
  parent Parent @reference(via: [tenantId, tenantId])
  @@id(id)
}''',
      message: 'duplicate field "tenantId" in relation "Child.parent"',
    ),
    (
      name: 'too many local fields',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  otherId UUID
  parent Parent @reference(via: [parentId, otherId])
  @@id(id)
}''',
      message:
          'relation "Child.parent" lists 2 field(s) for the 1-field identity '
          'of "Parent"',
    ),
    (
      name: 'mistyped local field',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId String
  parent Parent @reference(via: [parentId])
  @@id(id)
}''',
      message:
          'relation "Child.parent" field "parentId" must match the type of "Parent.id"',
    ),
    (
      name: 'nullability mismatch on a required relation',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID?
  parent Parent @reference(via: [parentId])
  @@id(id)
}''',
      message:
          'relation "Child.parent" and field "parentId" must have matching nullability',
    ),
    (
      name: 'nullability mismatch on a nullable relation',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent? @reference(via: [parentId])
  @@id(id)
}''',
      message:
          'relation "Child.parent" and field "parentId" must have matching nullability',
    ),
    (
      name: 'mixed nullability across a composite reference',
      source: '''model Parent {
  tenantId UUID
  number UUID
  @@id(tenantId, number)
}
model Child {
  id UUID
  tenantId UUID?
  number UUID
  parent Parent? @reference(via: [tenantId, number])
  @@id(id)
}''',
      message:
          'relation "Child.parent" and field "number" must have matching nullability',
    ),
    (
      name: 'nullable onTargetDelete: delete relation',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID?
  parent Parent? @reference(via: [parentId], onTargetDelete: delete)
  @@id(id)
}''',
      message:
          'relation "Child.parent" cannot be nullable and '
          'onTargetDelete: delete',
    ),
    (
      name: 'more than one onTargetDelete: delete relation',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  motherId UUID
  fatherId UUID
  mother Parent @reference(via: [motherId], onTargetDelete: delete)
  father Parent @reference(via: [fatherId], onTargetDelete: delete)
  @@id(id)
}''',
      message:
          'Model "Child" may declare at most one onTargetDelete: delete '
          'relation',
    ),
    (
      // Retired with the anonymous write path (CAP-444): which writes share
      // fate is a mutation's name, never an option on a reference.
      name: 'send: together is retired',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parentId UUID
  parent Parent @reference(via: [parentId], onTargetDelete: delete, send: together)
  @@id(id)
}''',
      message:
          'relation "Child.parent" argument "send" is retired; declare a '
          'mutation naming the writes that share fate',
    ),
    (
      name: '@sendWhenReady is retired',
      source: '''model Item {
  id  UUID
  key String @sendWhenReady
  @@id(id)
}''',
      message: '@sendWhenReady is retired; use @requires',
    ),
    (
      name: 'unknown prerequisite',
      source: '''model Item {
  id  UUID
  key UUID @requires(RemoteBlob(key: self))
  @@id(id)
}''',
      message: 'unknown prerequisite "RemoteBlob"',
    ),
    (
      name: 'missing prerequisite argument',
      source: '''prerequisite RemoteBlob(key UUID, owner UUID)
model Item {
  id  UUID
  key UUID @requires(RemoteBlob(key: self))
  @@id(id)
}''',
      message: 'missing prerequisite argument "owner"',
    ),
    (
      name: 'duplicate prerequisite argument',
      source: '''prerequisite RemoteBlob(key UUID)
model Item {
  id  UUID
  key UUID @requires(RemoteBlob(key: self, key: self))
  @@id(id)
}''',
      message: 'duplicate prerequisite argument "key"',
    ),
    (
      name: 'unknown prerequisite argument',
      source: '''prerequisite RemoteBlob(key UUID)
model Item {
  id  UUID
  key UUID @requires(RemoteBlob(blob: self))
  @@id(id)
}''',
      message: 'unknown prerequisite argument "blob"',
    ),
    (
      name: 'prerequisite type mismatch',
      source: '''prerequisite RemoteBlob(key UUID)
model Item {
  id  UUID
  key String @requires(RemoteBlob(key: self))
  @@id(id)
}''',
      message:
          'prerequisite argument "key" expects uuid but "Item.key" is string',
    ),
    (
      name: 'prerequisite binding other than self',
      source: '''prerequisite RemoteBlob(key UUID)
model Item {
  id  UUID
  key UUID @requires(RemoteBlob(key: id))
  @@id(id)
}''',
      message: 'prerequisite arguments must bind self',
    ),
    (
      name: '@requires on a list',
      source: '''prerequisite RemoteBlob(key UUID)
model Item {
  id   UUID
  keys UUID[] @requires(RemoteBlob(key: self))
  @@id(id)
}''',
      message:
          '@requires requires a non-list scalar field, and "Item.keys" is not one',
    ),
    (
      name: 'duplicate @requires',
      source: '''prerequisite RemoteBlob(key UUID)
model Item {
  id  UUID
  key UUID @requires(RemoteBlob(key: self)) @requires(RemoteBlob(key: self))
  @@id(id)
}''',
      message: 'duplicate @requires',
    ),
    (
      name: 'duplicate prerequisite declaration',
      source: '''prerequisite RemoteBlob(key UUID)
prerequisite RemoteBlob(key UUID)
model Item { id UUID @@id(id) }''',
      message: 'duplicate prerequisite name "RemoteBlob"',
    ),
    (
      name: 'duplicate prerequisite parameter',
      source: '''prerequisite RemoteBlob(key UUID, key UUID)
model Item { id UUID @@id(id) }''',
      message: 'duplicate prerequisite parameter "RemoteBlob.key"',
    ),
    (
      name: 'non-scalar prerequisite parameter',
      source: '''prerequisite RemoteBlob(key Item)
model Item { id UUID @@id(id) }''',
      message: 'prerequisite parameter "RemoteBlob.key" requires a scalar type',
    ),
    (
      name: 'duplicate scalar and relation member name',
      source: '''model Parent { id UUID @@id(id) }
model Child {
  id UUID
  parent UUID
  parent Parent @reference(via: [parentId])
  @@id(id)
}''',
      message: 'duplicate member "Child.parent"',
    ),
    (
      name: 'an ambiguous unnamed reverse half',
      source: '''model Moment {
  id    UUID
  links MomentLink[]
  @@id(id)
}
model MomentLink {
  id       UUID
  sourceId UUID
  targetId UUID
  source Moment @reference(via: [sourceId])
  target Moment @reference(via: [targetId])
  @@id(id)
}''',
      message:
          'inverse "Moment.links" matches 2 references from "MomentLink" '
          '(source, target); give each direction the same quoted relation name',
    ),
    (
      name: 'an unnamed reverse half where every reference is named',
      source: '''model Moment {
  id    UUID
  links MomentLink[]
  @@id(id)
}
model MomentLink {
  id       UUID
  sourceId UUID
  source Moment @reference("Source", via: [sourceId])
  @@id(id)
}''',
      message:
          'inverse "Moment.links" has no unnamed reference to pair with; '
          '"MomentLink" names "Source", so the inverse must name one too',
    ),
    (
      name: 'a named reference nothing answers',
      source: '''model Moment {
  id UUID
  @@id(id)
}
model MomentLink {
  id       UUID
  sourceId UUID
  source Moment @reference("Source", via: [sourceId])
  @@id(id)
}''',
      message:
          'reference "MomentLink.source" names relation "Source", and "Moment" '
          'declares no matching @inverse("Source")',
    ),
    (
      name: 'a named reverse half nothing answers',
      source: '''model Moment {
  id    UUID
  links MomentLink[] @inverse("Target")
  @@id(id)
}
model MomentLink {
  id       UUID
  sourceId UUID
  source Moment @reference("Source", via: [sourceId])
  @@id(id)
}''',
      message:
          'inverse "Moment.links" names relation "Target", and "MomentLink" '
          'declares no @reference("Target") to "Moment"',
    ),
    (
      name: 'a name pointing at the wrong endpoint Model',
      source: '''model Moment {
  id    UUID
  links MomentLink[] @inverse("Source")
  @@id(id)
}
model Space {
  id UUID
  @@id(id)
}
model MomentLink {
  id      UUID
  spaceId UUID
  source Space @reference("Source", via: [spaceId])
  @@id(id)
}''',
      message:
          'inverse "Moment.links" names relation "Source", and "MomentLink" '
          'declares no @reference("Source") to "Moment"',
    ),
    (
      name: 'one relation name on two references',
      source: '''model Moment {
  id    UUID
  links MomentLink[] @inverse("Source")
  @@id(id)
}
model MomentLink {
  id       UUID
  sourceId UUID
  targetId UUID
  source Moment @reference("Source", via: [sourceId])
  target Moment @reference("Source", via: [targetId])
  @@id(id)
}''',
      message:
          'relation "Source" is declared twice on "MomentLink", by "source" '
          'and "target"',
    ),
    (
      name: 'one relation name on two reverse halves',
      source: '''model Moment {
  id       UUID
  links    MomentLink[] @inverse("Source")
  mirrored MomentLink[] @inverse("Source")
  @@id(id)
}
model MomentLink {
  id       UUID
  sourceId UUID
  source Moment @reference("Source", via: [sourceId])
  @@id(id)
}''',
      message:
          'Model "Moment" declares relation "Source" twice, on "links" and '
          '"mirrored"',
    ),
    (
      name: 'two reverse halves competing for one reference',
      source: '''model Moment {
  id       UUID
  photos   MomentPhoto[]
  pictures MomentPhoto[]
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(id)
}''',
      message:
          'reference "MomentPhoto.moment" already has the inverse '
          '"Moment.photos"',
    ),
    (
      name: 'a to-one reverse half of a key that is not unique',
      source: '''model Moment {
  id    UUID
  photo MomentPhoto?
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(id)
}''',
      message:
          'inverse "Moment.photo" is to-one, and "MomentPhoto.moment" does not '
          'store its key in a unique field set of "MomentPhoto" — declare it '
          'as "MomentPhoto[]"',
    ),
    (
      name: '@inverse without a name',
      source: '''model Moment {
  id     UUID
  photos MomentPhoto[] @inverse
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(id)
}''',
      message:
          '@inverse on "Moment.photos" takes exactly one quoted relation name',
    ),
    (
      name: '@inverse with an unquoted name',
      source: '''model Moment {
  id     UUID
  photos MomentPhoto[] @inverse(name: Source)
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(id)
}''',
      message:
          '@inverse on "Moment.photos" takes exactly one quoted relation name',
    ),
    (
      name: '@inverse with an empty name',
      source: '''model Moment {
  id     UUID
  photos MomentPhoto[] @inverse("")
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(id)
}''',
      message: '@inverse on "Moment.photos" requires a non-empty relation name',
    ),
    (
      name: 'duplicate @inverse',
      source: '''model Moment {
  id     UUID
  photos MomentPhoto[] @inverse("A") @inverse("B")
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(id)
}''',
      message: 'duplicate @inverse',
    ),
    (
      name: '@inverse on the side that stores the key',
      source: '''model Moment {
  id UUID
  @@id(id)
}
model MomentPhoto {
  id       UUID
  momentId UUID
  moment Moment @reference(via: [momentId]) @inverse("Source")
  @@id(id)
}''',
      message: 'unknown field annotation "@inverse"',
    ),
    (
      name: '@inverse on a scalar field',
      source: '''model Moment {
  id   UUID
  name String @inverse("Source")
  @@id(id)
}''',
      message: 'unknown field annotation "@inverse"',
    ),
    (
      name: 'unknown member type',
      source: 'model Star { id UUID owner Usre @@id(id) }',
      message: 'unknown field type "Usre"',
    ),
    (
      name: 'unknown Model annotation',
      source: 'model Star { id UUID @@id(id) @@owner(1) }',
      message: 'unknown Model annotation "@@owner"',
    ),
    // A Model describes a row shape and says nothing about replication
    // (CAP-488). Both retired markers are refused rather than ignored: an
    // annotation the compiler accepts and drops is how the last one came to
    // mean nothing everywhere at once.
    (
      name: 'the retired local marker',
      source: 'model Draft { id UUID @@id(id) @@local }',
      message: 'unknown Model annotation "@@local"',
    ),
    (
      name: 'the retired sync marker',
      source: 'model Star { id UUID @@id(id) @@sync }',
      message: 'unknown Model annotation "@@sync"',
    ),
  ]) {
    test('rejects ${invalid.name} with a source location', () {
      expect(
        () => compileModelSources({'models/invalid.model': invalid.source}),
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

  test('rejects duplicate Model names across source files', () {
    expect(
      () => compileModelSources({
        'models/a.model': 'model User { id UUID @@id(id) }',
        'models/b.model': 'model User { id UUID @@id(id) }',
      }),
      throwsA(
        isA<DefinitionException>()
            .having((error) => error.location.path, 'path', 'models/b.model')
            .having((error) => error.location.line, 'line', 1)
            .having(
              (error) => error.message,
              'message',
              'duplicate Model name "User"',
            ),
      ),
    );
  });

  test(
    'locates an onTargetDelete: delete cycle on the edge that closes it',
    () {
      expect(
        () => compileModelSources({
          'models/a.model': '''model A {
  id UUID
  bId UUID
  b B @reference(via: [bId], onTargetDelete: delete)
  @@id(id)
}''',
          'models/b.model': '''model B {
  id UUID
  aId UUID
  a A @reference(via: [aId], onTargetDelete: delete)
  @@id(id)
}''',
        }),
        throwsA(
          isA<DefinitionException>()
              .having((error) => error.location.path, 'path', 'models/b.model')
              .having((error) => error.location.line, 'line', 4)
              .having((error) => error.location.column, 'column', 46)
              .having(
                (error) => error.message,
                'message',
                'onTargetDelete: delete cycle: A -> B -> A',
              ),
        ),
      );
    },
  );

  test('reports only the onTargetDelete: delete cycle, not the plain one', () {
    expect(
      () => compileModelSources({
        'models/a.model': '''model A {
  id UUID
  bId UUID
  b B @reference(via: [bId])
  @@id(id)
}''',
        'models/b.model': '''model B {
  id UUID
  cId UUID
  c C @reference(via: [cId], onTargetDelete: delete)
  @@id(id)
}''',
        'models/c.model': '''model C {
  id UUID
  bId UUID
  b B @reference(via: [bId], onTargetDelete: delete)
  @@id(id)
}''',
      }),
      throwsA(
        isA<DefinitionException>()
            .having((error) => error.location.path, 'path', 'models/c.model')
            .having(
              (error) => error.message,
              'message',
              'onTargetDelete: delete cycle: B -> C -> B',
            ),
      ),
    );
  });
}

void _expectExactFailure(
  String source, {
  required int line,
  required int column,
  required String message,
}) {
  expect(
    () => compileModelSources({'models/invalid.model': source}),
    throwsA(
      isA<DefinitionException>()
          .having(
            (error) => error.location.path,
            'path',
            'models/invalid.model',
          )
          .having((error) => error.location.line, 'line', line)
          .having((error) => error.location.column, 'column', column)
          .having((error) => error.message, 'message', message),
    ),
  );
}
