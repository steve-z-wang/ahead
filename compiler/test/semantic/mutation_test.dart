import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

/// The Models every mutation case below is declared against. None of them
/// says anything about replication: a Model describes a row shape, and every
/// declared mutation is a wire act (CAP-488).
const _models = '''model Space {
  id UUID
  name String
  @@id(id)
}

model Moment {
  id UUID
  spaceId UUID
  caption String?

  space Space @reference(via: [spaceId])

  @@id(id)
}

model Draft {
  id UUID
  text String
  @@id(id)
}

model Reply {
  id UUID
  momentId UUID

  moment Moment @reference(via: [momentId])

  @@id(id)
}
''';

ModelGraph _compile(String mutations) => compileModelSources({
  'models/base.model': _models,
  'models/act.model': mutations,
});

Matcher _rejects(String message) => throwsA(
  isA<DefinitionException>().having(
    (error) => error.message,
    'message',
    message,
  ),
);

void main() {
  test('a mutation carries its slots in declaration order', () {
    final graph = _compile('''mutation CreateMoment {
  space  Space.update<name>
  moment Moment.create
  extras Moment.create[]
  cover  Moment.update<caption>?
}
''');

    final mutation = graph.mutation(const MutationSymbol('CreateMoment'));
    expect(mutation.symbol.name, 'CreateMoment');
    expect(mutation.slots.map((slot) => slot.name), [
      'space',
      'moment',
      'extras',
      'cover',
    ]);
    expect(mutation.slots.map((slot) => slot.model.name), [
      'Space',
      'Moment',
      'Moment',
      'Moment',
    ]);
    expect(mutation.slots.map((slot) => slot.operation), [
      MutationOperationKind.update,
      MutationOperationKind.create,
      MutationOperationKind.create,
      MutationOperationKind.update,
    ]);
    expect(mutation.slots.map((slot) => slot.cardinality), [
      MutationSlotCardinality.single,
      MutationSlotCardinality.single,
      MutationSlotCardinality.list,
      MutationSlotCardinality.optional,
    ]);
    expect(
      mutation.slots.map(
        (slot) => slot.allowedPatchFields.map((field) => field.name).toList(),
      ),
      [
        ['name'],
        <String>[],
        <String>[],
        ['caption'],
      ],
    );
  });

  for (final invalid in <({String name, String slot, String message})>[
    (
      name: 'identity field',
      slot: 'moment Moment.update<id>',
      message:
          'slot "UpdateMoment.moment" patch projection cannot include identity field "id"',
    ),
    (
      name: 'relation',
      slot: 'moment Moment.update<space>',
      message:
          'slot "UpdateMoment.moment" patch projection names relation "space"; use its stored fields instead',
    ),
    (
      name: 'unknown field',
      slot: 'moment Moment.update<missing>',
      message:
          'slot "UpdateMoment.moment" patch projection names unknown field "missing" on Model "Moment"',
    ),
    (
      name: 'duplicate field',
      slot: 'moment Moment.update<caption, caption>',
      message:
          'slot "UpdateMoment.moment" patch projection names field "caption" twice',
    ),
    (
      name: 'reserved models slot',
      slot: 'models Moment.update<caption>',
      message:
          'update slot "UpdateMoment.models" uses reserved scope member name "models"',
    ),
    (
      name: 'reserved scopes slot',
      slot: 'scopes Moment.update<caption>',
      message:
          'update slot "UpdateMoment.scopes" uses reserved scope member name "scopes"',
    ),
  ]) {
    test('rejects an update projection with ${invalid.name}', () {
      expect(
        () => _compile('''mutation UpdateMoment {
  ${invalid.slot}
}
'''),
        _rejects(invalid.message),
      );
    });
  }

  test('every declared mutation reaches the graph, sorted by name', () {
    final graph = _compile('''mutation StarMoment {
  moment Moment.update<caption>
}

mutation DeleteMoment {
  moment Moment.delete
}
''');

    expect(graph.mutations.map((mutation) => mutation.symbol.name), [
      'DeleteMoment',
      'StarMoment',
    ]);
  });

  test('every declared mutation is a wire act, whichever Model it names', () {
    final graph = _compile('''mutation SaveDraft {
  draft Draft.create
}
''');

    final mutation = graph.mutation(const MutationSymbol('SaveDraft'));
    expect(mutation.slots.single.model.name, 'Draft');
  });

  test('rejects a slot naming an unknown Model', () {
    expect(
      () => _compile('''mutation CreateThing {
  thing Thing.create
}
'''),
      _rejects('slot "CreateThing.thing" names unknown Model "Thing"'),
    );
  });

  test('rejects a slot naming an unknown operation', () {
    expect(
      () => _compile('''mutation TouchMoment {
  moment Moment.touch
}
'''),
      _rejects(
        'slot "TouchMoment.moment" names unknown operation "touch"; '
        'expected create, update, or delete',
      ),
    );
  });

  test('rejects duplicate slot names', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  moment Moment.update<caption>
}
'''),
      _rejects('duplicate slot "CreateMoment.moment"'),
    );
  });

  test('rejects duplicate mutation names', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
}

mutation CreateMoment {
  moment Moment.update<caption>
}
'''),
      _rejects('duplicate mutation name "CreateMoment"'),
    );
  });

  test('rejects a mutation name a Model already holds', () {
    expect(
      () => _compile('''mutation Moment {
  moment Moment.create
}
'''),
      _rejects('mutation "Moment" duplicates a type name'),
    );
  });

  test('rejects an empty mutation', () {
    expect(
      () => _compile('''mutation DoNothing {
  @@version(1)
}
'''),
      _rejects('mutation "DoNothing" requires a slot'),
    );
  });

  test('a mutation may name several Models, and every slot is wire', () {
    // Device-only work is not declared here at all: it is a direct write
    // inside the act's own callback (CAP-488).
    final graph = _compile('''mutation WriteBoth {
  moment Moment.create
  draft  Draft.create
}
''');

    final mutation = graph.mutation(const MutationSymbol('WriteBoth'));
    expect(mutation.slots.map((slot) => slot.name), ['moment', 'draft']);
  });

  test('a mutation sequence resolves target and current paths', () {
    final graph = _compile('''mutation CreateMoment {
  moment Moment.create
  related Moment.update<caption>?
  extras Moment.delete[]

  @@sequence(after: [
    SetSpaceVisibility(space: moment.space),
    SetSpaceVisibility(space: related.space),
    SetSpaceVisibility(space: extras.space)
  ])
}

mutation CreateReply {
  reply Reply.create

  @@sequence(after: [
    SetSpaceVisibility(space: reply.moment.space)
  ])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
''');

    final dynamic moment = graph.mutation(const MutationSymbol('CreateMoment'));
    expect(moment.sequenceSelectors, hasLength(3));
    expect(
      moment.sequenceSelectors.map(
        (dynamic selector) => selector.predecessorMutation.name,
      ),
      ['SetSpaceVisibility', 'SetSpaceVisibility', 'SetSpaceVisibility'],
    );
    expect(
      moment.sequenceSelectors.map((dynamic selector) => selector.current.slot),
      ['moment', 'related', 'extras'],
    );

    final dynamic reply = graph.mutation(const MutationSymbol('CreateReply'));
    expect(
      reply.sequenceSelectors.single.current.relations.map(
        (dynamic relation) => '${relation.model.name}.${relation.name}',
      ),
      ['Reply.moment', 'Moment.space'],
    );
  });

  test('rejects a current sequence path naming an unknown slot', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [SetSpaceVisibility(space: missing.space)])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
