import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  test('projects every Model into a deterministic contract', () {
    final first = buildBackendContract(_graph(reordered: false));
    final reordered = buildBackendContract(_graph(reordered: true));

    expect(first, reordered);
    // Every Model, because the compiler no longer owns replication policy:
    // which of these the Backend actually publishes is decided by which
    // loaders it registers (CAP-488).
    expect(first.models.map((model) => model.name), [
      'LocalNote',
      'Space',
      'Star',
      'User',
    ]);
    expect(first.enums, [
      BackendEnumContract(name: 'LocalStatus', values: ['draft', 'done']),
      BackendEnumContract(name: 'SpaceKind', values: ['personal', 'group']),
    ]);

    final space = first.models[1];
    expect(space.identity.map((field) => field.name), ['id']);
    expect(space.fields.map((field) => field.name), [
      'id',
      'kind',
      'nickname',
      'ownerId',
      'tags',
    ]);
    expect(
      space.fields,
      containsAll([
        const BackendFieldContract(
          name: 'id',
          type: BackendScalarFieldType(ScalarType.uuid),
          nullable: false,
        ),
        const BackendFieldContract(
          name: 'kind',
          type: BackendEnumFieldType('SpaceKind'),
          nullable: false,
        ),
        const BackendFieldContract(
          name: 'nickname',
          type: BackendScalarFieldType(ScalarType.string),
          nullable: true,
        ),
        const BackendFieldContract(
          name: 'ownerId',
          type: BackendScalarFieldType(ScalarType.uuid),
          nullable: false,
        ),
        const BackendFieldContract(
          name: 'tags',
          type: BackendScalarListFieldType(ScalarType.string),
          nullable: false,
        ),
      ]),
    );
    expect(space.fields.map((field) => field.name), isNot(contains('owner')));

    final update = first.mutations.single.slots.single;
    expect(update.name, 'space');
    expect(update.allowedPatchFields, ['nickname', 'tags']);
    expect(() => update.allowedPatchFields!.clear(), throwsUnsupportedError);

    final star = first.models[2];
    expect(star.identity.map((field) => field.name), ['userId', 'spaceId']);
    expect(star.identity.every((field) => !field.nullable), isTrue);

    expect(() => first.models.clear(), throwsUnsupportedError);
    expect(() => space.fields.clear(), throwsUnsupportedError);
    expect(() => space.identity.clear(), throwsUnsupportedError);
    expect(() => first.enums.first.values.clear(), throwsUnsupportedError);
  });

  test('every declared slot reaches the Backend contract', () {
    // A declaration is always a wire act (CAP-488): device-only work is a
    // direct transaction operation or an off-wire callback companion, neither
    // of which is declared, so the contract has nothing to drop.
    final graph = compileModelSources({
      'models/mixed.model': '''
model Star {
  id UUID
  @@id(id)
}

model Draft {
  id UUID
  @@id(id)
}

mutation KeepAndClear {
  star  Star.create
  draft Draft.delete
}
''',
    });

    final contract = buildBackendContract(graph);
    final mutation = contract.mutations.single;
    expect(mutation.name, 'KeepAndClear');
    expect(mutation.slots.map((slot) => slot.name), ['star', 'draft']);
    expect(contract.models.map((model) => model.name), ['Draft', 'Star']);
  });

  test('rejects a manually constructed nullable identity', () {
    const model = ModelSymbol('Invalid');
    const id = FieldSymbol(model: model, name: 'id');
    final graph = ModelGraph([
      ModelDefinition(
        symbol: model,
        fields: const [
          ModelFieldDefinition(
            symbol: id,
            valueType: ScalarValueType(ScalarType.uuid),
            nullable: true,
          ),
        ],
        identity: ModelIdentity(const [id]),
        uniqueConstraints: const [],
        relations: const [],
      ),
    ]);

    expect(() => buildBackendContract(graph), throwsStateError);
  });
}

ModelGraph _graph({required bool reordered}) {
  final sources = <String, String>{
    'space.model':
        '''
enum SpaceKind {
  personal
  group
}

model Space {
  ${reordered ? 'tags String[]\n  owner User @reference(via: [ownerId], onTargetDelete: delete)\n  nickname String?\n  kind SpaceKind\n  ownerId UUID\n  id UUID' : 'id UUID\n  ownerId UUID\n  kind SpaceKind\n  nickname String?\n  owner User @reference(via: [ownerId], onTargetDelete: delete)\n  tags String[]'}
  @@id(id)
}

mutation UpdateSpace {
  space Space.update<nickname, tags>
}
''',
    'user.model': '''
model User {
  id UUID
  handle String
  @@id(id)
}
''',
    'star.model': '''
model Star {
  userId UUID
  spaceId UUID
  createdAt DateTime
  @@id(userId, spaceId)
}
''',
    'local.model': '''
enum LocalStatus {
  draft
  done
}

model LocalNote {
  id UUID
  status LocalStatus
  @@id(id)
}
''',
  };
  final entries = sources.entries.toList();
  if (reordered) {
    return compileModelSources({
      for (final entry in entries.reversed) entry.key: entry.value,
    });
  }
  return compileModelSources(sources);
}
