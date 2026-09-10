import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;

  final spaceId = FamilySpaceId(familyUuid(1));
  final otherSpaceId = FamilySpaceId(familyUuid(2));
  final momentId = FamilyMomentId(familyUuid(10));
  final otherMomentId = FamilyMomentId(familyUuid(11));
  final photoId = FamilyPhotoId(familyUuid(20));
  final tagId = FamilyTagId(familyUuid(30));
  final starId = FamilyStarId(familyUuid(31));
  final memberId = FamilyMemberId(
    spaceId: familyUuid(1),
    userId: familyUuid(40),
  );

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    runtimes = FamilyRuntimes(database.scope, family.registry);
  });

  tearDown(() => database.close());

  /// A book with one page, one photo on it, one tag, one star and one member —
  /// server truth on every row, nothing pending.
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
    await family.tag.create(tagId, {'momentId': momentId.value});
    await family.star.create(starId, {
      'spaceId': spaceId.value,
      'momentId': momentId.value,
    });
    await family.member.create(memberId, {'role': 'owner'});
  }

  Future<int> queueLength() async => (await database.scope.database.query(
    DatabaseQuery(sql: 'SELECT ordinal FROM pending_mutations'),
  )).rows.length;

  /// One named act each: the cascade is the delete's own business, never a
  /// second act, so every test here spells exactly one write.
  Future<void> burnBook() => runtimes.mutate('BurnBook', [
    ModelDeleteOperation(model: 'FamilySpace', id: spaceId),
  ]);

  Future<void> deletePage(FamilyMomentId id) => runtimes.mutate('DeletePage', [
    ModelDeleteOperation(model: 'FamilyMoment', id: id),
  ]);

  test('one delete empties the whole subtree from main', () async {
    await seedSyncedBook();

    await burnBook();

    expect(await family.space.readMain(spaceId), isNull);
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.photo.readMain(photoId), isNull);
    expect(await family.member.readMain(memberId), isNull);
  });

  test('an ordinary reference is left alone by the cascade', () async {
    await seedSyncedBook();

    await burnBook();

    // The tag names the page and the star names both the book and the page.
    // Neither declares onTargetDelete, so the cascade steps over both — a
    // reference is an ordering fact, never a lifecycle one (CAP-437).
    expect(await family.tag.readMain(tagId), isNotNull);
    expect(await family.star.readMain(starId), isNotNull);
  });

  test('the whole cascade appends exactly one queue entry', () async {
    await seedSyncedBook();

    await burnBook();

    expect(await queueLength(), 1);
    expect(await family.space.pendingMutations(spaceId), hasLength(1));
    expect(await family.moment.pendingMutations(momentId), isEmpty);
    expect(await family.photo.pendingMutations(photoId), isEmpty);
  });

  test('every previously clean row keeps its truth aside', () async {
    await seedSyncedBook();

    await burnBook();

    expect(
      (await family.space.readBefore(spaceId))?.fields['name'],
      'Everyday',
    );
    expect(
      (await family.moment.readBefore(momentId))?.fields['caption'],
      'a page',
    );
    expect(await family.photo.readBefore(photoId), isNotNull);
    expect(await family.member.readBefore(memberId), isNotNull);
  });

  test('a descendant that already diverged keeps the server\'s state', () async {
    await seedSyncedBook();
    await runtimes.mutate('EditPage', [
      ModelUpdateOperation(
        model: 'FamilyMoment',
        id: momentId,
        patch: const {'caption': 'edited'},
      ),
    ]);

    await burnBook();

    // Not the optimistic caption: the held row is the only copy of truth.
    expect(
      (await family.moment.readBefore(momentId))?.fields['caption'],
      'a page',
    );
    // The descendant's own edit stays in the queue — cascade never touches it.
    expect(await family.moment.pendingMutations(momentId), hasLength(1));
    expect(await queueLength(), 2);
  });

  test('a descendant still waiting to be created holds no truth', () async {
    await family.space.create(spaceId, {'name': 'Everyday'});
    await runtimes.mutate('WritePage', [
      ModelCreateOperation(
        model: 'FamilyMoment',
        id: momentId,
        values: {'spaceId': spaceId.value, 'caption': 'unsent'},
      ),
    ]);

    await burnBook();

    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.moment.readBefore(momentId), isNull);
    // Its create is doomed, and the server's rejection is what settles it.
    expect(await family.moment.pendingMutations(momentId), hasLength(1));
  });

  test('a descendant deleted first is not copied aside twice', () async {
    await seedSyncedBook();
    await deletePage(momentId);
    final held = await family.moment.readBefore(momentId);

    await burnBook();

    expect(await family.moment.readBefore(momentId), held);
    expect(await family.photo.readMain(photoId), isNull);
  });

  test('another book is untouched', () async {
    await seedSyncedBook();
    await family.space.create(otherSpaceId, {'name': 'Other'});
    await family.moment.create(otherMomentId, {
      'spaceId': otherSpaceId.value,
      'caption': null,
    });

    await burnBook();

    expect(await family.space.readMain(otherSpaceId), isNotNull);
    expect(await family.moment.readMain(otherMomentId), isNotNull);
  });

  test('every touched table tells its watchers', () async {
    await seedSyncedBook();
    final photos = database.database.watchTables({'family_photo'});
    final moments = database.database.watchTables({'family_moment'});
    final ticks = <String>[];
    final photoTicks = photos.listen((_) => ticks.add('photo'));
    final momentTicks = moments.listen((_) => ticks.add('moment'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await burnBook();
    for (var attempt = 0; attempt < 40 && ticks.length < 2; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(ticks, containsAll(<String>['photo', 'moment']));
    await photoTicks.cancel();
    await momentTicks.cancel();
  });

  test('a Model with no children deletes exactly as it always did', () async {
    await seedSyncedBook();

    await runtimes.mutate('DeletePhoto', [
      ModelDeleteOperation(model: 'FamilyPhoto', id: photoId),
    ]);

    expect(await family.photo.readMain(photoId), isNull);
    expect(await family.photo.readBefore(photoId), isNotNull);
    expect(await queueLength(), 1);
    expect(await family.moment.readMain(momentId), isNotNull);
  });

  test('a failure part way through leaves nothing behind', () async {
    await seedSyncedBook();
    // The book is already gone from main, so the act's own delete finds no row
    // and fails — after the cascade has emptied its subtree. One `mutate` call
    // is one transaction, so the half-done cascade goes with it.
    await family.space.delete(spaceId);

    await expectLater(burnBook(), throwsA(isA<LocalStorageException>()));

    expect(await family.photo.readMain(photoId), isNotNull);
    expect(await family.moment.readMain(momentId), isNotNull);
    expect(await family.moment.readBefore(momentId), isNull);
    expect(await queueLength(), 0);
  });
}