'''),
      _rejects(
        'sequence path "missing.space" names unknown slot '
        '"CreateMoment.missing"',
      ),
    );
  });

  test('rejects a sequence path crossing a scalar member', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [SetSpaceVisibility(space: moment.caption)])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
'''),
      _rejects(
        'sequence path "moment.caption" crosses "Moment.caption", which is '
        'not a forward relation',
      ),
    );
  });

  test('rejects a sequence path crossing an inverse relation', () {
    expect(
      () => compileModelSources({
        'models/inverse.model': '''model Space {
  id UUID
  name String
  moments Moment[] @inverse("Space")
  @@id(id)
}

model Moment {
  id UUID
  spaceId UUID
  caption String?
  space Space @reference("Space", via: [spaceId])
  @@id(id)
}

mutation TouchSpace {
  space Space.update<name>
  @@sequence(after: [TouchMoment(moment: space.moments)])
}

mutation TouchMoment {
  moment Moment.update<caption>
}
''',
      }),
      _rejects(
        'sequence path "space.moments" crosses "Space.moments", which is '
        'not a forward relation',
      ),
    );
  });

  test('rejects an unknown predecessor Mutation', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [MissingMutation(space: moment.space)])
}
'''),
      _rejects(
        '@@sequence on mutation "CreateMoment" names unknown predecessor '
        'Mutation "MissingMutation"',
      ),
    );
  });

  test('rejects a selector naming an unknown predecessor slot', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [SetSpaceVisibility(missing: moment.space)])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
'''),
      _rejects(
        'sequence path "missing" names unknown slot '
        '"SetSpaceVisibility.missing"',
      ),
    );
  });

  test('rejects a selector whose endpoints identify different Models', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [TouchMoment(moment: moment.space)])
}

