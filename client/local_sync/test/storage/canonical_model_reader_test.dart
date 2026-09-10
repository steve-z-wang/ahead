import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

/// Reads are plain table reads since CAP-393 — the main table IS the merged
/// view — so what is worth pinning here is the reactive contract the readers
/// share, not any merge.
void main() {
  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late BeforeImageStore<TestId> before;
  late SqlMutationStore<TestId> mutations;
  late CanonicalModelReader<TestId> reader;

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
    reader = CanonicalModelReader(
      canonical: main,
      database: fixture.scope,
      descriptor: testDescriptor,
    );
  });

  tearDown(() => fixture.close());

  test('an optimistic edit is read straight from the main table', () async {
    final writer = ModelMutationWriter(mutations, before: before, main: main);
    await writer.create(
      idOne,
      {'name': 'Family', 'note': null},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );
    await writer.update(
      idOne,
      {'name': 'Renamed'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    expect((await reader.get(idOne))?.fields['name'], 'Renamed');
    final queried = await reader.query(ProjectionQuery<TestId>());
    expect(queried.map((record) => record.fields['name']), ['Renamed']);
  });

  test('the twin is invisible to reads', () async {
    await main.create(idOne, {'name': 'Optimistic', 'note': null});
    await before.updateTruth(idOne, {'name': 'Truth', 'note': null});

    expect((await reader.get(idOne))?.fields['name'], 'Optimistic');
    expect(await reader.query(ProjectionQuery<TestId>()), hasLength(1));
  });

  test('watch reads initially, reacts to a write, and deduplicates', () async {
    final values = <String?>[];
    final subscription = reader
        .watch(idOne)
        .map((record) => record?.fields['name'] as String?)
        .listen(values.add);
    await _settle(values, 1);

    await main.create(idOne, {'name': 'Before', 'note': null});
    await _settle(values, 2);
    await main.update(idOne, {'name': 'After'});
    await _settle(values, 3);

    expect(values, [null, 'Before', 'After']);
    await subscription.cancel();
  });

  test('a rewrite of identical values yields nothing new', () async {
    await main.create(idOne, {'name': 'Only', 'note': null});
    final values = <ModelRecord<TestId>?>[];
    final subscription = reader.watch(idOne).listen(values.add);
    await _settle(values, 1);

    await main.update(idOne, {'name': 'Only'});
    await _quiet();

    expect(values, hasLength(1));
    await subscription.cancel();
  });

  test('a rebuild is a main-table change, so watchers fire', () async {
    final writer = ModelMutationWriter(mutations, before: before, main: main);
    await main.create(idOne, {'name': 'Truth', 'note': null});
    await writer.update(
      idOne,
      {'name': 'Optimistic'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    final values = <String?>[];
    final subscription = reader
        .watch(idOne)
        .map((record) => record?.fields['name'] as String?)
        .listen(values.add);
    await _settle(values, 1);

    // The server rejected the edit, so it leaves the queue and the row is
    // rebuilt back to the truth held aside.
    await fixture.scope.current.execute(
      DatabaseStatement(sql: 'DELETE FROM pending_mutations'),
    );
    await RowRebuilder(
      main: main,
      before: before,
      mutations: mutations,
      replay: MutationReducer(testSchema),
    ).rebuild(idOne);
    await _settle(values, 2);

    expect(values, ['Optimistic', 'Truth']);
    await subscription.cancel();
  });
}

/// Waits for the watcher to have delivered [count] values, so the tests read
/// the stream's own pace rather than guessing at it.
Future<void> _settle(List<Object?> values, int count) async {
  // Generous on purpose: the whole suite runs in parallel, and a watcher that
  // is merely slow under load must not read as a watcher that never fired.
  for (var attempt = 0; attempt < 2000 && values.length < count; attempt += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _quiet() =>
    Future<void>.delayed(const Duration(milliseconds: 100));
