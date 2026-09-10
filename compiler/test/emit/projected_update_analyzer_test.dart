import 'dart:io';

import 'package:local_sync_compiler/src/cli.dart';
import 'package:test/test.dart';

void main() {
  test('generated update projection is enforced by Dart analysis', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'local-sync-projected-update-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final definitions = Directory('${temporary.path}/definitions')
      ..createSync();
    File('${definitions.path}/moment.model').writeAsStringSync('''model Moment {
  id UUID
  caption String
  spaceId UUID
  @@id(id)
}

mutation ReviseMoment {
  moment Moment.update<caption>
}
''');
    final package = Directory('${temporary.path}/consumer')..createSync();
    final generated = '${package.path}/lib/src/generated';
    await runLocalSyncCompiler([
      '--definitions',
      definitions.path,
      '--dart-out',
      generated,
    ]);

    final localSyncRoot = Directory.current.parent.path;
    File('${package.path}/pubspec.yaml').writeAsStringSync(
      '''name: projection_fixture
publish_to: none
environment:
  sdk: ^3.10.3
dependencies:
  local_sync:
    path: $localSyncRoot/client/local_sync
  local_sync_database:
    path: $localSyncRoot/client/local_sync_database
''',
    );
    final source = File('${package.path}/lib/use.dart');
    final pubGet = await Process.run('dart', [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: package.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');

    source.writeAsStringSync(
      _use('mutation.moment.update(row, caption: next)'),
    );
    await _expectAnalysis(package, succeeds: true);

    source.writeAsStringSync(
      _use('mutation.moment.update(row, caption: next, spaceId: row.spaceId)'),
    );
    final undeclared = await _expectAnalysis(package, succeeds: false);
    expect(undeclared, contains('UNDEFINED_NAMED_PARAMETER'));
    expect(undeclared, contains('spaceId'));

    source.writeAsStringSync(_use('row.update(caption: next)'));
    final generic = await _expectAnalysis(package, succeeds: false);
    expect(generic, contains('RETURN_OF_INVALID_TYPE_FROM_CLOSURE'));
    expect(generic, contains('MomentUpdate'));
    expect(generic, contains('ReviseMomentResult'));
  });
}

String _use(String operation) =>
    '''import 'src/generated/local_sync.dart';

Future<void> revise(
  LocalSync localSync,
  MomentId id,
  String next,
) => localSync.transaction(
  (tx) => tx.mutate.reviseMoment((mutation) async {
    final row = await mutation.models.moment.get(id);
    if (row == null) return null;
    return (moment: $operation,);
  }),
);
''';

Future<String> _expectAnalysis(
  Directory package, {
  required bool succeeds,
}) async {
  final result = await Process.run('dart', [
    'analyze',
    '--format',
    'machine',
    '--no-fatal-warnings',
  ], workingDirectory: package.path);
  final output = '${result.stdout}${result.stderr}';
  expect(result.exitCode == 0, succeeds, reason: output);
  return output;
}
