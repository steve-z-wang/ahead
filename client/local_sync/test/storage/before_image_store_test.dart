import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

void main() {
  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late BeforeImageStore<TestId> before;

  setUp(() async {
    fixture = await TestLocalDatabase.open(
      modelStatements: testModelStatements,
    );
    main = SqlCanonicalStore(
      database: fixture.scope,
      descriptor: testDescriptor,
    );
    before = BeforeImageStore(
      database: fixture.scope,
      main: testDescriptor,
      before: testBeforeDescriptor,
    );
  });

  tearDown(() => fixture.close());

  test('copyAside copies exactly the row, and only that row', () async {
    await main.create(idOne, {'name': 'Family', 'note': 'kept'});
    await main.create(idTwo, {'name': 'Other', 'note': null});

    expect(await before.exists(idOne), isFalse);
    await before.copyAside(idOne);

    expect(await before.exists(idOne), isTrue);
    expect(await before.exists(idTwo), isFalse);
    final copied = await before.read(idOne);
    expect(copied?.id, idOne);
    expect(copied?.fields, {'name': 'Family', 'note': 'kept'});
  });

  test(
    'copyAside of a row already held is refused, never silently doubled',
    () async {
      await main.create(idOne, {'name': 'Family', 'note': null});
      await before.copyAside(idOne);
      await main.update(idOne, {'name': 'Drifted'});

      await expectLater(before.copyAside(idOne), throwsA(isA<Exception>()));
      // The first truth survives — a second copy would overwrite it with the
      // already-edited row and lose the only copy of the server's state.
      expect((await before.read(idOne))?.fields['name'], 'Family');
    },
  );

  test('copyAside of an absent row writes nothing', () async {
    await before.copyAside(idOne);

    expect(await before.exists(idOne), isFalse);
  });

  test('updateTruth overwrites the held truth in place', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);

    await before.updateTruth(idOne, {'name': 'Server', 'note': 'fresh'});

    expect((await before.read(idOne))?.fields, {
      'name': 'Server',
      'note': 'fresh',
    });
  });

  test('updateTruth writes a row that was not held before', () async {
    await before.updateTruth(idOne, {'name': 'Server', 'note': null});

    expect(await before.exists(idOne), isTrue);
    expect((await before.read(idOne))?.fields['name'], 'Server');
  });

  test('drop removes the held truth and is safe when absent', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);

    await before.drop(idOne);
    expect(await before.exists(idOne), isFalse);

    await before.drop(idOne);
    expect(await before.exists(idOne), isFalse);
  });

  test('the twin never disturbs the main table', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);
    await before.updateTruth(idOne, {'name': 'Server', 'note': null});
    await before.drop(idOne);

    expect((await main.get(idOne))?.fields['name'], 'Family');
  });
}