mutation TouchMoment {
  moment Moment.update<caption>
}
'''),
      _rejects(
        '@@sequence on mutation "CreateMoment" compares Moment with Space',
      ),
    );
  });

  test('rejects a predecessor path unavailable from queued identity', () {
    expect(
      () => _compile('''mutation CreateReply {
  reply Reply.create
  @@sequence(after: [MoveMoment(moment.space: reply.moment.space)])
}

mutation MoveMoment {
  moment Moment.update<caption>
}
'''),
      _rejects(
        'predecessor path in @@sequence on mutation "CreateReply" cannot be '
        'recovered from queued MoveMoment.moment identity values',
      ),
    );
  });

  test('rejects duplicate mutation sequence selectors', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [
    SetSpaceVisibility(space: moment.space),
    SetSpaceVisibility(space: moment.space)
  ])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
'''),
      _rejects(
        'duplicate sequence selector '
        '"SetSpaceVisibility(space:moment.space)" in mutation '
        '"CreateMoment"',
      ),
    );
  });

  test('rejects a sequence annotation without after', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(paths: [moment.space])
}
'''),
      _rejects('@@sequence on mutation "CreateMoment" requires after'),
    );
  });

  test('rejects extra sequence annotation arguments', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(
    after: [SetSpaceVisibility(space: moment.space)],
    version: 1
  )
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
'''),
      _rejects(
        '@@sequence on mutation "CreateMoment" takes exactly one argument: '
        'after',
      ),
    );
  });

  test('rejects duplicate sequence annotations', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [SetSpaceVisibility(space: moment.space)])
  @@sequence(after: [SetSpaceVisibility(space: moment.space)])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
'''),
      _rejects('duplicate @@sequence on mutation "CreateMoment"'),
    );
  });

  test('rejects an empty sequence path list', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [])
}
'''),
      _rejects('expected identifier path in annotation list'),
    );
  });

  test('rejects a malformed dotted selector path', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: [SetSpaceVisibility(space: moment.)])
}
'''),
      _rejects('expected identifier after "." in annotation path'),
    );
  });

  test('rejects a non-list sequence value', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  @@sequence(after: 1)
}
'''),
      _rejects(
        '@@sequence after on mutation "CreateMoment" must be a selector list',
      ),
    );
  });

  for (final annotation in ['@@shape']) {
    test('rejects the mutation annotation $annotation', () {
      expect(
        () => _compile('''mutation CreateMoment {
  moment Moment.create

  $annotation
}
'''),
        _rejects(
          'unknown mutation annotation '
          '"@@${annotation.substring(2).split('(').first}"',
        ),
      );
    });
  }
}
