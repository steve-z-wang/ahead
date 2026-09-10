import 'package:local_sync/local_sync.dart' show ModelRelationCardinality;
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

/// CAP-437 over the generated definitions: a relation is declared in two
/// directions, and both survive generation as separate, named facts.
///
/// `MomentLink` exists for this test alone. It is the one shape the pairing
/// rules cannot infer — two relations between the same pair of Models — so it
/// is the one shape that has to be proved rather than reasoned about.
void main() {
  test('keeps two relations between one pair of Models apart', () {
    final references = {
      for (final relation in momentLinkSchema.relations)
        relation.name: relation,
    };

    expect(references.keys, ['source', 'target']);
    expect(references['source']!.relationName, 'MomentLinkSource');
    expect(references['source']!.localFields, ['sourceId']);
    expect(references['target']!.relationName, 'MomentLinkTarget');
    expect(references['target']!.localFields, ['targetId']);
    for (final relation in references.values) {
      expect(relation.targetModel, 'Moment');
      expect(relation.referencedFields, ['id']);
    }

    final inverses = {
      for (final inverse in momentSchema.inverseRelations)
        inverse.name: inverse,
    };
    expect(inverses['outgoingLinks']!.relationName, 'MomentLinkSource');
    expect(inverses['outgoingLinks']!.reference, 'source');
    expect(inverses['incomingLinks']!.relationName, 'MomentLinkTarget');
    expect(inverses['incomingLinks']!.reference, 'target');
    for (final name in ['outgoingLinks', 'incomingLinks']) {
      expect(inverses[name]!.sourceModel, 'MomentLink');
      expect(inverses[name]!.cardinality, ModelRelationCardinality.many);
    }
  });

  test('gives a reverse half no column and no field of its own', () {
    // The graph reads both ways; the storage only ever held one. Every reverse
    // half on Moment is absent from its fields, and the keys they are read
    // through live on the Models that declared them.
    for (final inverse in momentSchema.inverseRelations) {
      expect(
        momentSchema.fieldsByName,
        isNot(contains(inverse.name)),
        reason: inverse.name,
      );
    }
    expect(momentSchema.fieldsByName.keys, [
      'id',
      'spaceId',
      'capturedAt',
      'caption',
    ]);
    expect(momentLinkSchema.fieldsByName.keys, ['id', 'sourceId', 'targetId']);
  });
}
