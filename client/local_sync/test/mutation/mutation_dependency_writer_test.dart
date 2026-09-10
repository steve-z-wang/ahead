import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

void main() {
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;

  final firstSpace = FamilySpaceId(familyUuid(1));
  final secondSpace = FamilySpaceId(familyUuid(2));
  final moment = FamilyMomentId(familyUuid(10));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
  });

  tearDown(() => fixture.close());

  Future<List<(int, int)>> edges(String table, String predecessor) async {
    final rows = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            'SELECT mutation_ordinal, $predecessor FROM $table '
            'ORDER BY mutation_ordinal, $predecessor',
      ),
    );
    return [
      for (final row in rows.rows)
        (row['mutation_ordinal']! as int, row[predecessor]! as int),
    ];
  }

  Future<List<(int, int)>> sequences() =>
      edges('pending_mutation_sequences', 'predecessor_ordinal');

  Future<List<(int, int)>> prerequisites() =>
      edges('pending_mutation_prerequisites', 'prerequisite_ordinal');

  MutationRecord record(
    String name,
    List<(String, ModelOperation)> slots, {
    List<MutationSequenceSelector> selectors = const [],
  }) => MutationRecord(
    name: name,
    slotOperations: [
      for (final slot in slots)
        MutationSlotOperation(
          slotName: slot.$1,
          operation: slot.$2,
          allowedPatchFields: slot.$2 is ModelUpdateOperation
              ? (slot.$2 as ModelUpdateOperation).patch.keys
              : null,
        ),
    ],
    sequenceSelectors: selectors,
  );

  ModelCreateOperation createSpace(FamilySpaceId id) => ModelCreateOperation(
    model: 'FamilySpace',
    id: id,
    values: {'name': 'space'},
  );

  ModelUpdateOperation updateSpace(FamilySpaceId id, String name) =>
      ModelUpdateOperation(model: 'FamilySpace', id: id, patch: {'name': name});

  ModelCreateOperation createMoment(FamilySpaceId space) =>
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: moment,
        values: {'spaceId': space.value, 'caption': 'page'},
      );

  MutationSequenceSelector afterVisibility(ModelOperation operation) =>
      MutationSequenceSelector(
        predecessorMutation: 'SetSpaceVisibility',
        predecessorSlot: 'space',
        predecessorRelations: const [],
        currentPaths: [
          MutationSequenceCurrentPath(
            source: operation,
            relations: const ['space'],
          ),
        ],
      );

  test('returned slots retain names and companions retain null', () async {
    await family.space.create(firstSpace, {'name': 'space'});
    final operation = createMoment(firstSpace);

    await runtimes.apply(
      record('CreateMoment', [('moment', operation)]),
      companions: (models) => models.tag.create(FamilyTagId(familyUuid(30)), {
        'momentId': moment.value,
      }),
    );

    final rows = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            'SELECT position, slot_name, is_uplink '
            'FROM pending_mutation_operations ORDER BY position',
      ),
    );
    expect(
      rows.rows.map(
        (row) => (row['position'], row['slot_name'], row['is_uplink']),
      ),
      [(0, null, 0), (1, 'moment', 1)],
    );
  });

  test('same-row work freezes one deduplicated sequence edge', () async {
    await family.space.create(firstSpace, {'name': 'space'});
    await runtimes.apply(
      record('RenameSpace', [('space', updateSpace(firstSpace, 'one'))]),
    );
    await runtimes.apply(
      record('RenameSpace', [('space', updateSpace(firstSpace, 'two'))]),
    );

    expect(await sequences(), [(2, 1)]);
  });

  test(
    'a direct reference to an earlier active create is a prerequisite',
    () async {
      await runtimes.apply(
        record('CreateSpace', [('space', createSpace(firstSpace))]),
      );
      await runtimes.apply(
        record('CreateMoment', [('moment', createMoment(firstSpace))]),
      );

      expect(await prerequisites(), [(2, 1)]);
    },
  );

  test('an update uses its after-state lifecycle reference', () async {
    await family.space.create(firstSpace, {'name': 'first'});
    await family.moment.create(moment, {
      'spaceId': firstSpace.value,
      'caption': 'page',
    });
    await runtimes.apply(
      record('CreateSpace', [('space', createSpace(secondSpace))]),
    );
    final move = ModelUpdateOperation(
      model: 'FamilyMoment',
      id: moment,
      patch: {'spaceId': secondSpace.value},
    );
    await runtimes.apply(record('MoveMoment', [('moment', move)]));

    expect(await prerequisites(), [(2, 1)]);
  });

  test('a delete never creates a lifecycle prerequisite', () async {
    await runtimes.apply(
      record('CreateSpace', [('space', createSpace(firstSpace))]),
    );
    await family.moment.create(moment, {
      'spaceId': firstSpace.value,
      'caption': 'page',
    });
    final remove = ModelDeleteOperation(model: 'FamilyMoment', id: moment);
    await runtimes.apply(record('DeleteMoment', [('moment', remove)]));

    expect(await prerequisites(), isEmpty);
  });

  test('missing local data without a queued create does not block', () async {
    await runtimes.apply(
      record('CreateMoment', [('moment', createMoment(firstSpace))]),
    );

    expect(await prerequisites(), isEmpty);
  });

  test('an accepted create no longer creates a prerequisite', () async {
    await runtimes.apply(
      record('CreateSpace', [('space', createSpace(firstSpace))]),
    );
    await fixture.scope.current.execute(
      DatabaseStatement(
        sql:
            'INSERT INTO uplink_batches '
            '(sequence, required_scope, required_sync_id, '
            'legacy_required_sync_id) VALUES (1, ?, 1, NULL)',
        variables: ['User:${familyUuid(99).uuid}'],
      ),
    );
    await fixture.scope.current.execute(
      DatabaseStatement(
        sql:
            'UPDATE pending_mutations SET batch_sequence = 1 WHERE ordinal = 1',
      ),
    );
    await runtimes.apply(
      record('CreateMoment', [('moment', createMoment(firstSpace))]),
    );

    expect(await prerequisites(), isEmpty);
  });

  test('a parent and child created in one act need no edge', () async {
    final space = createSpace(firstSpace);
    final page = createMoment(firstSpace);
    await runtimes.apply(
      record('CreateSpaceWithMoment', [('space', space), ('moment', page)]),
    );

    expect(await prerequisites(), isEmpty);
  });

  test(
    'business sequence matches predecessor name slot and identity',
    () async {
      await family.space.create(firstSpace, {'name': 'space'});
      await runtimes.apply(
        record('SetSpaceVisibility', [
          ('space', updateSpace(firstSpace, 'private')),
        ]),
      );
      final page = createMoment(firstSpace);
      await runtimes.apply(
        record(
          'CreateMoment',
          [('moment', page)],
          selectors: [afterVisibility(page)],
        ),
      );

      expect(await sequences(), [(2, 1)]);
    },
  );

  test(
    'business sequence ignores a differently named predecessor slot',
    () async {
      await family.space.create(firstSpace, {'name': 'space'});
      await runtimes.apply(
        record('SetSpaceVisibility', [
          ('other', updateSpace(firstSpace, 'private')),
        ]),
      );
      final page = createMoment(firstSpace);
      await runtimes.apply(
        record(
          'CreateMoment',
          [('moment', page)],
          selectors: [afterVisibility(page)],
        ),
      );

      expect(await sequences(), isEmpty);
    },
  );

  test(
    'current update selectors use before and after identity union',
    () async {
      await family.space.create(firstSpace, {'name': 'first'});
      await family.space.create(secondSpace, {'name': 'second'});
      await family.moment.create(moment, {
        'spaceId': firstSpace.value,
        'caption': 'page',
      });
      await runtimes.apply(
        record('SetSpaceVisibility', [
          ('space', updateSpace(firstSpace, 'private')),
        ]),
      );
      await runtimes.apply(
        record('SetSpaceVisibility', [
          ('space', updateSpace(secondSpace, 'private')),
        ]),
      );
      final move = ModelUpdateOperation(
        model: 'FamilyMoment',
        id: moment,
        patch: {'spaceId': secondSpace.value},
      );
      await runtimes.apply(
        record(
          'MoveMoment',
          [('moment', move)],
          selectors: [afterVisibility(move)],
        ),
      );

      expect(await sequences(), [(3, 1), (3, 2)]);
    },
  );

  test('a create predecessor relation resolves from queued values', () async {
    await family.space.create(firstSpace, {'name': 'space'});
    await family.moment.create(moment, {
      'spaceId': firstSpace.value,
      'caption': 'page',
    });
    final tag = ModelCreateOperation(
      model: 'FamilyTag',
      id: FamilyTagId(familyUuid(30)),
      values: {'momentId': moment.value},
    );
    await runtimes.apply(record('AddTag', [('tag', tag)]));
    final revise = ModelUpdateOperation(
      model: 'FamilyMoment',
      id: moment,
      patch: {'caption': 'revised'},
    );
    final selector = MutationSequenceSelector(
      predecessorMutation: 'AddTag',
      predecessorSlot: 'tag',
      predecessorRelations: const ['moment'],
      currentPaths: [
        MutationSequenceCurrentPath(source: revise, relations: const []),
      ],
    );
    await runtimes.apply(
      record('ReviseMoment', [('moment', revise)], selectors: [selector]),
    );

    expect(await sequences(), [(2, 1)]);
  });

  test('list predecessor slots deduplicate one predecessor mutation', () async {
    await family.space.create(firstSpace, {'name': 'first'});
    await family.space.create(secondSpace, {'name': 'second'});
    await runtimes.apply(
      record('SetSpaceVisibility', [
        ('spaces', updateSpace(firstSpace, 'private')),
        ('spaces', updateSpace(secondSpace, 'private')),
      ]),
    );
    final page = createMoment(secondSpace);
    final selector = MutationSequenceSelector(
      predecessorMutation: 'SetSpaceVisibility',
      predecessorSlot: 'spaces',
      predecessorRelations: const [],
      currentPaths: [
        MutationSequenceCurrentPath(source: page, relations: const ['space']),
      ],
    );
    await runtimes.apply(
      record('CreateMoment', [('moment', page)], selectors: [selector]),
    );

    expect(await sequences(), [(2, 1)]);
  });

  test(
    'later work never becomes a retroactive blocker or branch join',
    () async {
      await family.space.create(firstSpace, {'name': 'space'});
      await runtimes.apply(
        record('SetSpaceVisibility', [
          ('space', updateSpace(firstSpace, 'a1')),
        ]),
      );
      final page = createMoment(firstSpace);
      await runtimes.apply(
        record(
          'CreateMoment',
          [('moment', page)],
          selectors: [afterVisibility(page)],
        ),
      );
      await runtimes.apply(
        record('SetSpaceVisibility', [
          ('space', updateSpace(firstSpace, 'a2')),
        ]),
      );

      expect(await sequences(), [(2, 1), (3, 1)]);
    },
  );

  test(
    'a failed callback rolls back queue operations and both edge sets',
    () async {
      await runtimes.apply(
        record('CreateSpace', [('space', createSpace(firstSpace))]),
      );
      final page = createMoment(firstSpace);
      await expectLater(
        runtimes.apply(
          record(
            'Broken',
            [('moment', page), ('duplicate', page)],
            selectors: [afterVisibility(page)],
          ),
        ),
        throwsA(isA<Object>()),
      );

      expect(await prerequisites(), isEmpty);
      expect(await sequences(), isEmpty);
      final parents = await fixture.scope.current.query(
        DatabaseQuery(sql: 'SELECT ordinal FROM pending_mutations'),
      );
      expect(parents.rows.map((row) => row['ordinal']), [1]);
    },
  );
}
