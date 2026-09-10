import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

void main() {
  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late BeforeImageStore<TestId> before;
  late SqlMutationStore<TestId> mutations;
  late RowRebuilder<TestId> rebuilder;

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
    rebuilder = RowRebuilder(
      main: main,
      before: before,
      mutations: mutations,
      replay: MutationReducer(testSchema),
    );
  });

  tearDown(() => fixture.close());

  /// One queued edit and the named record it belongs to. Each is its own act,
  /// so each can leave the queue on its own — which is what a rebuild is for.
  Future<MutationPosition> queue(
    MutationOperation operation, [
    Map<String, Object?> values = const {},
  ]) async => mutations.append(
    id: idOne,
    operation: operation,
    values: values,
    mutationOrdinal: await fixture.queueRecord(),
    wire: true,
  );

  test('replays the surviving edits on top of held truth', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);
    await queue(MutationOperation.update, {'name': 'Rejected'});
    final survivor = await queue(MutationOperation.update, {'note': 'kept'});
    await main.update(idOne, {'name': 'Rejected', 'note': 'kept'});

    // The rejected mutation leaves the queue; the survivor is replayed.
    await _dropMutation(fixture, survivor.mutationOrdinal - 1);
    await rebuilder.rebuild(idOne);

    expect((await main.get(idOne))?.fields, {'name': 'Family', 'note': 'kept'});
    // Still dirty, so truth is still held.
    expect(await before.exists(idOne), isTrue);
  });

  test('an emptied queue restores truth exactly and drops the twin', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);
    final only = await queue(MutationOperation.update, {'name': 'Optimistic'});
    await main.update(idOne, {'name': 'Optimistic'});

    await _dropMutation(fixture, only.mutationOrdinal);
    await rebuilder.rebuild(idOne);

    expect((await main.get(idOne))?.fields['name'], 'Family');
    expect(await before.exists(idOne), isFalse);
  });

  test('a create origin with nothing surviving leaves no row', () async {
    // A pending create has no before-image: the queue's create IS the marker
    // that prior truth was nonexistence.
    final only = await queue(MutationOperation.create, {
      'name': 'Optimistic',
      'note': null,
    });
    await main.create(idOne, {'name': 'Optimistic', 'note': null});

    await _dropMutation(fixture, only.mutationOrdinal);
    await rebuilder.rebuild(idOne);

    expect(await main.get(idOne), isNull);
    expect(await before.exists(idOne), isFalse);
  });

  test('a create origin replays its surviving edits from nothing', () async {
    await queue(MutationOperation.create, {'name': 'Optimistic', 'note': null});
    final rejected = await queue(MutationOperation.update, {'note': 'dropped'});

    await _dropMutation(fixture, rejected.mutationOrdinal);
    await rebuilder.rebuild(idOne);

    expect((await main.get(idOne))?.fields, {
      'name': 'Optimistic',
      'note': null,
    });
    expect(await before.exists(idOne), isFalse);
  });

  test('a terminal delete removes the row from main', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);
    await queue(MutationOperation.delete);

    await rebuilder.rebuild(idOne);

    expect(await main.get(idOne), isNull);
    expect(await before.exists(idOne), isTrue);
  });

  test('rebases surviving edits onto truth that moved underneath', () async {
    await main.create(idOne, {'name': 'Family', 'note': null});
    await before.copyAside(idOne);
    await queue(MutationOperation.update, {'note': 'mine'});

    // The server spoke while the row was dirty.
    await before.updateTruth(idOne, {'name': 'Renamed', 'note': null});
    await rebuilder.rebuild(idOne);

    expect((await main.get(idOne))?.fields, {
      'name': 'Renamed',
      'note': 'mine',
    });
  });
}

Future<void> _dropMutation(TestLocalDatabase fixture, int ordinal) async {
  await fixture.scope.current.execute(
    DatabaseStatement(
      sql: 'DELETE FROM pending_mutations WHERE ordinal = ?',
      variables: [ordinal],
    ),
  );
}
