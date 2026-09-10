import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// Flow ② (CAP-396 spec §7): the server refuses a cascade delete, so the whole
/// subtree comes back — derived from the truth held aside, with whatever each
/// row still has pending replayed on top of it.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';

  late TestLocalDatabase database;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;
  late MutationQueue outbox;

  final spaceId = FamilySpaceId(familyUuid(1));
  final firstMomentId = FamilyMomentId(familyUuid(10));
  final secondMomentId = FamilyMomentId(familyUuid(11));
  final photoId = FamilyPhotoId(familyUuid(20));

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    runtimes = FamilyRuntimes(database.scope, family.registry);
    outbox = MutationQueue(database.scope, registry: family.registry);
    await ReadinessLedger(database.scope).markReady(remoteObject('k'));
    await outbox.initialize(clientId);
  });

  tearDown(() => database.close());

  /// A book with two pages, one of them carrying a photo — all of it the
  /// server's own state, nothing pending.
  Future<void> seedSyncedBook() async {
    await family.space.create(spaceId, {'name': 'Everyday'});
    await family.moment.create(firstMomentId, {
      'spaceId': spaceId.value,
      'caption': 'first',
    });
    await family.moment.create(secondMomentId, {
      'spaceId': spaceId.value,
      'caption': 'second',
    });
    await family.photo.create(photoId, {
      'momentId': secondMomentId.value,
      'key': 'k',
    });
  }

  /// Each of these is its own named act: the tests turn on which one the
  /// server refuses, so they must be able to fail separately.
  Future<void> burnBook() => runtimes.mutate('BurnBook', [
    ModelDeleteOperation(model: 'FamilySpace', id: spaceId),
  ]);

  Future<void> deletePage(FamilyMomentId id) => runtimes.mutate('DeletePage', [
    ModelDeleteOperation(model: 'FamilyMoment', id: id),
  ]);

  Future<void> editPage(FamilyMomentId id, String caption) =>
      runtimes.mutate('EditPage', [
        ModelUpdateOperation(
          model: 'FamilyMoment',
          id: id,
          patch: {'caption': caption},
        ),
      ]);

  Future<int> send() async {
    final candidate = await outbox.scheduledCandidate(limit: 100);
    final batch = await outbox.freeze(
      expectedSequence: candidate!.batchSequence,
      mutationOrdinals: candidate.records.keys.toList(),
    );
    return batch.batchSequence;
  }

  Future<int> ordinalOf(
    TypedModelRegistryEntry<ModelId> entry,
    ModelId id,
  ) async => (await entry.pendingMutations(id)).single.position.mutationOrdinal;

  Future<void> reject(int batch, int ordinal) => outbox.recordResponse(
    batchSequence: batch,
    requiredCheckpoints: [UplinkCheckpoint(scope: userScope, syncId: 7)],
    legacyPrincipalCheckpoint: UplinkCheckpoint(scope: userScope, syncId: 7),
    rejections: [UplinkMutationRejection(mutationId: ordinal, code: 'refused')],
  );

  test('a refused book delete brings the whole subtree back', () async {
    await seedSyncedBook();
    await burnBook();
    final ordinal = await ordinalOf(family.space, spaceId);
    final batch = await send();

    await reject(batch, ordinal);

    expect((await family.space.readMain(spaceId))?.fields['name'], 'Everyday');
    expect(
      (await family.moment.readMain(firstMomentId))?.fields['caption'],
      'first',
    );
    expect(
      (await family.moment.readMain(secondMomentId))?.fields['caption'],
      'second',
    );
    expect(await family.photo.readMain(photoId), isNotNull);
  });

  test('nothing is left holding truth once everything is back', () async {
    await seedSyncedBook();
    await burnBook();
    final ordinal = await ordinalOf(family.space, spaceId);

    await reject(await send(), ordinal);

    expect(await family.space.readBefore(spaceId), isNull);
    expect(await family.moment.readBefore(firstMomentId), isNull);
    expect(await family.moment.readBefore(secondMomentId), isNull);
    expect(await family.photo.readBefore(photoId), isNull);
  });

  test('a page the user deleted first stays deleted', () async {
    await seedSyncedBook();
    await deletePage(firstMomentId);
    await burnBook();
    final ordinal = await ordinalOf(family.space, spaceId);

    await reject(await send(), ordinal);

    // The book and everything else is back...
    expect(await family.space.readMain(spaceId), isNotNull);
    expect(await family.moment.readMain(secondMomentId), isNotNull);
    // ...but the page the user deleted in its own right is not: its delete is
    // still pending, and replay puts it back where it was.
    expect(await family.moment.readMain(firstMomentId), isNull);
    expect(await family.moment.readBefore(firstMomentId), isNotNull);
    expect(await family.moment.pendingMutations(firstMomentId), hasLength(1));
  });

  test('a page the user had edited comes back edited', () async {
    await seedSyncedBook();
    await editPage(firstMomentId, 'edited');
    await burnBook();
    final ordinal = await ordinalOf(family.space, spaceId);

    await reject(await send(), ordinal);

    expect(
      (await family.moment.readMain(firstMomentId))?.fields['caption'],
      'edited',
    );
    // Still diverging, so its truth stays held.
    expect(
      (await family.moment.readBefore(firstMomentId))?.fields['caption'],
      'first',
    );
  });

  test('refusing the page delete while the book delete stands', () async {
    await seedSyncedBook();
    await deletePage(firstMomentId);
    final momentOrdinal = await ordinalOf(family.moment, firstMomentId);
    await burnBook();

    await reject(await send(), momentOrdinal);

    // The page's own delete is gone, but the book's still stands over it —
    // the page inherits that delete and stays gone until the book resolves.
    expect(await family.moment.readMain(firstMomentId), isNull);
    expect(await family.moment.readBefore(firstMomentId), isNotNull);
    expect(await family.moment.pendingMutations(firstMomentId), isEmpty);
    expect(await family.space.pendingMutations(spaceId), hasLength(1));
  });
}
