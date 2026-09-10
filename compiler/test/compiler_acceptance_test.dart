import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  test(
    'compiles the conformance definition directory into a complete graph',
    () async {
      final graph = await compileModelDirectory('../conformance/definitions');

      expect(graph.models.map((model) => model.symbol.name), [
        'AccountState',
        'LocalNote',
        'Moment',
        'MomentLink',
        'ScalarSample',
        'Space',
        'Star',
        'StarTag',
        'User',
      ]);

      final user = graph.model(const ModelSymbol('User'));
      expect(user.identity.fields.single.name, 'id');
      expect(user.uniqueConstraints.single.fields.map((field) => field.name), [
        'handle',
      ]);

      final space = graph.model(const ModelSymbol('Space'));
      expect(space.fields.map((field) => field.symbol.name), [
        'id',
        'ownerId',
        'name',
        'kind',
        'avatarKey',
      ]);
      expect(
        space.fields[3].valueType,
        const EnumValueType(EnumSymbol('SpaceKind')),
      );
      expect(space.fields.last.nullable, isTrue);
      expect(space.fields.last.prerequisite!.prerequisite.name, 'RemoteLabel');
      expect(graph.prerequisites.single.symbol.name, 'RemoteLabel');
      expect(space.relations.map((relation) => relation.symbol.name), [
        'owner',
      ]);
      expect(space.relations.single.target, const ModelSymbol('User'));
      expect(space.relations.single.localFields.single.name, 'ownerId');
      expect(space.relations.single.referencedFields.single.name, 'id');
      expect(space.uniqueConstraints.single.fields.map((field) => field.name), [
        'ownerId',
        'name',
      ]);

      final moment = graph.model(const ModelSymbol('Moment'));
      expect(moment.fields.map((field) => field.symbol.name), [
        'id',
        'spaceId',
        'capturedAt',
        'caption',
      ]);
      expect(moment.relations.map((relation) => relation.symbol.name), [
        'space',
      ]);
      expect(moment.relations.single.deleteOnTarget, isTrue);

      final scalarSample = graph.model(const ModelSymbol('ScalarSample'));
      expect(scalarSample.fields.map((field) => field.valueType), [
        const ScalarValueType(ScalarType.uuid),
        const ScalarValueType(ScalarType.boolean),
        const ScalarValueType(ScalarType.int),
        const ScalarValueType(ScalarType.float),
        const ScalarValueType(ScalarType.dateTime),
        const ScalarValueType(ScalarType.uuid),
      ]);
      expect(scalarSample.fields.map((field) => field.nullable), [
        false,
        false,
        false,
        false,
        true,
        true,
      ]);

      final star = graph.model(const ModelSymbol('Star'));
      expect(star.fields.map((field) => field.symbol.name), [
        'userId',
        'momentId',
      ]);
      expect(star.fields.map((field) => field.valueType), [
        const ScalarValueType(ScalarType.uuid),
        const ScalarValueType(ScalarType.uuid),
      ]);
      expect(star.identity.fields.map((field) => field.name), [
        'userId',
        'momentId',
      ]);
      expect(star.relations.map((relation) => relation.symbol.name), [
        'user',
        'moment',
      ]);
      expect(star.relations.map((relation) => relation.deleteOnTarget), [
        false,
        false,
      ]);
      expect(star.uniqueConstraints, isEmpty);

      final starTag = graph.model(const ModelSymbol('StarTag'));
      // Two relations, one of them riding a field the other already uses —
      // the multi-parent shape slot bindings exercise (spec
      // 2026-08-16-slot-bindings).
      expect(starTag.relations.map((relation) => relation.symbol.name), [
        'star',
        'moment',
      ]);
      expect(starTag.relations.first.localFields.map((field) => field.name), [
        'userId',
        'momentId',
      ]);
      expect(
        starTag.relations.first.referencedFields.map((field) => field.name),
        ['userId', 'momentId'],
      );
      expect(starTag.relations.first.deleteOnTarget, isTrue);
      expect(starTag.relations.last.localFields.map((field) => field.name), [
        'momentId',
      ]);
      expect(starTag.relations.last.deleteOnTarget, isFalse);

      final accountState = graph.model(const ModelSymbol('AccountState'));
      expect(accountState.identity.fields.single.name, 'userId');
      expect(
        accountState.fields[1].valueType,
        const ScalarListValueType(ScalarType.uuid),
      );
      expect(accountState.relations.single.deleteOnTarget, isTrue);
      expect(graph.enums.map((definition) => definition.symbol.name), [
        'LocalNoteStatus',
        'SpaceKind',
      ]);
      expect(
        () => graph.model(const ModelSymbol('StarAudit')),
        throwsStateError,
      );
    },
  );

  test('rejects a source set with no Model definitions', () {
    expect(
      () =>
          compileModelSources({'models/empty.model': '// intentionally empty'}),
      throwsA(
        isA<CompilerException>().having(
          (error) => error.message,
          'message',
          'no Model definitions found',
        ),
      ),
    );
  });
}
