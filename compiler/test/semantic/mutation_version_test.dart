import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  test('versions default to one and accept explicit safe integers', () {
    for (final (annotation, version) in [
      ('', 1),
      ('@@version(1)', 1),
      ('@@version(2)', 2),
      ('@@version(9007199254740991)', 9007199254740991),
    ]) {
      final graph = compileModelSources({
        'test.model':
            'model Item { id String @@id(id) } mutation Add { item Item.create $annotation }',
      });
      expect(graph.mutations.single.version, version);
    }
  });
  test('duplicate version annotations fail', () {
    expect(
      () => compileModelSources({
        'test.model':
            'model Item { id UUID @@id(id) } mutation Add { item Item.create @@version(1) @@version(2) }',
      }),
      throwsA(isA<DefinitionException>()),
    );
  });
  test('invalid versions fail', () {
    for (final value in [
      '0',
      '-1',
      '1.5',
      '9007199254740992',
      'foo',
      '',
      '1, 2',
    ]) {
      expect(
        () => compileModelSources({
          'test.model':
              'model Item { id String @@id(id) } mutation Add { item Item.create @@version($value) }',
        }),
        throwsA(anything),
      );
    }
  });
}
