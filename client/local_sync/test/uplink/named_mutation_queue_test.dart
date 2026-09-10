import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// The queue at mutation granularity (CAP-439): a named record is the unit of
/// readiness, of batch membership, of the drop closure, and of rejection —
/// however many operations spell it.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';
  late TestLocalDatabase fixture;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue outbox;
  late ReadinessLedger ledger;

  PrerequisiteInvocation remoteObject(String key) =>
      PrerequisiteInvocation(name: 'RemoteObject', arguments: {'key': key});
  Future<void> markReady(String key) => ledger.markReady(remoteObject(key));
  Future<void> markFailed(String key) => ledger.markFailed(remoteObject(key));

  final spaceId = FamilySpaceId(familyUuid(1));

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    ledger = ReadinessLedger(fixture.scope);
    outbox = MutationQueue(fixture.scope, registry: family.registry);
    await outbox.initialize(clientId);
    await family.space.create(spaceId, {'name': 'book'});
  });

  tearDown(() => fixture.close());

  /// One page and its photos, as one named act. Each photo carries a readiness
  /// key, so the act waits on all of them.
  MutationRecord capturePage({
    required int page,
    required List<String> photoKeys,
    int firstPhoto = 100,
  }) => familyMutationRecord(
    name: 'CapturePage',
    operations: [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: FamilyMomentId(familyUuid(page)),
        values: {'spaceId': spaceId.value, 'caption': 'page $page'},
      ),
      for (var index = 0; index < photoKeys.length; index += 1)
        ModelCreateOperation(
          model: 'FamilyPhoto',
          id: FamilyPhotoId(familyUuid(firstPhoto + index)),
          values: {'momentId': familyUuid(page), 'key': photoKeys[index]},
        ),
    ],
  );

  Future<List<int>> queuedRecords() async => (await fixture.scope.current.query(
    DatabaseQuery(
      sql: 'SELECT ordinal FROM pending_mutations ORDER BY ordinal',
    ),
  )).rows.map((row) => row['ordinal']! as int).toList();

  Future<List<int>> queuedOrdinals() async =>
      (await fixture.scope.current.query(
        DatabaseQuery(
          sql:
              'SELECT position FROM pending_mutation_operations '
              'ORDER BY mutation_ordinal, position',
        ),
      )).rows.map((row) => row['position']! as int).toList();

  List<int> parentIds(UplinkBatchCandidate candidate) =>
      candidate.records.keys.toList()..sort();

  int firstWireId(UplinkBatchCandidate batch) {
    final record = batch.records.values.toList()
      ..sort((left, right) => left.ordinal.compareTo(right.ordinal));
    return record.first.legacyWireOrdinal ?? record.first.ordinal;
  }

  test('a pending key holds the whole act, not the operation', () async {
    await runtimes.apply(capturePage(page: 2, photoKeys: ['a', 'b']));
    await markReady('a');

    // One key of the three operations is still unspoken for, so nothing of the
    // act may ship — including the page itself, which carries no key at all.
    expect(await outbox.scheduledCandidate(limit: 20), isNull);

    await markReady('b');
    final candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations, hasLength(3));
  });

  test('explicit discard drops the failed act whole', () async {
    await runtimes.apply(capturePage(page: 2, photoKeys: ['good', 'doomed']));
    await markReady('good');
    await markFailed('doomed');
    await outbox.discardFailed(clientId: clientId, ordinal: 1);

    expect(await outbox.scheduledCandidate(limit: 20), isNull);

    // Which writes share fate is schema, so the page does not publish minus a
    // photo the way an anonymous group would: the act is gone, and every row
    // it wrote is rebuilt away.
    expect(await queuedOrdinals(), isEmpty);
    expect(await family.moment.readMain(FamilyMomentId(familyUuid(2))), isNull);
    expect(await family.photo.readMain(FamilyPhotoId(familyUuid(100))), isNull);
    expect(await family.photo.readMain(FamilyPhotoId(familyUuid(101))), isNull);
    // The record it was is gone too: nothing of the act is outstanding.
    expect(await queuedRecords(), isEmpty);
  });

  test('a 42-operation act is one mutation against the batch limit', () async {
    await runtimes.apply(
      capturePage(
        page: 2,
        photoKeys: [for (var index = 0; index < 41; index += 1) 'key-$index'],
      ),
    );
    for (var index = 0; index < 41; index += 1) {
      await markReady('key-$index');
    }

    // 42 operations, one record: the batch limit needs no reinterpretation,
    // and the act is never split.
    final candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations, hasLength(42));
    expect(candidate.groupBoundaries, [42]);
  });

  test('the limit counts acts, so a 21st is left for the next batch', () async {
    for (var page = 2; page <= 22; page += 1) {
      await runtimes.apply(capturePage(page: page, photoKeys: const []));
    }

    final candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations, hasLength(20));
    expect(candidate.groupBoundaries.last, 20);
  });

  test('a rejection rolls the whole act back', () async {
    await runtimes.apply(capturePage(page: 2, photoKeys: ['a']));
    await markReady('a');
    final candidate = await outbox.scheduledCandidate(limit: 20);
    final batch = await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: parentIds(candidate),
    );

    // The server refused the ACT, named by the ordinal of its first operation.
    await outbox.recordResponse(
      batchSequence: batch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [
        UplinkMutationRejection(
          mutationId: firstWireId(batch),
          code: 'capture_page.not_allowed',
        ),
      ],
    );

    expect(await queuedOrdinals(), isEmpty);
    expect(await queuedRecords(), isEmpty);
    expect(await family.moment.readMain(FamilyMomentId(familyUuid(2))), isNull);
    expect(await family.photo.readMain(FamilyPhotoId(familyUuid(100))), isNull);
  });

  test('a companion shares the act ordinal and its whole fate', () async {
    final tagId = FamilyTagId(familyUuid(80));
    await runtimes.apply(
      capturePage(page: 2, photoKeys: ['a']),
      companions: (models) =>
          models.tag.create(tagId, {'momentId': familyUuid(2)}),
    );
    await markReady('a');

    final rows = await fixture.scope.current.query(
      DatabaseQuery(
        sql:
            'SELECT model, is_uplink, mutation_ordinal FROM '
            'pending_mutation_operations '
            'ORDER BY mutation_ordinal, position',
      ),
    );
    // One record, every operation beneath it, and the wire membership stated
    // per operation rather than inferred from the Model (CAP-488).
    expect(
      rows.rows.map((row) => row['mutation_ordinal']).toSet(),
      hasLength(1),
    );
    expect(
      rows.rows.map((row) => (row['model'], row['is_uplink'])),
      containsAll(<(Object?, Object?)>[
        ('FamilyTag', 0),
        ('FamilyMoment', 1),
        ('FamilyPhoto', 1),
      ]),
    );

    // Only the wire operations are offered to the server; the companion stays
    // in the queue holding the act's fate.
    final candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations.where((row) => row.isUplink), hasLength(2));
    final batch = await outbox.freeze(
      expectedSequence: candidate.batchSequence,
      mutationOrdinals: parentIds(candidate),
    );

    await outbox.recordResponse(
      batchSequence: batch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [
        UplinkMutationRejection(
          mutationId: firstWireId(batch),
          code: 'capture_page.not_allowed',
        ),
      ],
    );

    expect(await queuedOrdinals(), isEmpty);
    expect(await queuedRecords(), isEmpty);
    expect(await family.moment.readMain(FamilyMomentId(familyUuid(2))), isNull);
    // The companion rolled back with the act it was written inside.
    expect(await family.tag.readMain(tagId), isNull);
  });

  test('an accepted companion becomes final', () async {
    final tagId = FamilyTagId(familyUuid(81));
    await runtimes.apply(
      capturePage(page: 3, photoKeys: ['b']),
      companions: (models) =>
          models.tag.create(tagId, {'momentId': familyUuid(3)}),
    );
    await markReady('b');
    final candidate = await outbox.scheduledCandidate(limit: 20);
    final batch = await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: parentIds(candidate),
    );
    await outbox.recordResponse(
      batchSequence: batch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 9)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 9),
      rejections: const [],
    );

    // Acceptance is what makes a companion's truth final: no Downlink change
    // will ever name it (CAP-488). An empty advancing page settles every
    // batch it reaches.
    final store = DownlinkPageProcessor(
      database: fixture.scope,
      registry: family.registry,
      decoder: ModelChangeDecoder(family.registry),
    );
    await setTestScopes(fixture.scope, [userScope]);
    final result = await store.apply(
      DownlinkPage(
        scope: userScope,
        fromSyncId: 0,
        throughSyncId: 9,
        changes: const [],
      ),
      afterSyncId: 0,
    );
    expect(result.failures, isEmpty);

    expect(await queuedOrdinals(), isEmpty);
    expect(await family.tag.readMain(tagId), isNotNull);
    expect(await family.tag.readBefore(tagId), isNull);
  });

  test(
    'a lifecycle dependent waits for its target create to be accepted',
    () async {
      await runtimes.apply(capturePage(page: 2, photoKeys: ['one']));
      await runtimes.apply(
        familyMutationRecord(
          name: 'TagPage',
          operations: [
            ModelCreateOperation(
              model: 'FamilyTag',
              id: FamilyTagId(familyUuid(5)),
              values: {'momentId': familyUuid(2)},
            ),
          ],
        ),
      );

      // Readiness alone cannot publish a row whose referenced target does not
      // exist on the Backend yet.
      expect(await outbox.scheduledCandidate(limit: 20), isNull);

      await markReady('one');
      final page = await outbox.scheduledCandidate(limit: 20);
      expect(page!.mutations.map((row) => row.order), [
        const MutationPosition(mutationOrdinal: 1, operationPosition: 0),
        const MutationPosition(mutationOrdinal: 1, operationPosition: 1),
      ]);
      expect(page.groupBoundaries, [2]);

      final batch = await outbox.freeze(
        expectedSequence: page.batchSequence,
        mutationOrdinals: parentIds(page),
      );
      await outbox.recordResponse(
        batchSequence: batch.batchSequence,
        requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 1)],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: 1,
        ),
        rejections: const [],
      );

      final tag = await outbox.scheduledCandidate(limit: 20);
      expect(tag!.mutations.map((row) => row.order), [
        const MutationPosition(mutationOrdinal: 2, operationPosition: 0),
      ]);
      expect(tag.groupBoundaries, [1]);
    },
  );

  test('an act is deferred whole rather than cut by the window', () async {
    await runtimes.apply(
      familyMutationRecord(
        name: 'TagPage',
        operations: [
          ModelCreateOperation(
            model: 'FamilyTag',
            id: FamilyTagId(familyUuid(5)),
            values: {'momentId': familyUuid(2)},
          ),
        ],
      ),
    );
    await runtimes.apply(capturePage(page: 2, photoKeys: ['one']));
    await markReady('one');

    // The window measures ACTS, and it cuts only between them: room for one
    // takes the tag alone rather than the tag and half a page.
    final first = await outbox.scheduledCandidate(limit: 1);
    expect(first!.mutations.map((row) => row.order), [
      const MutationPosition(mutationOrdinal: 1, operationPosition: 0),
    ]);
    // Room for two takes the page whole, both operations of it.
    final second = await outbox.scheduledCandidate(limit: 2);
    expect(second!.mutations.map((row) => row.order), [
      const MutationPosition(mutationOrdinal: 1, operationPosition: 0),
      const MutationPosition(mutationOrdinal: 2, operationPosition: 0),
      const MutationPosition(mutationOrdinal: 2, operationPosition: 1),
    ]);
  });

  test('a readiness mark wakes the worker on its own', () async {
    await runtimes.apply(capturePage(page: 2, photoKeys: ['one']));

    // A mark is the one event that can make a waiting act sendable without the
    // queue moving at all. If the sendable signal ignored the ledger, the page
    // would sit until some unrelated write happened to wake the worker.
    final sendable = outbox.watchSendable().take(2).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await markReady('one');

    await expectLater(sendable, completion(hasLength(2)));
  });

  test('lifecycle edges only bind to target creates already queued', () async {
    final otherSpaceId = FamilySpaceId(familyUuid(9));
    final otherMomentId = FamilyMomentId(familyUuid(6));
    final starId = FamilyStarId(familyUuid(10));

    Future<void> foundBook() => runtimes.apply(
      familyMutationRecord(
        name: 'FoundBook',
        operations: [
          ModelCreateOperation(
            model: 'FamilySpace',
            id: otherSpaceId,
            values: const {'name': 'other book'},
          ),
        ],
      ),
    );
    Future<void> writePage() => runtimes.apply(
      familyMutationRecord(
        name: 'WritePage',
        operations: [
          ModelCreateOperation(
            model: 'FamilyMoment',
            id: otherMomentId,
            values: {'spaceId': otherSpaceId.value, 'caption': 'a page'},
          ),
        ],
      ),
    );
    Future<void> starPage() => runtimes.apply(
      familyMutationRecord(
        name: 'StarPage',
        operations: [
          ModelCreateOperation(
            model: 'FamilyStar',
            id: starId,
            values: {
              'spaceId': otherSpaceId.value,
              'momentId': otherMomentId.value,
            },
          ),
        ],
      ),
    );

    var syncId = 0;
    late DownlinkPageProcessor store;
    Future<void> initializeSettlement() async {
      store = DownlinkPageProcessor(
        database: fixture.scope,
        registry: family.registry,
        decoder: ModelChangeDecoder(family.registry),
      );
      await setTestScopes(fixture.scope, [userScope]);
    }

    Future<void> acceptAndSettle(UplinkBatchCandidate candidate) async {
      final batch = await outbox.freeze(
        expectedSequence: candidate.batchSequence,
        mutationOrdinals: parentIds(candidate),
      );
      final required = syncId + 1;
      await outbox.recordResponse(
        batchSequence: batch.batchSequence,
        requiredCheckpoints: [
          UplinkCheckpoint(scope: userScope, syncId: required),
        ],
        legacyPrincipalCheckpoint: UplinkCheckpoint(
          scope: userScope,
          syncId: required,
        ),
        rejections: const [],
      );
      final result = await store.apply(
        DownlinkPage(
          scope: userScope,
          fromSyncId: syncId,
          throughSyncId: required,
          changes: const [],
        ),
        afterSyncId: syncId,
      );
      expect(result.failures, isEmpty);
      syncId = required;
    }

    // Targets first: each source waits for the earlier queued create of the
    // row it references.
    await foundBook();
    await writePage();
    await starPage();
    await initializeSettlement();
    var candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations.map((row) => row.model), ['FamilySpace']);
    await acceptAndSettle(candidate);
    candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations.map((row) => row.model), ['FamilyMoment']);
    await acceptAndSettle(candidate);
    candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations.map((row) => row.model), ['FamilyStar']);

    // Source first: a partial replica may legitimately lack its target, so a
    // later local create never invents a retroactive edge.
    await fixture.close();
    fixture = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(fixture.scope);
    runtimes = FamilyRuntimes(fixture.scope, family.registry);
    outbox = MutationQueue(fixture.scope, registry: family.registry);
    await outbox.initialize(clientId);
    syncId = 0;
    await starPage();
    await foundBook();
    await writePage();
    await initializeSettlement();
    candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations.map((row) => row.model), [
      'FamilyStar',
      'FamilySpace',
    ]);
    expect(candidate.groupBoundaries, [1, 2]);
    await acceptAndSettle(candidate);
    candidate = await outbox.scheduledCandidate(limit: 20);
    expect(candidate!.mutations.map((row) => row.model), ['FamilyMoment']);
  });

  test('two acts keep independent fates in one batch', () async {
    await runtimes.apply(capturePage(page: 2, photoKeys: const []));
    await runtimes.apply(
      capturePage(page: 3, photoKeys: const [], firstPhoto: 200),
    );

    final candidate = await outbox.scheduledCandidate(limit: 20);
    final batch = await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: parentIds(candidate),
    );
    await outbox.recordResponse(
      batchSequence: batch.batchSequence,
      requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
      legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
      rejections: [
        UplinkMutationRejection(
          mutationId: firstWireId(batch),
          code: 'capture_page.not_allowed',
        ),
      ],
    );

    // The refused act is gone; its neighbour is untouched.
    expect(await family.moment.readMain(FamilyMomentId(familyUuid(2))), isNull);
    expect(
      await family.moment.readMain(FamilyMomentId(familyUuid(3))),
      isNotNull,
    );
  });
}
