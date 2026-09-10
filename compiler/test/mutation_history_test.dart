import 'dart:io';
import 'package:local_sync_compiler/src/cli.dart';
import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

ModelGraph graph({
  int version = 1,
  String fields = 'text String?',
  String slot = 'item Item.create',
}) => compileModelSources({
  'test.model':
      'model Item { id UUID $fields @@id(id) } mutation Add { $slot @@version($version) }',
});
void main() {
  test(
    'retained prerequisites must keep their handler declaration and signature',
    () {
      ModelGraph schema(String declaration, int version, String field) =>
          compileModelSources({
            'test.model':
                '$declaration model Item { id UUID $field @@id(id) } '
                'mutation Add { item Item.create @@version($version) }',
          });
      final original = MutationHistory.capture(
        schema(
          'prerequisite Upload(key String)',
          1,
          'key String @requires(Upload(key: self))',
        ),
      );
      for (final declaration in [
        '',
        'prerequisite Upload(key UUID)',
        'prerequisite Upload(blob String)',
        'prerequisite Upload(key String, extra String)',
      ]) {
        expect(
          () => original.reconcile(schema(declaration, 2, 'text String')),
          throwsA(isA<CompilerException>()),
        );
      }
      expect(
        original
            .reconcile(
              schema('prerequisite Upload(key String)', 2, 'text String'),
            )
            .mutations['Add']!
            .keys,
        ['1', '2'],
      );
    },
  );

  test('update and delete retain only fields their slots consume', () {
    ModelGraph schema(String unrelated, String slots) => compileModelSources({
      'test.model':
          'enum State { one two } prerequisite Remote(key String) model Item { id UUID text String $unrelated @@id(id) } mutation Change { $slots }',
    });
    for (final slot in ['item Item.update<text>', 'item Item.delete']) {
      final original = MutationHistory.capture(
        schema('state State key String @requires(Remote(key: self))', slot),
      );
      final changed = original.reconcile(schema('count Int', slot));
      expect(changed.mutations['Change']!.keys, ['1']);
      final input = (changed.mutations['Change']!['1'] as Map)['input'] as Map;
      expect(input['enumValues'], isEmpty);
      final fields =
          ((input['models'] as Map)['item'] as Map)['fields'] as List;
      expect(
        fields.map((f) => (f as Map)['name']),
        slot.contains('update') ? ['id', 'text'] : ['id'],
      );
    }
  });
  test(
    'multiple update slots union projections and widening remains compatible',
    () {
      ModelGraph schema(String slots) =>
          graph(fields: 'text String count Int', slot: slots);
      final original = MutationHistory.capture(
        schema('item Item.update<text>'),
      );
      final widened = original.reconcile(
        schema('item Item.update<text, count>'),
      );
      expect(widened.mutations, isNotEmpty);
      final union = MutationHistory.capture(
        schema('item Item.update<text> other Item.update<count>'),
      );
      final fields =
          union.mutations['Add']!['1']['input']['models']['item']['fields']
              as List;
      expect(fields.map((f) => f['name']), ['count', 'id', 'text']);
      final creates = MutationHistory.capture(
        schema('item Item.create other Item.update<text>'),
      );
      expect(
        () => creates.reconcile(
          graph(
            fields: 'text String count Int extra Int',
            slot: 'item Item.create other Item.update<text>',
          ),
        ),
        throwsA(isA<CompilerException>()),
      );
    },
  );
  test('current model operation exports remain available beside frozen inputs', () {
    final schema = graph();
    final source = emitBackendTypescript(
      buildBackendContract(schema),
    ).backendContract;
    expect(
      source,
      contains(
        'export type ItemCreateOperation = Readonly<{\n  identity: ItemIdentity;\n  data: ItemCreateData;\n}>;',
      ),
    );
    expect(
      source,
      contains(
        'export type ItemUpdateOperation = Readonly<{\n  identity: ItemIdentity;\n  patch: ItemPatch;\n}>;',
      ),
    );
    expect(
      source,
      contains(
        'export type ItemDeleteOperation = Readonly<{\n  identity: ItemIdentity;\n}>;',
      ),
    );
    final historicalArgs = source.substring(
      source.indexOf('export type AddV1Arguments'),
    );
    expect(historicalArgs, isNot(contains('ItemCreateData')));
  });
  test(
    'CLI requires explicit initialization and shares history between consumers',
    () async {
      final root = await Directory.systemTemp.createTemp('mutation-history-');
      addTearDown(() => root.delete(recursive: true));
      final definitions = Directory('${root.path}/models')..createSync();
      final schema = File('${definitions.path}/item.model')
        ..writeAsStringSync(
          'model Item { id UUID text String? @@id(id) } mutation Add { item Item.create }',
        );
      final path = '${root.path}/mutation-contract.json';
      final arguments = [
        '--definitions',
        definitions.path,
        '--mutation-history',
        path,
        '--dart-out',
        '${root.path}/dart',
      ];
      await expectLater(
        runLocalSyncCompiler(arguments),
        throwsA(isA<CompilerException>()),
      );
      await runLocalSyncCompiler([
        ...arguments,
        '--initialize-mutation-history',
      ]);
      final first = File(path).readAsStringSync();
      await expectLater(
        runLocalSyncCompiler([...arguments, '--initialize-mutation-history']),
        throwsA(isA<CompilerException>()),
      );
      await runLocalSyncCompiler([
        '--definitions',
        definitions.path,
        '--mutation-history',
        path,
        '--typescript-backend-out',
        '${root.path}/typescript',
      ]);
      expect(File(path).readAsStringSync(), first);
      schema.writeAsStringSync(
        'model Item { id UUID text Int @@id(id) } mutation Add { item Item.create @@version(2) }',
      );
      await runLocalSyncCompiler(arguments);
      expect(
        MutationHistory.decode(
          File(path).readAsStringSync(),
        ).mutations['Add']!.keys,
        ['1', '2'],
      );
      File(path).deleteSync();
      await expectLater(
        runLocalSyncCompiler(arguments),
        throwsA(isA<CompilerException>()),
      );
      await expectLater(
        runLocalSyncCompiler([...arguments, '--initialize-mutation-history']),
        throwsA(isA<CompilerException>()),
      );
    },
  );
  test(
    'enum narrowing and update projection narrowing require a new version',
    () {
      ModelGraph schema(
        String values,
        String projection,
      ) => compileModelSources({
        'test.model':
            'enum State { $values } model Item { id UUID state State? text String? @@id(id) } mutation Edit { item Item.update<$projection> }',
      });
      final old = MutationHistory.capture(schema('one two', 'state, text'));
      expect(
        old.reconcile(schema('one two three', 'state, text')).mutations,
        isNotEmpty,
      );
      expect(
        () => old.reconcile(schema('one', 'state, text')),
        throwsA(isA<CompilerException>()),
      );
      expect(
        () => old.reconcile(schema('one two', 'state')),
        throwsA(isA<CompilerException>()),
      );
    },
  );
  test('retains historical inputs independent of current models', () {
    final old = MutationHistory.capture(graph());
    final current = graph(version: 2, fields: 'text Int required String');
    final history = old.reconcile(current);
    expect(history.mutations['Add']!.keys, ['1', '2']);
    final types = emitBackendTypescript(
      buildBackendContract(current),
      history: history,
    ).backendContract;
    expect(types, contains('text: string | null'));
    expect(types, contains('text: number'));
    expect(types, contains('v1: AddV1Arguments'));
    expect(types, contains('v2: AddV2Arguments'));
    expect(
      types.substring(types.indexOf('export type AddV1Arguments')),
      isNot(contains('data: ItemCreateData')),
    );
    expect(
      emitDart(current, history: history)['mutations.dart'],
      contains('version: 2'),
    );
    final metadata = emitDart(
      current,
      history: history,
    )['mutation_input_contracts.dart']!;
    expect(metadata, contains('1: '));
    expect(metadata, contains('2: '));
  });
  test(
    'active version accepts optional additions but rejects input breaks',
    () {
      final history = MutationHistory.capture(graph());
      expect(
        history
            .reconcile(graph(fields: 'text String? extra String?'))
            .mutations,
        isNotEmpty,
      );
      for (final changed in [
        graph(fields: 'text Int?'),
        graph(fields: 'text String'),
        graph(fields: 'text String? extra String'),
        graph(fields: ''),
        graph(slot: 'items Item.create[]'),
      ]) {
        expect(
          () => history.reconcile(changed),
          throwsA(isA<CompilerException>()),
        );
      }
    },
  );
  test('versions never decrease and historical snapshots freeze', () {
    final initial = MutationHistory.capture(graph());
    final history = initial.reconcile(graph(version: 2, fields: 'text Int'));
    expect(history.mutations['Add']!['1'], initial.mutations['Add']!['1']);
    expect(() => history.reconcile(graph()), throwsA(isA<CompilerException>()));
    expect(MutationHistory.decode(history.encode()).encode(), history.encode());
  });
}
