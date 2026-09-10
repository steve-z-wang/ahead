import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// Flow ③ (CAP-396 spec §8): the Backend claims the parent and nothing else,
/// so the device mirrors an absent parent by running the same expansion — and
/// settles an accepted cascade by forgetting the truth it was holding for the
/// rows that fell.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';

  late TestLocalDatabase database;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue outbox;
  late DownlinkPageProcessor store;
  late List<CanonicalDownlinkChange> applied;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(10));
  final photoId = FamilyPhotoId(familyUuid(20));

  PrerequisiteInvocation remoteObject(String key) =>
      PrerequisiteInvocation(name: 'RemoteObject', arguments: {'key': key});

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    runtimes = FamilyRuntimes(database.scope, family.registry);
    outbox = MutationQueue(database.scope, registry: family.registry);
    // The fixture's photos carry a readiness key; the product's media
    // worker is what vouches for it, and here the test stands in for one.
    await ReadinessLedger(database.scope).markReady(remoteObject('k'));
    await outbox.initialize(clientId);
    applied = [];
    store = DownlinkPageProcessor(
      database: database.scope,
      registry: family.registry,
      decoder: ModelChangeDecoder(family.registry),
      onApplied: (changes) async => applied.addAll(changes),
    );
    await setTestScopes(database.scope, [userScope]);
  });

  tearDown(() => database.close());

  test(
    'settlement keeps a mark a still-queued act references (CAP-521)',
    () async {
      // Two acts wait on the SAME readiness key, shipped as two batches. The
      // first settling must not prune the mark the second still needs.
      final ledger = ReadinessLedger(database.scope);
      final runtimesLocal = runtimes;
      await family.space.create(spaceId, {'name': 'book'});
      await runtimesLocal.mutate('CapturePage', [
        ModelCreateOperation(
          model: 'FamilyMoment',
          id: momentId,
          values: {'spaceId': spaceId.value, 'caption': 'one'},
        ),
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: photoId,
          values: {'momentId': momentId.value, 'key': 'shared'},
        ),
      ]);
      await runtimesLocal.mutate('AttachPhoto', [
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: FamilyPhotoId(familyUuid(21)),
          values: {'momentId': momentId.value, 'key': 'shared'},
        ),
      ]);
      await ledger.markReady(remoteObject('shared'));

      // Batch 1: the first act alone.
      final first = await outbox.scheduledCandidate(limit: 1);
      await outbox.freeze(
        expectedSequence: first!.batchSequence,
        mutationOrdinals: first.records.keys.toList(),
      );
      await outbox.recordResponse(
        batchSequence: first.batchSequence,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 5)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 5,
        ),
        rejections: const [],
      );
      await store.apply(
        DownlinkPage(
          scope: userScope,
          fromSyncId: 0,
          throughSyncId: 5,
          changes: const [],
        ),
        afterSyncId: 0,
      );

      // The second act is still queued on 'shared': the mark must survive.
      expect(await ledger.read(remoteObject('shared')), ReadinessState.ready);

      // Batch 2: the second act. Once IT settles, nothing references the key
      // and the mark goes — fully synced means every auxiliary table is empty.
      final second = await outbox.scheduledCandidate(limit: 1);
      await outbox.freeze(
        expectedSequence: second!.batchSequence,
        mutationOrdinals: second.records.keys.toList(),
      );
      await outbox.recordResponse(
        batchSequence: second.batchSequence,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 6)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 6,
        ),
        rejections: const [],
      );
      await store.apply(
        DownlinkPage(
          scope: userScope,
          fromSyncId: 5,
          throughSyncId: 6,
          changes: const [],
        ),
        afterSyncId: 5,
      );

      expect(await ledger.read(remoteObject('shared')), ReadinessState.pending);
    },
  );

  Future<void> seedSyncedBook() async {
    await family.space.create(spaceId, {'name': 'Everyday'});
    await family.moment.create(momentId, {
      'spaceId': spaceId.value,
      'caption': 'a page',
    });
    await family.photo.create(photoId, {
      'momentId': momentId.value,
      'key': 'k',
    });
  }

  /// One claim: the book is gone, or no longer visible — the device cannot
  /// tell the two apart, and cascade is right either way.
  DownlinkPage bookIsAbsent(int syncId) => DownlinkPage(
    scope: userScope,
    fromSyncId: syncId - 1,
    throughSyncId: syncId,
    changes: [
      AddressedModelChange(
        syncId: syncId,
        raw: {
          'syncId': syncId,
          'model': 'FamilySpace',
          'operation': 'delete',
          'id': {'id': spaceId.value.uuid},
        },
      ),
    ],
  );

  /// Sends the next `limit` queued mutations and has the server accept them.
  Future<void> acceptBatch({required int limit}) async {
    final candidate = await outbox.scheduledCandidate(limit: limit);
    final batch = await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: candidate.records.keys.toList(),
    );
    await outbox.recordResponse(
      batchSequence: batch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 1)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 1),
      rejections: const [],
    );
    await store.apply(
      DownlinkPage(
        scope: userScope,
        fromSyncId: 0,
        throughSyncId: 1,
        changes: const [],
      ),
      afterSyncId: 0,
    );
  }

  /// The server speaks about a page that is locally gone with its book.
  DownlinkPage pageChanged(int syncId) => DownlinkPage(
    scope: userScope,
    fromSyncId: syncId - 1,
    throughSyncId: syncId,
    changes: [
      AddressedModelChange(
        syncId: syncId,
        raw: {
          'syncId': syncId,
          'model': 'FamilyMoment',
          'operation': 'upsert',
          'id': {'id': momentId.value.uuid},
          'data': {'spaceId': spaceId.value.uuid, 'caption': 'from the server'},
        },
      ),
    ],
  );

  Future<int> queueLength() async => (await database.scope.database.query(
    DatabaseQuery(sql: 'SELECT ordinal FROM pending_mutations'),
  )).rows.length;

  /// One named act each, so the server can answer them one at a time.
  Future<void> burnBook() => runtimes.mutate('BurnBook', [
    ModelDeleteOperation(model: 'FamilySpace', id: spaceId),
  ]);

  Future<void> editPage(FamilyMomentId id, String caption) =>
      runtimes.mutate('EditPage', [
        ModelUpdateOperation(
          model: 'FamilyMoment',
          id: id,
          patch: {'caption': caption},
        ),
      ]);

  test('an absent book clears its subtree', () async {
    await seedSyncedBook();

    final result = await store.apply(bookIsAbsent(1), afterSyncId: 0);

    expect(result.failures, isEmpty);
    expect(await family.space.readMain(spaceId), isNull);
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.photo.readMain(photoId), isNull);
    final deleted = applied.whereType<CanonicalDownlinkDelete>().toList();
    expect(deleted.map((change) => change.entry.schema.name), [
      'FamilySpace',
      'FamilyPhoto',
      'FamilyMoment',
    ]);
    expect(deleted[0].row.fields, {'name': 'Everyday'});
    expect(deleted[1].row.fields['key'], 'k');
    expect(deleted[2].row.fields['caption'], 'a page');
  });

  test('a parent cascade waits for the last scope claim', () async {
    const bookA = 'Book:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const bookB = 'Book:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    await setTestScopes(database.scope, [bookA, bookB]);

    DownlinkPage snapshot(String scope) => DownlinkPage(
      scope: scope,
      fromSyncId: 0,
      throughSyncId: 3,
      changes: [
        AddressedModelChange(
          syncId: 1,
          raw: {
            'syncId': 1,
            'model': 'FamilySpace',
            'operation': 'upsert',
            'id': {'id': spaceId.value.uuid},
            'data': {'name': 'Everyday'},
          },
        ),
        AddressedModelChange(
          syncId: 2,
          raw: {
            'syncId': 2,
            'model': 'FamilyMoment',
            'operation': 'upsert',
            'id': {'id': momentId.value.uuid},
            'data': {'spaceId': spaceId.value.uuid, 'caption': 'a page'},
          },
        ),
        AddressedModelChange(
          syncId: 3,
          raw: {
            'syncId': 3,
            'model': 'FamilyPhoto',
            'operation': 'upsert',
            'id': {'id': photoId.value.uuid},
            'data': {'momentId': momentId.value.uuid, 'key': 'k'},
          },
        ),
      ],
    );

    await store.apply(snapshot(bookA), afterSyncId: 0);
    await store.apply(snapshot(bookB), afterSyncId: 0);
    await store.apply(
      DownlinkPage(
        scope: bookA,
        fromSyncId: 3,
        throughSyncId: 4,
        changes: [
          AddressedModelChange(
            syncId: 4,
            raw: {
              'syncId': 4,
              'model': 'FamilySpace',
              'operation': 'delete',
              'id': {'id': spaceId.value.uuid},
            },
          ),
        ],
      ),
      afterSyncId: 3,
    );

    expect(await family.space.readMain(spaceId), isNotNull);
    expect(await family.moment.readMain(momentId), isNotNull);
    expect(await family.photo.readMain(photoId), isNotNull);

    await store.apply(
      DownlinkPage(
        scope: bookB,
        fromSyncId: 3,
        throughSyncId: 4,
        changes: [
          AddressedModelChange(
            syncId: 4,
            raw: {
              'syncId': 4,
              'model': 'FamilySpace',
              'operation': 'delete',
              'id': {'id': spaceId.value.uuid},
            },
          ),
        ],
      ),
      afterSyncId: 3,
    );

    expect(await family.space.readMain(spaceId), isNull);
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.photo.readMain(photoId), isNull);
    final claims = await database.database.query(
      DatabaseQuery(sql: 'SELECT 1 FROM downlink_scope_rows'),
    );
    expect(claims.rows, isEmpty);
  });

  test('applying the same page again changes nothing', () async {
    await seedSyncedBook();
    await store.apply(bookIsAbsent(1), afterSyncId: 0);

    final result = await store.apply(bookIsAbsent(2), afterSyncId: 1);

    expect(result.failures, isEmpty);
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.photo.readMain(photoId), isNull);
  });

  test('a page the user was editing replays over nothing', () async {
    await seedSyncedBook();
    await editPage(momentId, 'edited');

    await store.apply(bookIsAbsent(1), afterSyncId: 0);

    // Truth is now nonexistence, and an update over nothing yields nothing —
    // the edit is doomed and its rejection is what takes it off the queue.
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.moment.readBefore(momentId), isNull);
    expect(await family.moment.pendingMutations(momentId), hasLength(1));
  });

  test('a page the user had just written comes back off truth', () async {
    await seedSyncedBook();
    final freshId = FamilyMomentId(familyUuid(11));
    await runtimes.mutate('WritePage', [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: freshId,
        values: {'spaceId': spaceId.value, 'caption': 'unsent'},
      ),
    ]);

    await store.apply(bookIsAbsent(1), afterSyncId: 0);

    // Its create still stands on its own, over nonexistence.
    expect(
      (await family.moment.readMain(freshId))?.fields['caption'],
      'unsent',
    );
  });

  test('settling our own accepted burn forgets every held row', () async {
    await seedSyncedBook();
    await burnBook();

    await acceptBatch(limit: 100);

    expect(await queueLength(), 0);
    expect(await family.space.readBefore(spaceId), isNull);
    expect(await family.moment.readBefore(momentId), isNull);
    expect(await family.photo.readBefore(photoId), isNull);
    expect(await family.moment.readMain(momentId), isNull);
  });

  test(
    'a fallen row whose own edit is still in flight keeps its truth',
    () async {
      await seedSyncedBook();
      await editPage(momentId, 'edited');
      await burnBook();
      // Only the page's edit travels; the book's delete is still on the device.
      await acceptBatch(limit: 1);

      // Accepting the edit does not put the page back: the book's delete still
      // stands over it, and replay knows that without anything being written
      // down for the page itself.
      expect(await family.moment.readMain(momentId), isNull);
      expect(await family.moment.readBefore(momentId), isNotNull);
      expect(await family.space.pendingMutations(spaceId), hasLength(1));
    },
  );

  test('an accepted edit never resurrects the page the delete took', () async {
    await seedSyncedBook();
    await editPage(momentId, 'edited');
    await burnBook();
    // Both travel together and both are accepted.
    await acceptBatch(limit: 100);

    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.moment.readBefore(momentId), isNull);
    expect(await queueLength(), 0);
  });

  test('news about a fallen page does not bring it back', () async {
    await seedSyncedBook();
    await burnBook();

    await store.apply(pageChanged(1), afterSyncId: 0);

    // The book's delete still stands, so the page stays gone — and the new
    // truth lands underneath it, ready for the rejection that may undo it all.
    expect(await family.moment.readMain(momentId), isNull);
    expect(
      (await family.moment.readBefore(momentId))?.fields['caption'],
      'from the server',
    );
  });
}
