import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

/// The fixture graph the mutation goldens are read from: a page-shaped
/// composite (the 42-operation act), an update-and-delete act, a
/// single-slot act, and a composite-identity Model in a slot.
final _graph = compileModelSources({
  'moment.model': '''model Space {
  id UUID
  name String

  @@id(id)
}

model Moment {
  id         UUID
  spaceId    UUID
  caption    String?

  space Space @reference(via: [spaceId])

  @@id(id)
}

mutation CaptureMoment {
  moment Moment.create
  photos MomentPhoto.create[]
  star   Star.create

  @@sequence(after: [
    SetSpaceVisibility(space: moment.space),
    SetSpaceVisibility(space: photos.moment.space),
    SetSpaceVisibility(space: star.moment.space)
  ])
}

mutation ReviseMoment {
  moment        Moment.update<caption>
  removedPhotos MomentPhoto.delete[]
  addedPhotos   MomentPhoto.create[]
  star          Star.delete?

  @@sequence(after: [
    SetSpaceVisibility(space: star.moment.space)
  ])
}

mutation SetSpaceVisibility {
  space Space.update<name>
}
''',
  'photo.model': '''prerequisite RemoteObject(key String)

model MomentPhoto {
  id       UUID
  momentId UUID
  key      String @requires(RemoteObject(key: self))
  position Int

  moment Moment @reference(via: [momentId])

  @@id(id)
}
''',
  // Composite identity, and no field beyond it.
  'star.model': '''model Star {
  userId   UUID
  momentId UUID

  moment Moment @reference(via: [momentId])

  @@id(userId, momentId)
}
''',
  'draft.model': '''model Draft {
  id   UUID
  text String

  @@id(id)
}

mutation SaveDraft {
  draft Draft.create
}
''',
});

