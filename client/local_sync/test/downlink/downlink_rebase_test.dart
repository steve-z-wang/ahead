import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

import '../support/test_database.dart';
import '../support/test_model.dart';

/// Flow ③ (CAP-393 spec §5): new truth lands under the user's pending edits
/// rather than over them, inside the per-change transaction that already
/// couples the canonical write, settlement and the cursor.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';

  late TestLocalDatabase fixture;
  late SqlCanonicalStore<TestId> main;
  late BeforeImageStore<TestId> before;
  late SqlMutationStore<TestId> mutations;
  late ModelMutationWriter<TestId> writer;
  late DownlinkPageProcessor store;

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
    final registry = ModelRegistry([
      TypedModelRegistryEntry<TestId>(
        schema: testSchema,
        canonical: main,
        before: before,
        mutations: mutations,
      ),
    ]);
    store = DownlinkPageProcessor(
      database: fixture.scope,
      registry: registry,
      decoder: ModelChangeDecoder(registry),
    );
    await MutationQueue(fixture.scope, registry: registry).initialize(clientId);
    await setTestScopes(fixture.scope, [userScope]);
  });

  tearDown(() => fixture.close());

  DownlinkPage page(int through, List<Map<String, Object?>> changes) =>
      DownlinkPage(
        scope: userScope,
        fromSyncId: 0,
        throughSyncId: through,
        changes: [
          for (final (index, change) in changes.indexed)
            () {
              final syncId = through - changes.length + index + 1;
              return AddressedModelChange(
                syncId: syncId,
                raw: {...change, 'syncId': syncId},
              );
            }(),
        ],
      );

  Map<String, Object?> upsert(TestId id, String name, {String? note}) => {
    'model': 'Test',
    'operation': 'upsert',
    'id': {'id': id.value.uuid},
    'data': {'name': name, 'note': note},
    'syncId': 0,
  };

  Map<String, Object?> remove(TestId id) => {
    'model': 'Test',
    'operation': 'delete',
    'id': {'id': id.value.uuid},
    'syncId': 0,
  };

  test('a clean row takes the server state straight into main', () async {
    final result = await store.apply(
      page(1, [upsert(idOne, 'Server')]),
      afterSyncId: 0,
    );

    expect(result.failures, isEmpty);
    expect((await main.get(idOne))?.fields['name'], 'Server');
    expect(await before.exists(idOne), isFalse);
  });

  test('a dirty row keeps its edit on top of the new truth', () async {
    await main.create(idOne, {'name': 'Old', 'note': null});
    await writer.update(
      idOne,
      {'note': 'mine'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    await store.apply(page(1, [upsert(idOne, 'Renamed')]), afterSyncId: 0);

    // The server renamed it; the user's own note survives on top.
    expect((await main.get(idOne))?.fields, {
      'name': 'Renamed',
      'note': 'mine',
    });
    expect((await before.read(idOne))?.fields, {
      'name': 'Renamed',
      'note': null,
    });
  });

  test('a server delete under a pending edit wins', () async {
    await main.create(idOne, {'name': 'Old', 'note': null});
    await writer.update(
      idOne,
      {'note': 'mine'},
      mutationOrdinal: await fixture.queueRecord(),
      wire: true,
    );

    await store.apply(page(1, [remove(idOne)]), afterSyncId: 0);

    // Truth is nonexistence now, and the doomed edit is still queued for the
    // rejection that will confirm it.
    expect(await main.get(idOne), isNull);
    expect(await before.exists(idOne), isFalse);
    expect(await mutations.read(idOne), hasLength(1));
  });

  test('rejects replaying a page from an older cursor', () async {
    await store.apply(page(1, [upsert(idOne, 'Server')]), afterSyncId: 0);
    final first = await main.get(idOne);

    // Canonical writes and cursor advancement share one transaction. Once
    // cursor 1 is durable, replaying a page requested from cursor 0 is stale.
    await expectLater(
      store.apply(page(1, [upsert(idOne, 'Server')]), afterSyncId: 1),
      throwsA(isA<DownlinkPageException>()),
    );

    expect(await main.get(idOne), first);
    expect(await store.readLastAppliedSyncId(userScope), 1);
  });

  test('the cursor advances exactly once per change', () async {
    await store.apply(
      page(2, [upsert(idOne, 'One'), upsert(idTwo, 'Two')]),
      afterSyncId: 0,
    );

    expect(await store.readLastAppliedSyncId(userScope), 2);
    expect((await main.get(idOne))?.fields['name'], 'One');
    expect((await main.get(idTwo))?.fields['name'], 'Two');
  });
}
