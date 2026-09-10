import 'dart:io';

import 'package:local_sync_compiler/src/cli.dart';
import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  test(
    'requires definitions, at least one output, and no duplicates',
    () async {
      for (final arguments in [
        <String>[],
        // Definitions with no output asked for: nothing to do is an error.
        ['--definitions', 'models'],
        // Outputs with no definitions.
        ['--dart-out', 'generated'],
        ['--contract-out', 'model-contract.json'],
        ['--dart-output', 'generated'],
        ['--typescript-output', 'generated'],
        ['--unknown', 'value'],
        [
          '--definitions',
          'one',
          '--definitions',
          'two',
          '--dart-out',
          'generated',
          '--contract-out',
          'model-contract.json',
        ],
        [
          '--definitions',
          'models',
          '--dart-out',
          'generated',
          '--dart-out',
          'other',
          '--contract-out',
          'model-contract.json',
        ],
        [
          '--definitions',
          'models',
          '--dart-out',
          'generated',
          '--contract-out',
          'one',
          '--contract-out',
          'two',
        ],
      ]) {
        await expectLater(
          () => runLocalSyncCompiler(arguments),
          throwsA(isA<CompilerException>()),
        );
      }
    },
  );

  test('writes a single requested output on its own', () async {
    // Each consumer generates only its own side (CAP-423): Mobile passes
    // --dart-out alone, the Backend --contract-out (+ TypeScript) alone.
    final temporary = await Directory.systemTemp.createTemp('local-sync-cli-');
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    File('${definitions.path}/user.model').writeAsStringSync('''model User {
  id UUID
  @@id(id)
}''');

    final dartOutput = '${temporary.path}/generated-dart';
    await runLocalSyncCompiler([
      '--definitions',
      definitions.path,
      '--dart-out',
      dartOutput,
    ]);
    expect(File('$dartOutput/models/user.dart').existsSync(), isTrue);
    expect(
      File('$dartOutput/local_sync.dart').readAsStringSync(),
      isNot(contains('ScopeKey')),
    );

    final contractOutput = '${temporary.path}/model-contract.json';
    await runLocalSyncCompiler([
      '--definitions',
      definitions.path,
      '--contract-out',
      contractOutput,
    ]);
    expect(File(contractOutput).readAsStringSync(), contains('"name": "User"'));
  });

  test('--scope-models is no longer a compiler option', () async {
    final temporary = await Directory.systemTemp.createTemp('local-sync-cli-');
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    File('${definitions.path}/user.model').writeAsStringSync('''model User {
  id UUID
  @@id(id)
}''');
    final dartOutput = '${temporary.path}/generated-dart';

    await expectLater(
      () => runLocalSyncCompiler([
        '--definitions',
        definitions.path,
        '--scope-models',
        'User',
      ]),
      throwsA(
        isA<CompilerException>().having(
          (error) => error.message,
          'message',
          contains('unknown compiler argument: --scope-models'),
        ),
      ),
    );
    expect(Directory(dartOutput).existsSync(), isFalse);
  });

  test('compiles once and writes Dart plus the Model contract', () async {
    final temporary = await Directory.systemTemp.createTemp('local-sync-cli-');
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    File('${definitions.path}/user.model').writeAsStringSync('''model User {
  id UUID
  @@id(id)
}''');
    final dartOutput = '${temporary.path}/generated-dart';
    final contractOutput = '${temporary.path}/backend/model-contract.json';

    await runLocalSyncCompiler([
      '--definitions',
      definitions.path,
      '--dart-out',
      dartOutput,
      '--contract-out',
      contractOutput,
    ]);

    expect(File('$dartOutput/models/user.dart').existsSync(), isTrue);
    expect(File(contractOutput).readAsStringSync(), contains('"name": "User"'));
  });

  test('invalid definitions leave prior output intact', () async {
    final temporary = await Directory.systemTemp.createTemp('local-sync-cli-');
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    File('${definitions.path}/bad.model').writeAsStringSync('model Broken {');
    final dartOutput = Directory('${temporary.path}/generated-dart')
      ..createSync();
    final contractOutput = File('${temporary.path}/model-contract.json');
    File('${dartOutput.path}/existing.dart').writeAsStringSync('existing');
    contractOutput.writeAsStringSync('existing');

    await expectLater(
      () => runLocalSyncCompiler([
        '--definitions',
        definitions.path,
        '--dart-out',
        dartOutput.path,
        '--contract-out',
        contractOutput.path,
      ]),
      throwsA(isA<DefinitionException>()),
    );

    expect(
      File('${dartOutput.path}/existing.dart').readAsStringSync(),
      'existing',
    );
    expect(contractOutput.readAsStringSync(), 'existing');
  });

  test('writes the typed Backend output', () async {
    final temporary = await Directory.systemTemp.createTemp('local-sync-cli-');
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    File('${definitions.path}/models.model').writeAsStringSync('''
model Page {
  id UUID
  title String
  @@id(id)
}

model Note {
  id UUID
  @@id(id)
}
''');
    final dartOutput = '${temporary.path}/generated-dart';
    final contractOutput = '${temporary.path}/model-contract.json';
    final typescriptOutput = '${temporary.path}/typescript/backend';

    await runLocalSyncCompiler([
      '--definitions',
      definitions.path,
      '--dart-out',
      dartOutput,
      '--contract-out',
      contractOutput,
      '--typescript-backend-out',
      typescriptOutput,
    ]);

    expect(File('$typescriptOutput/backend_contract.ts').existsSync(), isTrue);
    expect(File('$dartOutput/models/page.dart').existsSync(), isTrue);
  });

  test('requires an explicit issue to replace a breaking contract', () async {
    final temporary = await Directory.systemTemp.createTemp('local-sync-cli-');
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    final contractOutput = '${temporary.path}/model-contract.json';

    File('${definitions.path}/models.model').writeAsStringSync('''
model Note {
  id UUID
  body String
  @@id(id)
}
''');
    await runLocalSyncCompiler([
      '--definitions',
      definitions.path,
      '--contract-out',
      contractOutput,
    ]);

    File('${definitions.path}/models.model').writeAsStringSync('''
model Note {
  id UUID
  @@id(id)
}
''');

    await expectLater(
      runLocalSyncCompiler([
        '--definitions',
        definitions.path,
        '--contract-out',
        contractOutput,
        '--allow-breaking-contract',
        'because-I-said-so',
      ]),
      throwsA(
        isA<CompilerException>().having(
          (error) => error.message,
          'message',
          contains('must name a CAP issue'),
        ),
      ),
    );

    await expectLater(
      runLocalSyncCompiler([
        '--definitions',
        definitions.path,
        '--contract-out',
        contractOutput,
        '--allow-breaking-contract',
        'CAP-567',
      ]),
      completes,
    );
    expect(File(contractOutput).readAsStringSync(), isNot(contains('body')));
  });
}
