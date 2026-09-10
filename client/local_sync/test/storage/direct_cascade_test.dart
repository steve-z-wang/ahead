import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

/// The Model schema decides what a delete MEANS; the write path decides only
/// whether the operation is synchronized (CAP-488).
///
/// So a direct transaction delete walks the same `onTargetDelete: delete`
/// graph a named act does — deepest first, in one SQLite transaction — and
/// respect only: nothing local will undo it, so each descendant ends holding
/// no truth rather than holding it aside for a rejection.
void main() {
  late TestLocalDatabase database;
  late FamilyRegistry family;
  late FamilyRuntimes runtimes;

  final spaceId = FamilySpaceId(familyUuid(1));
  final otherSpaceId = FamilySpaceId(familyUuid(2));
  final momentId = FamilyMomentId(familyUuid(10));
  final otherMomentId = FamilyMomentId(familyUuid(11));
  final photoId = FamilyPhotoId(familyUuid(20));
  final cropId = FamilyCropId(familyUuid(30));
  final tagId = FamilyTagId(familyUuid(40));
  final memberId = FamilyMemberId(
    spaceId: spaceId.value,
    userId: familyUuid(50),
  );

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    runtimes = FamilyRuntimes(database.scope, family.registry);
  });

  tearDown(() => database.close());

  /// A book with a page, its photo, that photo's crop, a member, and a tag
  /// that imposes nothing — plus a second book nothing here touches.
  Future<void> seedBook() async {
    await family.space.create(spaceId, {'name': 'Everyday'});
    await family.space.create(otherSpaceId, {'name': 'Untouched'});
    await family.moment.create(momentId, {
      'spaceId': spaceId.value,
      'caption': 'a page',
    });
    await family.moment.create(otherMomentId, {
      'spaceId': otherSpaceId.value,
      'caption': 'elsewhere',
    });
    await family.photo.create(photoId, {
      'momentId': momentId.value,
      'key': 'k',
    });
    await family.crop.create(cropId, {'photoId': photoId.value});
    await family.member.create(memberId, {'role': 'owner'});
    // Declared without onTargetDelete, so the walk must step over it.
    await family.tag.create(tagId, {'momentId': momentId.value});
  }

  Future<int> countQueued() async {
    final result = await database.scope.current.query(
      DatabaseQuery(
        sql: 'SELECT COUNT(*) AS count FROM pending_mutation_operations',
      ),
    );
    return result.rows.single['count']! as int;
  }

  Future<int> countRecords() async {
    final result = await database.scope.current.query(
      DatabaseQuery(sql: 'SELECT COUNT(*) AS count FROM pending_mutations'),
    );
    return result.rows.single['count']! as int;
  }

  test('a direct delete takes the whole declared subtree', () async {
    await seedBook();

    await runtimes.write((models) => models.space.delete(spaceId));

    // Every row the schema says falls with the book, however deep.
    expect(await family.space.readMain(spaceId), isNull);
    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.photo.readMain(photoId), isNull);
    expect(await family.crop.readMain(cropId), isNull);
    expect(await family.member.readMain(memberId), isNull);
  });

  test('it takes nothing the schema did not name', () async {
    await seedBook();

    await runtimes.write((models) => models.space.delete(spaceId));

    // The tag hangs off the deleted page and imposes nothing, so it stays —
    // as does the whole of the other book.
    expect(await family.tag.readMain(tagId), isNotNull);
    expect(await family.space.readMain(otherSpaceId), isNotNull);
    expect(await family.moment.readMain(otherMomentId), isNotNull);
  });

  test('it creates no queue work at all', () async {
    await seedBook();

    await runtimes.write((models) => models.space.delete(spaceId));

    // The whole point of the lane: a schema cascade is not a reason to send
    // anything, and neither is the delete that started it.
    expect(await countQueued(), 0);
    expect(await countRecords(), 0);
  });

  test('a descendant holds no truth, so nothing can restore it', () async {
    await seedBook();

    await runtimes.write((models) => models.space.delete(spaceId));

    for (final absent in [
      await family.photo.readBefore(photoId),
      await family.crop.readBefore(cropId),
      await family.member.readBefore(memberId),
    ]) {
      expect(absent, isNull);
    }
  });

  test('a rejected edit does not resurrect a directly deleted row', () async {
    await seedBook();
    // The page is being edited when the book is burned locally.
    await runtimes.mutate('EditPage', [
      ModelUpdateOperation(
        model: 'FamilyMoment',
        id: momentId,
        patch: {'caption': 'edited'},
      ),
    ]);

    await runtimes.write((models) => models.space.delete(spaceId));

    // The refusal removes the edit's optimism. It has no truth to rebuild
    // from — the final delete made nonexistence the truth — so the row stays
    // gone rather than coming back holding the value the act found.
    await database.scope.current.execute(
      DatabaseStatement(sql: 'DELETE FROM pending_mutations'),
    );
    await family.moment.rebuild(momentId);

    expect(await family.moment.readMain(momentId), isNull);
    expect(await family.moment.readBefore(momentId), isNull);
  });

  test('a failing write rolls the whole cascade back', () async {
    await seedBook();

    await expectLater(
      runtimes.write((models) async {
        await models.space.delete(spaceId);
        throw StateError('no');
      }),
      throwsStateError,
    );

    // One transaction, so the subtree either goes or none of it does.
    expect(await family.space.readMain(spaceId), isNotNull);
    expect(await family.moment.readMain(momentId), isNotNull);
    expect(await family.photo.readMain(photoId), isNotNull);
    expect(await family.crop.readMain(cropId), isNotNull);
    expect(await family.member.readMain(memberId), isNotNull);
  });

  test('a queued delete still holds its subtree aside', () async {
    await seedBook();

    await runtimes.mutate('BurnBook', [
      ModelDeleteOperation(model: 'FamilySpace', id: spaceId),
    ]);

    // The other lane is untouched: its cascade is provisional, so every
    // descendant keeps the truth a rejection restores it from.
    expect(await family.photo.readMain(photoId), isNull);
    expect(await family.photo.readBefore(photoId), isNotNull);
    expect(await family.crop.readBefore(cropId), isNotNull);
    expect(await family.member.readBefore(memberId), isNotNull);
  });
}
