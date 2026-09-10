import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

/// Slot bindings (spec 2026-08-16-slot-bindings): the act-level wiring —
/// `photos MomentPhoto.create(moment: moment)[]` — resolved against the
/// Models' declared relations.
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

model MomentPhoto {
  id UUID
  momentId UUID
  position Int
  moment Moment @reference(via: [momentId], onTargetDelete: delete)
  @@id(id)
}

model Star {
  userId UUID
  momentId UUID
  moment Moment @reference(via: [momentId])
  @@id(userId, momentId)
}

model StarTag {
  id UUID
  starUserId UUID
  starMomentId UUID
  momentId UUID
  star Star @reference(via: [starUserId, starMomentId])
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
  test('a binding resolves to the relation, its fields, and the slot', () {
    final graph = _compile('''mutation CreateMoment {
  moment Moment.create
  photos MomentPhoto.create(moment: moment)[]
}
''');

    final mutation = graph.mutation(const MutationSymbol('CreateMoment'));
    expect(mutation.slots.first.bindings, isEmpty);
    final binding = mutation.slots.last.bindings.single;
    expect(binding.relation.name, 'moment');
    expect(binding.slot, 'moment');
    expect(binding.fields.map((field) => field.name), ['momentId']);
  });

  test('every operation kind may bind', () {
    final graph = _compile('''mutation UpdateMoment {
  moment  Moment.update<caption>
  removed MomentPhoto.delete(moment: moment)[]
  added   MomentPhoto.create(moment: moment)[]
}
''');

    final mutation = graph.mutation(const MutationSymbol('UpdateMoment'));
    expect(mutation.slots.map((slot) => slot.bindings.length).toList(), [
      0,
      1,
      1,
    ]);
  });

  test('rejects projecting a field used by a binding', () {
    expect(
      () => _compile('''mutation ReorderPhotos {
  moment Moment.update<caption>
  photos MomentPhoto.update<position, momentId>(moment: moment)[]
}
'''),
      _rejects(
        'slot "ReorderPhotos.photos" patch projection field "momentId" '
        'backs bound relation "moment"; stored-row bindings cannot also be '
        'patched',
      ),
    );
  });

  test('allows projecting an unbound relation backing field', () {
    final graph = _compile('''mutation MoveMoment {
  moment Moment.update<spaceId>
}
''');

    expect(
      graph
          .mutation(const MutationSymbol('MoveMoment'))
          .slots
          .single
          .allowedPatchFields
          .map((field) => field.name),
      ['spaceId'],
    );
  });

  test('a slot may bind several relations, each to a different slot', () {
    final graph = _compile('''mutation StarWithTag {
  moment Moment.create
  star   Star.create(moment: moment)
  tag    StarTag.create(star: star, moment: moment)
}
''');

    final tag = graph.mutation(const MutationSymbol('StarWithTag')).slots.last;
    expect(tag.bindings, hasLength(2));
    expect(tag.bindings.first.relation.name, 'star');
    expect(tag.bindings.first.slot, 'star');
    expect(tag.bindings.first.fields.map((field) => field.name), [
      'starUserId',
      'starMomentId',
    ]);
    expect(tag.bindings.last.relation.name, 'moment');
    expect(tag.bindings.last.slot, 'moment');
  });

  test('an unbound relation stays an ordinary field', () {
    // `space` on Moment goes unbound: binding is per-relation, not per-slot.
    final graph = _compile('''mutation CreateMoment {
  moment Moment.create
  photos MomentPhoto.create(moment: moment)[]
}
''');

    expect(
      graph.mutation(const MutationSymbol('CreateMoment')).slots.first.bindings,
      isEmpty,
    );
  });

  test('rejects a binding naming an unknown relation', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  photos MomentPhoto.create(album: moment)[]
}
'''),
      _rejects(
        'slot "CreateMoment.photos" binds unknown '
        'relation "album" — expected a relation field declared on Model '
        '"MomentPhoto"',
      ),
    );
  });

  test('rejects binding a nullable relation', () {
    expect(
      () => compileModelSources({
        'models/base.model': _models,
        'models/extra.model': '''model Caption {
  id UUID
  momentId UUID?
  moment Moment? @reference(via: [momentId])
  @@id(id)
}
''',
        'models/act.model': '''mutation CaptionMoment {
  moment  Moment.create
  caption Caption.create(moment: moment)
}
''',
      }),
      _rejects(
        'slot "CaptionMoment.caption" binds nullable relation "moment" — a '
        'binding asserts equality with the bound slot\'s identity, which '
        'null can never satisfy',
      ),
    );
  });

  test('rejects a binding naming an unknown slot', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  photos MomentPhoto.create(moment: page)[]
}
'''),
      _rejects(
        'slot "CreateMoment.photos" binds unknown '
        'slot "page"',
      ),
    );
  });

  test('rejects binding a slot declared later', () {
    expect(
      () => _compile('''mutation CreateMoment {
  photos MomentPhoto.create(moment: moment)[]
  moment Moment.create
}
'''),
      _rejects(
        'slot "CreateMoment.photos" binds slot '
        '"moment", which must be declared before it — declaration order is '
        'execution order',
      ),
    );
  });

  test('rejects binding a slot holding the wrong Model', () {
    expect(
      () => _compile('''mutation CreateMoment {
  space  Space.create
  photos MomentPhoto.create(moment: space)[]
}
'''),
      _rejects(
        'slot "CreateMoment.photos" binds relation '
        '"moment" (targeting Model "Moment") to slot "space", which holds '
        'Model "Space"',
      ),
    );
  });

  test('rejects binding a list slot', () {
    expect(
      () => _compile('''mutation CreateMoments {
  moments Moment.create[]
  photos  MomentPhoto.create(moment: moments)[]
}
'''),
      _rejects(
        'slot "CreateMoments.photos" binds slot '
        '"moments", which is not single-cardinality — binding to an optional '
        'or list slot is ambiguous',
      ),
    );
  });

  test('rejects binding the same relation twice', () {
    expect(
      () => _compile('''mutation CreateMoment {
  moment Moment.create
  other  Moment.create
  photos MomentPhoto.create(moment: moment, moment: other)[]
}
'''),
      _rejects(
        'slot "CreateMoment.photos" binds relation '
        '"moment" twice',
      ),
    );
  });
}
