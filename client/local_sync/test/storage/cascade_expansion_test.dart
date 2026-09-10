import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late FamilyRegistry family;
  late CascadeExpansion expansion;

  final spaceId = FamilySpaceId(familyUuid(1));
  final otherSpaceId = FamilySpaceId(familyUuid(2));
  final momentId = FamilyMomentId(familyUuid(10));
  final otherMomentId = FamilyMomentId(familyUuid(11));
  final photoId = FamilyPhotoId(familyUuid(20));
  final tagId = FamilyTagId(familyUuid(30));
  final memberId = FamilyMemberId(
    spaceId: familyUuid(1),
    userId: familyUuid(40),
  );

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    expansion = CascadeExpansion(RelationIndex.of(family.registry));
  });

  tearDown(() => database.close());

  Future<void> seedSpace(FamilySpaceId id) =>
      family.space.create(id, {'name': 'a book'});

  Future<void> seedMoment(FamilyMomentId id, FamilySpaceId parent) =>
      family.moment.create(id, {'spaceId': parent.value, 'caption': null});

  Future<void> seedPhoto(FamilyPhotoId id, FamilyMomentId parent) =>
      family.photo.create(id, {'momentId': parent.value, 'key': 'k'});

  /// Puts the row in the before table only — what a locally deleted row looks
  /// like once its truth has been held aside and main has been emptied.
  Future<void> holdMomentAside(FamilyMomentId id, FamilySpaceId parent) async {
    await family.moment.replaceTruth(id, {
      'spaceId': parent.value,
      'caption': null,
    });
  }

  List<String> names(List<(ModelRegistryEntry, ModelId)> found) => [
    for (final (entry, id) in found) '${entry.schema.name}:$id',
  ];

  test('walks the declared cascade edges, children first', () async {
    await seedSpace(spaceId);
    await seedMoment(momentId, spaceId);
    await seedPhoto(photoId, momentId);

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(names(found), ['FamilyPhoto:$photoId', 'FamilyMoment:$momentId']);
  });

  test('sweeps every child of one parent', () async {
    final otherPhotoId = FamilyPhotoId(familyUuid(21));
    await seedSpace(spaceId);
    await seedMoment(momentId, spaceId);
    await seedPhoto(photoId, momentId);
    await seedPhoto(otherPhotoId, momentId);

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(found, hasLength(3));
    expect(
      found.map((found) => found.$2),
      containsAll(<ModelId>[photoId, otherPhotoId, momentId]),
    );
  });

  test('steps over a relation that declares no referential action', () async {
    await seedSpace(spaceId);
    await seedMoment(momentId, spaceId);
    await family.tag.create(tagId, {'momentId': momentId.value});

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(names(found), ['FamilyMoment:$momentId']);
  });

  test('resolves a composite-identity child', () async {
    await seedSpace(spaceId);
    await family.member.create(memberId, {'role': 'owner'});

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(names(found), ['FamilyMember:$memberId']);
  });

  test('finds a child that survives only in the before table', () async {
    await seedSpace(spaceId);
    await holdMomentAside(momentId, spaceId);

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(names(found), ['FamilyMoment:$momentId']);
  });

  test('a child in both tables is returned once', () async {
    await seedSpace(spaceId);
    await seedMoment(momentId, spaceId);
    await holdMomentAside(momentId, spaceId);

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(names(found), ['FamilyMoment:$momentId']);
  });

  test('scans only the side it was asked for', () async {
    await seedSpace(spaceId);
    await seedMoment(momentId, spaceId);
    await holdMomentAside(otherMomentId, spaceId);

    expect(
      names(
        await expansion.descendantsOf(
          family.space,
          spaceId,
          sources: CascadeScanSource.main,
        ),
      ),
      ['FamilyMoment:$momentId'],
    );
    expect(
      names(
        await expansion.descendantsOf(
          family.space,
          spaceId,
          sources: CascadeScanSource.before,
        ),
      ),
      ['FamilyMoment:$otherMomentId'],
    );
  });

  test('leaves another parent\'s children alone', () async {
    await seedSpace(spaceId);
    await seedSpace(otherSpaceId);
    await seedMoment(momentId, spaceId);
    await seedMoment(otherMomentId, otherSpaceId);
    await seedPhoto(photoId, otherMomentId);

    final found = await expansion.descendantsOf(
      family.space,
      spaceId,
      sources: CascadeScanSource.mainAndBefore,
    );

    expect(names(found), ['FamilyMoment:$momentId']);
  });

  test('a Model with no cascade children expands to nothing', () async {
    await seedSpace(spaceId);
    await seedMoment(momentId, spaceId);
    await seedPhoto(photoId, momentId);

    expect(
      await expansion.descendantsOf(
        family.photo,
        photoId,
        sources: CascadeScanSource.mainAndBefore,
      ),
      isEmpty,
    );
  });
}
