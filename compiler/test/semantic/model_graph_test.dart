import 'package:local_sync_compiler/src/semantic/model_graph.dart';
import 'package:test/test.dart';

void main() {
  test(
    'separates scalar fields from relations and freezes canonical Model order',
    () {
      const alpha = ModelSymbol('Alpha');
      const zebra = ModelSymbol('Zebra');
      const alphaId = FieldSymbol(model: alpha, name: 'id');
      const alphaZebraId = FieldSymbol(model: alpha, name: 'zebraId');
      const alphaZebra = RelationSymbol(model: alpha, name: 'zebra');
      const zebraId = FieldSymbol(model: zebra, name: 'id');
      final alphaFields = <ModelFieldDefinition>[
        const ModelFieldDefinition(
          symbol: alphaId,
          valueType: const ScalarValueType(ScalarType.uuid),
          nullable: false,
        ),
        const ModelFieldDefinition(
          symbol: alphaZebraId,
          valueType: const ScalarValueType(ScalarType.uuid),
          nullable: false,
        ),
      ];
      final alphaRelations = <RelationDefinition>[
        RelationDefinition(
          symbol: alphaZebra,
          target: zebra,
          localFields: const [alphaZebraId],
          referencedFields: const [zebraId],
          nullable: false,
          deleteOnTarget: true,
        ),
      ];
      final alphaDefinition = ModelDefinition(
        symbol: alpha,
        fields: alphaFields,
        identity: ModelIdentity(const [alphaId]),
        uniqueConstraints: const [],
        relations: alphaRelations,
      );
      final zebraDefinition = ModelDefinition(
        symbol: zebra,
        fields: const [
          ModelFieldDefinition(
            symbol: zebraId,
            valueType: const ScalarValueType(ScalarType.uuid),
            nullable: false,
          ),
        ],
        identity: ModelIdentity(const [zebraId]),
        uniqueConstraints: const [],
        relations: const [],
      );

      final graph = ModelGraph([zebraDefinition, alphaDefinition]);
      alphaFields.clear();
      alphaRelations.clear();

      expect(graph.models.map((model) => model.symbol.name), [
        'Alpha',
        'Zebra',
      ]);
      expect(graph.model(const ModelSymbol('Alpha')), same(alphaDefinition));
      expect(
        graph.field(const FieldSymbol(model: ModelSymbol('Alpha'), name: 'id')),
        same(alphaDefinition.fields.first),
      );
      expect(alphaDefinition.identity.fields, [alphaId]);
      expect(alphaDefinition.fields.map((field) => field.symbol.name), [
        'id',
        'zebraId',
      ]);
      expect(alphaDefinition.relations.single.localFields, [alphaZebraId]);
      expect(alphaDefinition.relations.single.target, zebra);
      expect(
        graph.relation(alphaZebra),
        same(alphaDefinition.relations.single),
      );
      expect(
        graph.relation(const RelationSymbol(model: alpha, name: 'zebra')),
        same(alphaDefinition.relations.single),
      );
      expect(alphaDefinition.fields, hasLength(2));
      expect(alphaDefinition.relations, hasLength(1));
      expect(() => graph.models.add(alphaDefinition), throwsUnsupportedError);
      expect(() => alphaDefinition.fields.clear(), throwsUnsupportedError);
      expect(() => alphaDefinition.relations.clear(), throwsUnsupportedError);
    },
  );
}