void main() {
  group('Dart', () {
    final output = emitDart(_graph);

    test('mutations reach their own file, and the facade exports it', () {
      expect(output.keys, contains('mutations.dart'));
      expect(output['local_sync.dart'], contains("export 'mutations.dart';"));
    });

    test('a create is static and builds its identity from components', () {
      expect(
        output['models/moment.dart'],
        allOf(
          contains('static MomentCreate create({'),
          contains('    required UUID id,'),
          contains('    required String? caption,'),
          contains('  }) => MomentCreate._('),
          contains('    id: MomentId(id),'),
          // Identity lives in the id; only the rest is state.
          contains("      'spaceId': spaceId,"),
          isNot(contains("      'id': id,")),
        ),
      );
    });

    test('a composite identity is spelled component by component', () {
      expect(
        output['models/star.dart'],
        allOf(
          contains('static StarCreate create({'),
          contains('    required UUID userId,'),
          contains('    required UUID momentId,'),
          contains(
            '    id: StarId(\n'
            '      userId: userId,\n'
            '      momentId: momentId,\n'
            '    ),',
          ),
        ),
      );
    });

    test('update and delete build values off a row that was read', () {
      // Members on the row itself: with the transaction row type gone
      // (CAP-444) nothing else spells these two verbs, so there is no clash
      // left for an extension to step around.
      expect(
        output['models/moment.dart'],
        allOf(
          contains('  MomentUpdate update({'),
          contains('    FieldUpdate<String?>? caption,'),
          contains("      if (caption != null) 'caption': caption.value,"),
          contains('  MomentDelete delete() => MomentDelete._(id: id);'),
          isNot(contains('extension MomentOperations')),
        ),
      );
    });

    test(
      'no row writes: the operation value is the only thing a row builds',
      () {
        expect(
          output['models/moment.dart'],
          allOf(
            isNot(contains('MutableMoment')),
            isNot(contains('Future<void> delete()')),
            isNot(contains('writeUpdate')),
          ),
        );
      },
    );

    test('one exact operation type per (Model, op) pair', () {
      expect(
        output['models/moment.dart'],
        allOf(
          contains('final class MomentCreate extends ModelCreateOperation {'),
          contains('final class MomentUpdate extends ModelUpdateOperation {'),
          contains('final class MomentDelete extends ModelDeleteOperation {'),
          contains("super(model: 'Moment', id: id, values: values)"),
        ),
      );
    });

    test('a mutation names one exact record type per slot', () {
      expect(
        output['mutations.dart'],
        contains(
          'typedef CaptureMomentResult = ({\n'
          '  MomentCreate moment,\n'
          '  List<MomentPhotoCreate> photos,\n'
          '  StarCreate star,\n'
          '});',
        ),
      );
    });

    test('an update slot owns a projected builder and operation type', () {
      expect(
        output['mutations.dart'],
        allOf(
          contains(
            'final class ReviseMomentMomentUpdate '
            'extends ModelUpdateOperation {',
          ),
          contains('final class ReviseMomentMomentSlot {'),
          contains('  const ReviseMomentMomentSlot();'),
          contains(
            '  ReviseMomentMomentUpdate update(\n'
            '    Moment row, {\n'
            '    FieldUpdate<String?>? caption,\n'
            '  }) {',
          ),
          contains("      if (caption != null) 'caption': caption.value,"),
          contains(
            '    if (patch.isEmpty) {\n'
            "      throw ArgumentError('mutation \"ReviseMoment\" slot "
            '"moment\" update requires at least one field\');\n'
            '    }',
          ),
          isNot(contains('    UUID? spaceId,')),
        ),
      );
    });

    test('an update mutation callback receives its generated scope', () {
      expect(
        output['mutations.dart'],
        allOf(
          contains(
            'final class ReviseMomentMutationScope {\n'
            '  const ReviseMomentMutationScope(this._scope);\n\n'
            '  final LocalSyncMutationScope<TransactionModels> _scope;\n\n'
            '  TransactionModels get models => _scope.models;\n'
            '  MutationScopes get scopes => _scope.scopes;\n'
            '  ReviseMomentMomentSlot get moment =>\n'
            '      const ReviseMomentMomentSlot();\n'
            '}',
          ),
          contains(
            'typedef ReviseMomentResult = ({\n'
            '  ReviseMomentMomentUpdate moment,\n'
            '  List<MomentPhotoDelete> removedPhotos,\n'
            '  List<MomentPhotoCreate> addedPhotos,\n'
            '  StarDelete? star,\n'
            '});',
          ),
          contains(
            '  Future<void> reviseMoment(\n'
            '    Future<ReviseMomentResult?> Function(\n'
            '      ReviseMomentMutationScope mutation,\n'
            '    ) build,\n'
            '  ) => _executor.run(\n'
            "    name: 'ReviseMoment',\n"
            '    build: (mutation) =>\n'
            '        build(ReviseMomentMutationScope(mutation)),\n'
            '    record: mutationRecords.reviseMoment,\n'
            '  );',
          ),
        ),
      );
    });

    test('a mutation is bound to an outer transaction', () {
      expect(
        output['mutations.dart'],
        contains(
          '  Future<void> captureMoment(\n'
          '    Future<CaptureMomentResult?> Function(\n'
          '      LocalSyncMutationScope<TransactionModels> mutation,\n'
          '    ) build,\n'
          '  ) => _executor.run(\n'
          "    name: 'CaptureMoment',\n"
          '    build: build,\n'
          '    record: mutationRecords.captureMoment,\n'
          '  );',
        ),
      );
      expect(
        output['mutations.dart'],
        contains(
          'final class TransactionMutations {\n'
          '  const TransactionMutations(this._executor);\n\n'
          '  final MutationScopeExecutor<TransactionModels> _executor;',
        ),
      );
      expect(
        output['local_sync.dart'],
        allOf(
          contains(
            'extends LocalSyncRuntime<Models, TransactionModels, '
            'TransactionMutations>',
          ),
          contains('transactionContexts: transactionContexts'),
          isNot(contains('late final Mutations mutate')),
        ),
      );
    });

    test('the old value-class spelling is gone', () {
      expect(
        output['mutations.dart'],
        allOf(
          isNot(contains('GeneratedMutation')),
          isNot(contains('extends GeneratedMutation')),
          isNot(contains('synced:')),
        ),
      );
    });

    test('slot operations flatten in declaration order and retain names', () {
      expect(
        output['mutations.dart'],
        contains(
          "        name: 'CaptureMoment',\n"
          '        version: 1,\n'
          '        slotOperations: [\n'
          "          MutationSlotOperation(slotName: 'moment', operation: result.moment),\n"
          '          for (final operation in result.photos)\n'
          "            MutationSlotOperation(slotName: 'photos', operation: operation),\n"
          "          MutationSlotOperation(slotName: 'star', operation: result.star),\n"
          '        ],',
        ),
      );
      expect(
        output['mutations.dart'],
        contains(
          '        slotOperations: [\n'
          "          MutationSlotOperation(slotName: 'moment', operation: result.moment, allowedPatchFields: const ['caption']),\n"
          '          for (final operation in result.removedPhotos)\n'
          "            MutationSlotOperation(slotName: 'removedPhotos', operation: operation),\n"
          '          for (final operation in result.addedPhotos)\n'
          "            MutationSlotOperation(slotName: 'addedPhotos', operation: operation),\n"
          '          if (result.star != null)\n'
          "            MutationSlotOperation(slotName: 'star', operation: result.star!),\n"
          '        ],',
        ),
      );
    });

    test('sequence selectors bind concrete single list and optional paths', () {
      expect(
        output['mutations.dart'],
        contains(
          '        sequenceSelectors: [\n'
          '          MutationSequenceSelector(\n'
          "            predecessorMutation: 'SetSpaceVisibility',\n"
          "            predecessorSlot: 'space',\n"
          '            predecessorRelations: const [],\n'
          '            currentPaths: [\n'
          '              MutationSequenceCurrentPath(\n'
          '                source: result.moment,\n'
          "                relations: const ['space'],\n"
          '              ),\n'
          '            ],\n'
          '          ),\n'
          '          MutationSequenceSelector(\n'
          "            predecessorMutation: 'SetSpaceVisibility',\n"
          "            predecessorSlot: 'space',\n"
          '            predecessorRelations: const [],\n'
          '            currentPaths: [\n'
          '              for (final operation in result.photos)\n'
          '                MutationSequenceCurrentPath(\n'
          '                  source: operation,\n'
          "                  relations: const ['moment', 'space'],\n"
          '                ),\n'
          '            ],\n'
          '          ),\n',
        ),
      );
      expect(
        output['mutations.dart'],
        contains(
          '            currentPaths: [\n'
          '              if (result.star != null)\n'
          '                MutationSequenceCurrentPath(\n'
          '                  source: result.star!,\n'
          "                  relations: const ['moment', 'space'],\n"
          '                ),\n'
          '            ],\n'
          '          ),\n',
        ),
      );
    });

    test('an optional slot is a nullable record field', () {
      expect(output['mutations.dart'], contains('  StarDelete? star,\n'));
    });

    test('every declared mutation is a wire act', () {
      expect(
        output['mutations.dart'],
        contains(
          "        name: 'SaveDraft',\n"
          '        version: 1,\n'
          '        slotOperations: [\n'
          "          MutationSlotOperation(slotName: 'draft', operation: result.draft),\n"
          '        ],',
        ),
      );
    });
  });

  group('TypeScript', () {
    final contract = buildBackendContract(_graph);
    final source = emitBackendTypescript(contract).backendContract;

    test('historical per-slot payload types embed resolved field rules', () {
      expect(
        source,
        contains('export type CaptureMomentV1Arguments = Readonly<{'),
      );
      expect(
        source,
        contains(
          'moment: Readonly<{ identity: Readonly<{ id: string; }>; data: Readonly<{ caption: string | null; spaceId: string; }>; }>;',
        ),
      );
      expect(source, contains('patch: Readonly<{ caption?: string | null; }>'));
      expect(source, contains('photos: readonly Readonly<'));
      expect(source, contains('}> | null;'));
      expect(
        source.substring(
          source.indexOf('export type CaptureMomentV1Arguments'),
        ),
        isNot(contains('data: MomentCreateData')),
      );
    });
    test('each mutation requires its retained version handlers', () {
      expect(source, contains('captureMoment: Readonly<{'));
      expect(source, contains('v1: CaptureMomentV1Arguments;'));
      expect(source, contains('v1: SaveDraftV1Arguments;'));
      expect(source, contains('[V in keyof GeneratedMutationArguments[K]]'));
    });
    test('version descriptors preserve ordered slots and projections', () {
      expect(
        source,
        contains(
          '"slots":[{"name":"moment","model":"Moment","operation":"create","cardinality":"single"},{"name":"photos","model":"MomentPhoto","operation":"create","cardinality":"list"},{"name":"star","model":"Star","operation":"create","cardinality":"single"}]',
        ),
      );
      expect(source, contains('"allowedPatchFields":["caption"]'));
      expect(source, contains('"name":"CaptureMoment","version":1'));
      expect(source, contains('forward: forwardCaptureMomentV1'));
    });

    test('sequence metadata never enters the Backend contract', () {
      expect(source, isNot(contains('sequencePaths')));
      expect(source, isNot(contains('sequenceSelectors')));
      expect(source, isNot(contains("relations: ['moment', 'space']")));
    });
  });

  group('slot bindings', () {
    // The wired fixture (spec 2026-08-16-slot-bindings): a list slot, a
    // single multi-parent slot, and an optional bound slot.
    final graph = compileModelSources({
      'wired.model': '''model Moment {
  id UUID

  @@id(id)
}

model MomentPhoto {
  id       UUID
  momentId UUID
  moment   Moment @reference(via: [momentId])

  @@id(id)
}

model Star {
  userId   UUID
  momentId UUID
  moment   Moment @reference(via: [momentId])

  @@id(userId, momentId)
}

model StarTag {
  id           UUID
  starUserId   UUID
  starMomentId UUID
  momentId     UUID
  star         Star @reference(via: [starUserId, starMomentId])
  moment       Moment @reference(via: [momentId])

  @@id(id)
}

mutation CaptureMoment {
  moment Moment.create
  photos MomentPhoto.create(moment: moment)[]
  cover  MomentPhoto.create(moment: moment)?
  star   Star.create(moment: moment)
  tag    StarTag.create(star: star, moment: moment)
}
''',
    });

    test('generated Dart states bindings as facts on the record', () {
      final output = emitDart(graph)['mutations.dart'];
      expect(
        output,
        contains(
          '        bindings: [\n'
          '          for (final operation in result.photos) ...[\n'
          "            SlotBinding(operation: operation, fields: const "
          "['momentId'], parent: result.moment),\n"
          '          ],\n'
          "          if (result.cover != null) SlotBinding(operation: "
          "result.cover!, fields: const ['momentId'], "
          'parent: result.moment),\n'
          "          SlotBinding(operation: result.star, fields: const "
          "['momentId'], parent: result.moment),\n"
          "          SlotBinding(operation: result.tag, fields: const "
          "['starUserId', 'starMomentId'], parent: result.star),\n"
          "          SlotBinding(operation: result.tag, fields: const "
          "['momentId'], parent: result.moment),\n"
          '        ],',
        ),
      );
    });

    test('an unbound slot emits no bindings entry at all', () {
      final unbound = compileModelSources({
        'plain.model': '''model Moment {
  id UUID
  caption String?

  @@id(id)
}

mutation TouchMoment {
  moment Moment.update<caption>
}
''',
      });
      expect(emitDart(unbound)['mutations.dart'], isNot(contains('bindings:')));
    });

    test('the Backend contract carries each slot\'s bindings', () {
      final source = emitBackendTypescript(
        buildBackendContract(graph),
      ).backendContract;
      expect(
        source,
        contains(
          '"bindings":[{"relation":"moment","fields":["momentId"],"slot":"moment"}]',
        ),
      );
      expect(
        source,
        contains(
          '"bindings":[{"relation":"star","fields":["starUserId","starMomentId"],"slot":"star"},{"relation":"moment","fields":["momentId"],"slot":"moment"}]',
        ),
      );
    });
  });
}
