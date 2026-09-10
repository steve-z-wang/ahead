import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

/// The wire fence (spec §6b/§9.3): field names are the contract, so a
/// published Model or field may gain company and never leave.
void main() {
  Object? contract(Map<String, List<String>> models) => decodeContract(
    '{"enums":[],"models":['
    '${models.entries.map((entry) => '{"name":"${entry.key}","schemaVersion":1,'
        '"identity":["id"],"fields":['
        '${entry.value.map((field) => '{"name":"$field","type":{"kind":"scalar",'
            '"name":"string"},"nullable":true}').join(',')}]}').join(',')}'
    ']}',
  );

  test('an unchanged contract keeps its promise', () {
    final before = contract({
      'Moment': ['id', 'text'],
    });

    expect(findContractBreaks(committed: before, generated: before), isEmpty);
  });

  test('a new field is additive, and passes', () {
    expect(
      findContractBreaks(
        committed: contract({
          'Moment': ['id', 'text'],
        }),
        generated: contract({
          'Moment': ['id', 'text', 'mood'],
        }),
      ),
      isEmpty,
    );
  });

  test('a whole new Model is additive too', () {
    expect(
      findContractBreaks(
        committed: contract({
          'Moment': ['id'],
        }),
        generated: contract({
          'Moment': ['id'],
          'Star': ['id'],
        }),
      ),
      isEmpty,
    );
  });

  test('a removed field fails, and says which one', () {
    final breaks = findContractBreaks(
      committed: contract({
        'Moment': ['id', 'text'],
      }),
      generated: contract({
        'Moment': ['id'],
      }),
    );

    expect(breaks, hasLength(1));
    expect(breaks.single.message, contains('Moment.text'));
    expect(breaks.single.message, contains('never removed or renamed'));
  });

  // A rename is a removal and an addition at once. The removal half is what
  // breaks a client that still speaks the old name, so it fails here.
  test('a renamed field fails as the removal it is', () {
    final breaks = findContractBreaks(
      committed: contract({
        'Moment': ['id', 'text'],
      }),
      generated: contract({
        'Moment': ['id', 'body'],
      }),
    );

    expect(breaks, hasLength(1));
    expect(breaks.single.message, contains('Moment.text'));
  });

  test('a removed Model fails', () {
    final breaks = findContractBreaks(
      committed: contract({
        'Moment': ['id'],
        'Star': ['id'],
      }),
      generated: contract({
        'Moment': ['id'],
      }),
    );

    expect(breaks, hasLength(1));
    expect(breaks.single.message, contains('Model "Star"'));
  });

  test('a renamed Model fails as the removal it is', () {
    final breaks = findContractBreaks(
      committed: contract({
        'Moment': ['id'],
      }),
      generated: contract({
        'Page': ['id'],
      }),
    );

    expect(breaks, hasLength(1));
    expect(breaks.single.message, contains('Model "Moment"'));
  });

  test('every break names both the loss and what to do instead', () {
    final breaks = findContractBreaks(
      committed: contract({
        'Moment': ['id', 'text'],
        'Star': ['id'],
      }),
      generated: contract({
        'Moment': ['id'],
      }),
    );

    expect(breaks, hasLength(2));
    for (final issue in breaks) {
      expect(issue.message, contains('Add the new'));
    }
  });

  test('nothing committed yet promises nothing', () {
    expect(
      findContractBreaks(
        committed: null,
        generated: contract({
          'Moment': ['id'],
        }),
      ),
      isEmpty,
    );
  });
}
