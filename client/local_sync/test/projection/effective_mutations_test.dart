import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late FamilyRegistry family;
  late EffectiveMutations<FamilyMomentId> momentEffective;

  final spaceId = FamilySpaceId(familyUuid(1));
  final momentId = FamilyMomentId(familyUuid(10));
  final photoId = FamilyPhotoId(familyUuid(20));
  final memberId = FamilyMemberId(
    spaceId: familyUuid(1),
    userId: familyUuid(40),
  );

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    // Building the registry is what hands each entry the graph.
    family.registry;
    momentEffective = EffectiveMutations<FamilyMomentId>(
      registry: family.registry,
      entry: family.moment,
      own: family.moment.mutations,
    );
  });

  tearDown(() => database.close());

  Future<void> seedSpace() => family.space.create(spaceId, {'name': 'a book'});
  Future<void> seedMoment() => family.moment.create(momentId, {
    'spaceId': spaceId.value,
    'caption': null,
  });

  /// One queued operation, and the named record it belongs to — every queued
  /// write is a letter of some act (CAP-444).
  Future<MutationPosition> queue(
    TypedModelRegistryEntry<ModelId> entry,
    ModelId id,
    MutationOperation operation, [
    Map<String, Object?> values = const {},
  ]) async => entry.mutations.append(
    id: id,
    operation: operation,
    values: values,
    mutationOrdinal: await database.queueRecord(),
    wire: true,
  );

  Future<MutationPosition> queueDelete(
    TypedModelRegistryEntry<ModelId> entry,
    ModelId id,
  ) => queue(entry, id, MutationOperation.delete);

  test('a row with no pending ancestor keeps exactly its own edits', () async {
    await seedSpace();
    await seedMoment();
    final ordinal = await queue(
      family.moment,
      momentId,
      MutationOperation.update,
      {'caption': 'edited'},
    );

    final effective = await momentEffective.read(momentId);

    expect(effective, hasLength(1));
    expect(effective.single.position, ordinal);
    expect(effective.single.operation, MutationOperation.update);
    expect(effective.single.inherited, isFalse);
  });

  test('inherits its parent\'s pending delete, at that ordinal', () async {
    await seedSpace();
    await seedMoment();
    final own = await queue(family.moment, momentId, MutationOperation.update, {
      'caption': 'edited',
    });
    final parentOrdinal = await queueDelete(family.space, spaceId);

    final effective = await momentEffective.read(momentId);

    expect(effective.map((mutation) => mutation.position), [
      own,
      parentOrdinal,
    ]);
    final inherited = effective.last;
    expect(inherited.operation, MutationOperation.delete);
    expect(inherited.inherited, isTrue);
    expect(inherited.id, momentId);
  });

  test('inherits through two levels', () async {
    await seedSpace();
    await seedMoment();
    await family.photo.create(photoId, {
      'momentId': momentId.value,
      'key': 'k',
    });
    final parentOrdinal = await queueDelete(family.space, spaceId);

    final effective = await EffectiveMutations<FamilyPhotoId>(
      registry: family.registry,
      entry: family.photo,
      own: family.photo.mutations,
    ).read(photoId);

    expect(effective, hasLength(1));
    expect(effective.single.position, parentOrdinal);
    expect(effective.single.operation, MutationOperation.delete);
    expect(effective.single.inherited, isTrue);
  });

  test('a parent edit that is not a delete is not inherited', () async {
    await seedSpace();
    await seedMoment();
    await queue(family.space, spaceId, MutationOperation.update, {
      'name': 'renamed',
    });

    expect(await momentEffective.read(momentId), isEmpty);
  });

  test('reads its foreign key from held truth once main is empty', () async {
    await seedSpace();
    await seedMoment();
    // The row has already been deleted locally: truth aside, main empty.
    await family.moment.replaceTruth(momentId, {
      'spaceId': spaceId.value,
      'caption': null,
    });
    await family.moment.delete(momentId);
    final parentOrdinal = await queueDelete(family.space, spaceId);

    final effective = await momentEffective.read(momentId);

    expect(effective.single.position, parentOrdinal);
    expect(effective.single.inherited, isTrue);
  });

  test('resolves a parent named by an identity component', () async {
    await seedSpace();
    await family.member.create(memberId, {'role': 'owner'});
    final parentOrdinal = await queueDelete(family.space, spaceId);

    final effective = await EffectiveMutations<FamilyMemberId>(
      registry: family.registry,
      entry: family.member,
      own: family.member.mutations,
    ).read(memberId);

    expect(effective.single.position, parentOrdinal);
    expect(effective.single.inherited, isTrue);
  });

  test('a row absent from both tables inherits nothing', () async {
    await seedSpace();
    await queueDelete(family.space, spaceId);

    expect(await momentEffective.read(momentId), isEmpty);
  });
}
