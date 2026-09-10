import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/cascade_family.dart';
import '../support/test_database.dart';

void main() {
  late TestLocalDatabase database;
  late FamilyRegistry family;
  late RelationIndex index;

  setUp(() async {
    database = await TestLocalDatabase.open(
      modelStatements: familyModelStatements,
    );
    family = FamilyRegistry(database.scope);
    index = RelationIndex.of(family.registry);
  });

  tearDown(() => database.close());

  test('inverts a relation into its target', () {
    // The crop is the leaf of the family's chain, so nothing points at it.
    expect(index.incoming('FamilyCrop'), isEmpty);
    expect(
      index.incoming('FamilyPhoto').map((relation) => relation.source),
      <ModelRegistryEntry>[family.crop],
    );

    final momentIncoming = index.incoming('FamilyMoment');
    expect(
      momentIncoming.map((relation) => relation.source),
      containsAll(<ModelRegistryEntry>[family.photo, family.tag]),
    );
  });

  test('carries relations that impose neither rule', () {
    final tagEdge = index
        .incoming('FamilyMoment')
        .singleWhere((relation) => identical(relation.source, family.tag));
    expect(tagEdge.relation.deleteOnTarget, isFalse);
    expect(tagEdge.relation.localFields, ['momentId']);
    expect(tagEdge.relation.referencedFields, ['id']);
  });

  test('collects every source pointing at one target', () {
    // The star imposes nothing and is carried all the same: the index is the
    // whole graph, and the filtering belongs to whoever walks it.
    expect(
      index.incoming('FamilySpace').map((relation) => relation.source),
      unorderedEquals(<ModelRegistryEntry>[
        family.moment,
        family.member,
        family.star,
      ]),
    );
  });

  test('carries both references an association declares', () {
    final edges = index
        .incoming('FamilyMoment')
        .where((relation) => identical(relation.source, family.star));
    expect(edges.single.relation.localFields, ['momentId']);
    expect(
      index
          .incoming('FamilySpace')
          .singleWhere((relation) => identical(relation.source, family.star))
          .relation
          .localFields,
      ['spaceId'],
    );
  });

  test('a Model nothing points at has no incoming relations', () {
    expect(index.incoming('FamilyTag'), isEmpty);
  });

  test('an unknown Model name has no incoming relations', () {
    expect(index.incoming('Nowhere'), isEmpty);
  });
}
