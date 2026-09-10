import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// `mutate` is the one write boundary (CAP-439): one call is one SQLite
/// transaction applying every operation in slot order, one before-image set,
/// and one queued record — and any failure applies nothing at all.
void main() {
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(2));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    await family.space.create(spaceId, {'name': 'book'});
  });

  tearDown(() => fixture.close());

  /// The page-shaped act: one page and its photos, spelled as one word.
  MutationRecord capturePage({
    required int photos,
    String caption = 'a page',
    int firstPhoto = 10,
  }) => familyMutationRecord(
    name: 'CapturePage',
    operations: [
      _create('FamilyMoment', FamilyMomentId(familyUuid(2)), {
        'spaceId': spaceId.value,
        'caption': caption,
      }),
      for (var index = 0; index < photos; index += 1)
        _create('FamilyPhoto', FamilyPhotoId(familyUuid(firstPhoto + index)), {
          'momentId': momentId.value,
          'key': 'photo-${firstPhoto + index}',
        }),
    ],
  );

  Future<List<DatabaseRow>> queueRecords() async =>
      (await fixture.scope.current.query(
        DatabaseQuery(
          sql:
              'SELECT ordinal, name FROM pending_mutations '
              'ORDER BY ordinal',
        ),
      )).rows.toList();

  Future<List<DatabaseRow>> queuedOperations() async =>
      (await fixture.scope.current.query(
        DatabaseQuery(
          sql:
              'SELECT mutation_ordinal, position, model, operation, is_uplink '
              'FROM pending_mutation_operations '
              'ORDER BY mutation_ordinal, position',
        ),
      )).rows.toList();

  test('fresh queue storage is parent-owned and position-ordered', () async {
    final tagId = FamilyTagId(familyUuid(63));
    await runtimes.apply(
      capturePage(photos: 1),
      companions: (models) =>
          models.tag.create(tagId, {'momentId': momentId.value}),
    );

    final tables = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name LIKE 'pending_%' ORDER BY name",
      ),
    );
    expect(tables.rows.map((row) => row['name']), [
      'pending_mutation_operations',
      'pending_mutation_prerequisites',
      'pending_mutation_scopes',
      'pending_mutation_sequences',
      'pending_mutations',
    ]);

    final operationColumns = await fixture.scope.current.query(
      DatabaseQuery(sql: 'PRAGMA table_info(pending_mutation_operations)'),
    );
    expect(
      operationColumns.rows.map((row) => row['name']),
      contains('slot_name'),
    );

    final sequenceColumns = await fixture.scope.current.query(
      DatabaseQuery(sql: 'PRAGMA table_info(pending_mutation_sequences)'),
    );
    expect(sequenceColumns.rows.map((row) => row['name']), [
      'mutation_ordinal',
      'predecessor_ordinal',
    ]);

    final prerequisiteColumns = await fixture.scope.current.query(
      DatabaseQuery(sql: 'PRAGMA table_info(pending_mutation_prerequisites)'),
    );
    expect(prerequisiteColumns.rows.map((row) => row['name']), [
      'mutation_ordinal',
      'prerequisite_ordinal',
    ]);

    final edgeIndexes = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name IN ('pending_mutation_sequences_reverse', "
            "'pending_mutation_prerequisites_reverse') ORDER BY name",
      ),
    );
    expect(edgeIndexes.rows.map((row) => row['name']), [
      'pending_mutation_prerequisites_reverse',
      'pending_mutation_sequences_reverse',
    ]);

    final edgeDefinitions = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            "SELECT sql FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('pending_mutation_sequences', "
            "'pending_mutation_prerequisites') ORDER BY name",
      ),
    );
    expect(
      edgeDefinitions.rows.map((row) => row['sql']! as String),
      everyElement(contains('CHECK (')),
    );

    final operations = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            'SELECT mutation_ordinal, position, slot_name, model, is_uplink '
            'FROM pending_mutation_operations '
            'ORDER BY mutation_ordinal, position',
      ),
    );
    expect(
      operations.rows.map(
        (row) =>
            (row['position'], row['slot_name'], row['model'], row['is_uplink']),
      ),
      [
        (0, null, 'FamilyTag', 0),
        (1, 'wire0', 'FamilyMoment', 1),
        (2, 'wire1', 'FamilyPhoto', 1),
      ],
    );
    expect(
      operations.rows.map((row) => row['mutation_ordinal']).toSet(),
      hasLength(1),
    );
  });

  test('applies every operation in slot order, as one record', () async {
    await runtimes.apply(capturePage(photos: 41));

    // 42 operations — the page the batch limit used to split — and every row
    // readable at once.
    final operations = await queuedOperations();
    expect(operations, hasLength(42));
    expect(operations.first['model'], 'FamilyMoment');
    expect(operations.skip(1).map((row) => row['model']).toSet(), {
      'FamilyPhoto',
    });
    expect(await runtimes.moment.reader.get(momentId), isNotNull);
    expect(
      await runtimes.photo.reader.get(FamilyPhotoId(familyUuid(50))),
      isNotNull,
    );

    // One record, and every operation names it.
    final records = await queueRecords();
    expect(records, hasLength(1));
    expect(records.single['name'], 'CapturePage');
    expect(operations.map((row) => row['mutation_ordinal']).toSet(), {
      records.single['ordinal'],
    });
  });

  test('a failing operation applies nothing', () async {
    // The second create collides with the first on the primary key, so the
    // act cannot happen — and half of it must not either.
    final doomed = familyMutationRecord(
      name: 'CapturePage',
      operations: [
        _create('FamilyMoment', momentId, {
          'spaceId': spaceId.value,
          'caption': 'a page',
        }),
        _create('FamilyPhoto', FamilyPhotoId(familyUuid(10)), {
          'momentId': momentId.value,
          'key': 'photo',
        }),
        _create('FamilyPhoto', FamilyPhotoId(familyUuid(10)), {
          'momentId': momentId.value,
          'key': 'twin',
        }),
      ],
    );

    await expectLater(runtimes.apply(doomed), throwsA(isA<Object>()));

    expect(await runtimes.moment.reader.get(momentId), isNull);
    expect(
      await runtimes.photo.reader.get(FamilyPhotoId(familyUuid(10))),
      isNull,
    );
    expect(await queuedOperations(), isEmpty);
    expect(await queueRecords(), isEmpty);
  });

  test('an update patch may use any nonempty projected subset', () async {
    await family.moment.create(momentId, {
      'spaceId': spaceId.value,
      'caption': 'before',
    });
    final update = ModelUpdateOperation(
      model: 'FamilyMoment',
      id: momentId,
      patch: const {'caption': 'after'},
    );

    await runtimes.apply(
      MutationRecord(
        name: 'RevisePage',
        slotOperations: [
          MutationSlotOperation(
            slotName: 'moment',
            operation: update,
            allowedPatchFields: const ['caption', 'spaceId'],
          ),
        ],
      ),
    );

    expect(
      (await runtimes.moment.reader.get(momentId))!.fields['caption'],
      'after',
    );
    expect(await queueRecords(), hasLength(1));
  });

  test('an undeclared update key rolls back before apply and queue', () async {
    await family.moment.create(momentId, {
      'spaceId': spaceId.value,
      'caption': 'before',
    });
    final companionId = FamilyTagId(familyUuid(66));
    final update = ModelUpdateOperation(
      model: 'FamilyMoment',
      id: momentId,
      patch: {'spaceId': familyUuid(9)},
    );

    await expectLater(
      runtimes.apply(
        MutationRecord(
          name: 'RevisePage',
          slotOperations: [
            MutationSlotOperation(
              slotName: 'moment',
              operation: update,
              allowedPatchFields: const ['caption'],
            ),
          ],
        ),
        companions: (models) =>
            models.tag.create(companionId, {'momentId': momentId.value}),
      ),
      throwsArgumentError,
    );

    final row = await runtimes.moment.reader.get(momentId);
    expect(row!.fields['spaceId'], spaceId.value);
    expect(row.fields['caption'], 'before');
    expect(await runtimes.tag.reader.get(companionId), isNull);
    expect(await queueRecords(), isEmpty);
    expect(await queuedOperations(), isEmpty);
  });

  test('before-images cover every identity the act touched', () async {
    await runtimes.apply(capturePage(photos: 2));
    // Accept the creates, so the rows are server truth with nothing pending.
    await fixture.scope.current.execute(
      DatabaseStatement(sql: 'DELETE FROM pending_mutations'),
    );

    await runtimes.apply(
      familyMutationRecord(
        name: 'RevisePage',
        operations: [
          ModelUpdateOperation(
            model: 'FamilyMoment',
            id: momentId,
            patch: const {'caption': 'revised'},
          ),
          ModelDeleteOperation(
            model: 'FamilyPhoto',
            id: FamilyPhotoId(familyUuid(11)),
          ),
        ],
      ),
    );

    // Each edited row holds the truth it diverged from — one before-image per
    // touched identity, and none for the row the act left alone.
    expect(
      await runtimes.moment.before.exists(momentId),
      isTrue,
      reason: 'the updated page holds its prior caption',
    );
    expect(
      await runtimes.photo.before.exists(FamilyPhotoId(familyUuid(11))),
      isTrue,
      reason: 'the deleted photo holds the row it was',
    );
    expect(
      await runtimes.photo.before.exists(FamilyPhotoId(familyUuid(10))),
      isFalse,
      reason: 'an untouched row is not dirty',
    );
  });

  test('the callback decides against the row it is enqueued beside', () async {
    // What a caller reading BEFORE the act would be holding.
    final stale = await runtimes.space.reader.get(spaceId);
    expect(stale?.fields['name'], 'book');

    // Truth moves underneath it — a Downlink page landing, another act
    // settling, anything. A slot built from `stale` would now be a decision
    // about a row that no longer exists in that shape.
    await family.space.upsert(spaceId, {'name': 'renamed by the server'});

    Object? seen;
    await runtimes.transaction(
      (tx) => tx.mutate.run(
        name: 'RenameBook',
        build: (mutation) async {
          seen = (await mutation.models.space.get(spaceId))?.fields['name'];
          return (
            operations: <ModelOperation>[
              ModelUpdateOperation(
                model: 'FamilySpace',
                id: spaceId,
                patch: {'name': 'mine'},
              ),
            ],
          );
        },
        record: (result) => familyMutationRecord(
          name: 'RenameBook',
          operations: result.operations,
        ),
      ),
    );

    // The read inside the act sees the current row, never the stale one.
    expect(seen, 'renamed by the server');
  });

  test('a row deleted before the act enters is a clean no-op', () async {
    // The other half of the same rule: a caller that pre-read a row and then
    // lost it would enqueue an operation on nothing. Reading inside means the
    // act simply proves itself a no-op and returns null.
    final stale = await runtimes.space.reader.get(spaceId);
    expect(stale, isNotNull);

    await family.space.delete(spaceId);

    await runtimes.transaction(
      (tx) => tx.mutate.run<({List<ModelOperation> operations})>(
        name: 'RenameBook',
        build: (mutation) async {
          final book = await mutation.models.space.get(spaceId);
          if (book == null) return null;
          return (
            operations: <ModelOperation>[
              ModelUpdateOperation(
                model: 'FamilySpace',
                id: spaceId,
                patch: {'name': 'mine'},
              ),
            ],
          );
        },
        record: (result) => familyMutationRecord(
          name: 'RenameBook',
          operations: result.operations,
        ),
      ),
    );

    expect(await queueRecords(), isEmpty);
    expect(await queuedOperations(), isEmpty);
  });

  test('a direct transaction applies and never queues', () async {
    // Direct transaction work commits to this device only: no record or queue,
    // no wire (CAP-488).
    final tagId = FamilyTagId(familyUuid(60));
    await runtimes.write(
      (models) => models.tag.create(tagId, {'momentId': momentId.value}),
    );

    expect(await runtimes.tag.reader.get(tagId), isNotNull);
    expect(await queueRecords(), isEmpty);
    expect(await queuedOperations(), isEmpty);
  });

  test('a write rolls back whole when its callback throws', () async {
    final first = FamilyTagId(familyUuid(61));
    final second = FamilyTagId(familyUuid(62));
    await expectLater(
      runtimes.write((models) async {
        await models.tag.create(first, {'momentId': momentId.value});
        await models.tag.create(second, {'momentId': momentId.value});
        throw StateError('no');
      }),
      throwsStateError,
    );

    expect(await runtimes.tag.reader.get(first), isNull);
    expect(await runtimes.tag.reader.get(second), isNull);
  });

  test('a companion write stays off the wire and shares the act', () async {
    final tagId = FamilyTagId(familyUuid(63));
    await runtimes.apply(
      capturePage(photos: 1),
      companions: (models) =>
          models.tag.create(tagId, {'momentId': momentId.value}),
    );

    final operations = await queuedOperations();
    // One record, and every operation of the act beneath it — the companion
    // included, because it shares the act's fate.
    expect(await queueRecords(), hasLength(1));
    expect(
      operations.map((row) => (row['model'], row['is_uplink'])),
      containsAll(<(String, int)>[
        ('FamilyMoment', 1),
        ('FamilyPhoto', 1),
        ('FamilyTag', 0),
      ]),
    );
    expect(
      operations.map((row) => row['mutation_ordinal']).toSet(),
      hasLength(1),
    );
  });

  test('a callback returning null is an atomic no-op', () async {
    final tagId = FamilyTagId(familyUuid(64));
    await runtimes.mutateNothing(
      'CaptionWithNote',
      companions: (models) =>
          models.tag.create(tagId, {'momentId': momentId.value}),
    );

    // The record was written before the callback ran and rolled back with it,
    // and so did the companion. Nothing throws: saying nothing happened is
    // what returning null is for.
    expect(await runtimes.tag.reader.get(tagId), isNull);
    expect(await queueRecords(), isEmpty);
    expect(await queuedOperations(), isEmpty);
  });

  test('a returned record with no operation is refused whole', () async {
    // Every optional slot absent, every list slot empty: the record would
    // freeze as a wire element with nothing in it. That is a call-site
    // programming error, refused before anything is written — including the
    // companions that would otherwise ride a record going nowhere.
    final tagId = FamilyTagId(familyUuid(65));
    await expectLater(
      runtimes.mutate(
        'CaptionWithNote',
        const [],
        companions: (models) =>
            models.tag.create(tagId, {'momentId': momentId.value}),
      ),
      throwsArgumentError,
    );

    expect(await runtimes.tag.reader.get(tagId), isNull);
    expect(await queueRecords(), isEmpty);
    expect(await queuedOperations(), isEmpty);
  });

  test('two calls are two records with independent fates', () async {
    await runtimes.apply(capturePage(photos: 1));
    await runtimes.apply(
      familyMutationRecord(
        name: 'StarPage',
        operations: [
          _create('FamilyStar', FamilyStarId(familyUuid(70)), {
            'momentId': momentId.value,
            'spaceId': spaceId.value,
          }),
        ],
      ),
    );

    final records = await queueRecords();
    expect(records.map((row) => row['name']), ['CapturePage', 'StarPage']);

    // Each operation belongs to exactly one of them, and the page's two rows
    // are not the star's business.
    final byRecord = <Object?, int>{};
    for (final row in await queuedOperations()) {
      byRecord[row['mutation_ordinal']] =
          (byRecord[row['mutation_ordinal']] ?? 0) + 1;
    }
    expect(byRecord[records.first['ordinal']], 2);
    expect(byRecord[records.last['ordinal']], 1);
  });

  test('refuses an operation for a Model it was given no target for', () async {
    expect(
      runtimes.apply(
        familyMutationRecord(
          name: 'WriteStranger',
          operations: [_create('Stranger', momentId, const {})],
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  // Slot bindings (spec 2026-08-16-slot-bindings): the act's declared wiring,
  // held against what the rows actually say before anything is written. A
  // binding is a check and nothing else.
  group('slot bindings', () {
    final photoId = FamilyPhotoId(familyUuid(10));

    ModelOperation moment(FamilyMomentId id) =>
        _create('FamilyMoment', id, {'spaceId': spaceId.value, 'caption': 'a'});

    ModelOperation photoUnder(FamilyMomentId parent) => _create(
      'FamilyPhoto',
      photoId,
      {'momentId': parent.value, 'key': 'photo-10'},
    );

    test('a consistent act applies exactly as before', () async {
      final parent = moment(momentId);
      await runtimes.apply(
        familyMutationRecord(
          name: 'CapturePage',
          operations: [parent, photoUnder(momentId)],
          bindings: [
            SlotBinding(
              operation: photoUnder(momentId),
              fields: const ['momentId'],
              parent: parent,
            ),
          ],
        ),
      );
      expect(await runtimes.photo.reader.get(photoId), isNotNull);
    });

    test(
      'a create naming a different parent dies before anything lands',
      () async {
        final parent = moment(momentId);
        final stray = photoUnder(FamilyMomentId(familyUuid(9)));
        await expectLater(
          runtimes.apply(
            familyMutationRecord(
              name: 'CapturePage',
              operations: [parent, stray],
              bindings: [
                SlotBinding(
                  operation: stray,
                  fields: const ['momentId'],
                  parent: parent,
                ),
              ],
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
        // The throw is the whole story: no record, no operations, no rows.
        expect(await queueRecords(), isEmpty);
        expect(await runtimes.moment.reader.get(momentId), isNull);
        expect(await runtimes.photo.reader.get(photoId), isNull);
      },
    );

    test('a delete is held against its STORED row, not its value', () async {
      // The photo lives under momentId; the act claims to edit a different
      // page and take this photo with it.
      await runtimes.apply(capturePage(photos: 1));
      final otherId = FamilyMomentId(familyUuid(9));
      final other = moment(otherId);
      final doomed = ModelDeleteOperation(model: 'FamilyPhoto', id: photoId);
      await expectLater(
        runtimes.apply(
          familyMutationRecord(
            name: 'RevisePage',
            operations: [other, doomed],
            bindings: [
              SlotBinding(
                operation: doomed,
                fields: const ['momentId'],
                parent: other,
              ),
            ],
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await runtimes.photo.reader.get(photoId), isNotNull);
    });

    test(
      'an update patch moving the bound field is what gets checked',
      () async {
        await runtimes.apply(capturePage(photos: 1));
        final parent = ModelUpdateOperation(
          model: 'FamilyMoment',
          id: momentId,
          patch: const {'caption': 'edited'},
        );
        final moved = ModelUpdateOperation(
          model: 'FamilyPhoto',
          id: photoId,
          patch: {'momentId': familyUuid(9)},
        );
        await expectLater(
          runtimes.apply(
            familyMutationRecord(
              name: 'RevisePage',
              operations: [parent, moved],
              bindings: [
                SlotBinding(
                  operation: moved,
                  fields: const ['momentId'],
                  parent: parent,
                ),
              ],
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'a row born earlier in the SAME act is judged by what that act wrote',
      () async {
        // Verify runs before any write, so the store cannot know this row —
        // the act's own earlier create is the only truth it has. Skipping it
        // would make the one wiring mistake this check exists for silent.
        final parent = moment(momentId);
        final bornWrong = photoUnder(FamilyMomentId(familyUuid(9)));
        final touched = ModelUpdateOperation(
          model: 'FamilyPhoto',
          id: photoId,
          patch: const {'key': 'renamed'},
        );
        await expectLater(
          runtimes.apply(
            familyMutationRecord(
              name: 'RevisePage',
              operations: [parent, bornWrong, touched],
              bindings: [
                SlotBinding(
                  operation: touched,
                  fields: const ['momentId'],
                  parent: parent,
                ),
              ],
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(await queueRecords(), isEmpty);
      },
    );

    test('a row born rightly in the SAME act passes and lands', () async {
      final parent = moment(momentId);
      final born = photoUnder(momentId);
      final touched = ModelUpdateOperation(
        model: 'FamilyPhoto',
        id: photoId,
        patch: const {'key': 'renamed'},
      );
      await runtimes.apply(
        familyMutationRecord(
          name: 'RevisePage',
          operations: [parent, born, touched],
          bindings: [
            SlotBinding(
              operation: touched,
              fields: const ['momentId'],
              parent: parent,
            ),
          ],
        ),
      );
      expect(
        (await runtimes.photo.reader.get(photoId))!.fields['key'],
        'renamed',
      );
    });

    test(
      'a row whose main copy a pending delete purged is judged by held truth',
      () async {
        // An optimistic delete of a SERVER-known row empties the main table
        // but holds the row aside; a later act's bound operation on that row
        // still has truth to stand on, and a wrong parent still dies loudly.
        // (A locally-born row has no before-image — its truth is
        // nonexistence — so the seed here is canonical, as a claim writes.)
        await family.moment.create(momentId, {
          'spaceId': spaceId.value,
          'caption': 'a page',
        });
        await family.photo.create(photoId, {
          'momentId': momentId.value,
          'key': 'photo-10',
        });
        await runtimes.apply(
          familyMutationRecord(
            name: 'DiscardPhoto',
            operations: [
              ModelDeleteOperation(model: 'FamilyPhoto', id: photoId),
            ],
          ),
        );
        final otherId = FamilyMomentId(familyUuid(9));
        final other = moment(otherId);
        final revived = ModelUpdateOperation(
          model: 'FamilyPhoto',
          id: photoId,
          patch: const {'key': 'renamed'},
        );
        await expectLater(
          runtimes.apply(
            familyMutationRecord(
              name: 'RevisePage',
              operations: [other, revived],
              bindings: [
                SlotBinding(
                  operation: revived,
                  fields: const ['momentId'],
                  parent: other,
                ),
              ],
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'a row this device does not hold is not the binding\'s to judge',
      () async {
        final parent = moment(momentId);
        final phantom = ModelDeleteOperation(
          model: 'FamilyPhoto',
          id: FamilyPhotoId(familyUuid(99)),
        );
        // The failure is the write's own — the store's, not a binding verdict
        // invented for a row that is not there.
        await expectLater(
          runtimes.apply(
            familyMutationRecord(
              name: 'RevisePage',
              operations: [parent, phantom],
              bindings: [
                SlotBinding(
                  operation: phantom,
                  fields: const ['momentId'],
                  parent: parent,
                ),
              ],
            ),
          ),
          throwsA(isA<LocalStorageException>()),
        );
      },
    );
  });
}

ModelOperation _create(String model, ModelId id, Map<String, Object?> values) =>
    ModelCreateOperation(model: model, id: id, values: values);
