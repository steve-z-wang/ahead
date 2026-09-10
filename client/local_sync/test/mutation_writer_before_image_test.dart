import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import 'support/test_database.dart';
import 'support/test_model.dart';

void main() {
  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late BeforeImageStore<TestId> before;
  late SqlMutationStore<TestId> mutations;
  late ModelMutationWriter<TestId> writer;

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
    mutations = SqlMutationStore(database: fixture.scope, schema: testSchema);
    writer = ModelMutationWriter(mutations, before: before, main: main);
  });

  tearDown(() => fixture.close());

  // Every synced write is a letter of some named act (CAP-444). These are
  // one-write acts, so each queues its own record for the row to name.
  Future<void> create(Map<String, Object?> values) async {
    await writer.create(
      idOne,
      values,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
  }

  Future<void> update(Map<String, Object?> patch) async {
    await writer.update(
      idOne,
      patch,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
  }

  Future<void> remove() async {
    await writer.delete(
      idOne,
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
  }

  test('create inserts into main and holds no before-image', () async {
    await create({'name': 'Family', 'note': null});

    expect((await main.get(idOne))?.fields['name'], 'Family');
    expect(await before.exists(idOne), isFalse);
    expect(await mutations.read(idOne), hasLength(1));
  });

  test('the first update copies truth aside, later ones do not', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});

    await update({'name': 'First'});
    expect((await before.read(idOne))?.fields['name'], 'Truth');
    expect((await main.get(idOne))?.fields['name'], 'First');

    await update({'name': 'Second'});
    // Still the server's state, not the intermediate optimistic one.
    expect((await before.read(idOne))?.fields['name'], 'Truth');
    expect((await main.get(idOne))?.fields['name'], 'Second');
    expect(await mutations.read(idOne), hasLength(2));
  });

  test('delete removes the row from main and holds its truth', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});

    await remove();

    expect(await main.get(idOne), isNull);
    expect((await before.read(idOne))?.fields['name'], 'Truth');
  });

  test('an update after a delete fails on the missing row', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});
    await remove();

    await expectLater(update({'name': 'Late'}), throwsA(isA<Exception>()));
  });

  test('a second create fails on the primary key', () async {
    await create({'name': 'Family', 'note': null});

    await expectLater(
      create({'name': 'Again', 'note': null}),
      throwsA(isA<Exception>()),
    );
  });

  test('a create of a row the server already holds fails', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});

    await expectLater(
      create({'name': 'Clash', 'note': null}),
      throwsA(isA<Exception>()),
    );
  });

  test('an update of a row that never existed fails', () async {
    await expectLater(update({'name': 'Nobody'}), throwsA(isA<Exception>()));
  });

  test('a delete of a row that never existed fails', () async {
    await expectLater(remove(), throwsA(isA<Exception>()));
  });

  test('main, twin and queue roll back together', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});

    await expectLater(
      fixture.scope.transaction((_) async {
        await update({'name': 'Doomed'});
        throw StateError('abandon the transaction');
      }),
      throwsA(isA<StateError>()),
    );

    expect((await main.get(idOne))?.fields['name'], 'Truth');
    expect(await before.exists(idOne), isFalse);
    expect(await mutations.read(idOne), isEmpty);
  });

  test('an empty update patch writes nothing at all', () async {
    await main.create(idOne, {'name': 'Truth', 'note': null});

    await update(const {});

    expect(await before.exists(idOne), isFalse);
    expect(await mutations.read(idOne), isEmpty);
  });
}
