import 'dart:async';

import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late LocalSync localSync;
  late TestDatabase database;

  setUp(() async {
    database = await TestDatabase.create();
    localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: successLocalSyncTransport,
      prerequisites: readyPrerequisites(),
    );
    await activateTestScopes(localSync);
  });

  tearDown(() async {
    await localSync.close();
    await database.dispose();
  });

  test(
    'typed query projects before filtering, ordering, and limiting',
    () async {
      final userId = UserId(uuid(1));
      await localSync.transaction(
        (outerTx) => outerTx.mutate.registerUser(
          (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
        ),
      );
      for (final (id, name) in [(uuid(2), 'Beta'), (uuid(3), 'Alpha')]) {
        await localSync.transaction(
          (outerTx) => outerTx.mutate.createSpace(
            (tx) async => (
              space: Space.create(
                id: id,
                ownerId: userId.value,
                name: name,
                kind: SpaceKind.group,
                avatarKey: null,
              ),
            ),
          ),
        );
      }
      await localSync.transaction(
        (outerTx) => outerTx.mutate.renameSpace(
          (tx) async => (
            space: tx.space.update(
              (await tx.models.space.get(SpaceId(uuid(2))))!,
              name: 'Aardvark',
            ),
          ),
        ),
      );

      // A query reads the merged view, so the rename an act has written is
      // what filtering, ordering and limiting see.
      final limited = await localSync.models.space
          .query()
          .where((fields) => fields.ownerId.equals(userId.value))
          .orderBy((fields) => fields.name.ascending())
          .limit(1)
          .get();
      expect(limited.single.name, 'Aardvark');

      final result = await localSync.models.space
          .query()
          .where((fields) => fields.ownerId.equals(userId.value))
          .orderBy((fields) => fields.name.descending())
          .get();
      expect(result.map((space) => space.name), ['Alpha', 'Aardvark']);
      expect(await localSync.models.space.query().limit(0).get(), isEmpty);
    },
  );

  test('reactive query emits committed projections only', () async {
    final values = <List<String>>[];
    final subscription = localSync.models.user
        .query()
        .orderBy((fields) => fields.handle.ascending())
        .watch()
        .map((users) => users.map((user) => user.handle).toList())
        .listen(values.add);
    await settle();

    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: uuid(1), handle: 'steve')),
      ),
    );
    await settle();

    // The unique index refuses this act as it is written, so it commits
    // nothing — and a watcher never hears about a write that did not commit.
    await expectLater(
      localSync.transaction(
        (outerTx) => outerTx.mutate.registerUser(
          (tx) async => (user: User.create(id: uuid(2), handle: 'steve')),
        ),
      ),
      throwsA(anything),
    );
    await settle();
    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: uuid(3), handle: 'committed')),
      ),
    );
    await settle();

    expect(values, [
      <String>[],
      ['steve'],
      ['committed', 'steve'],
    ]);
    await subscription.cancel();
  });

  test('local Model watches direct canonical commits', () async {
    final noteId = LocalNoteId(uuid(10));
    final values = <String?>[];
    final subscription = localSync.models.localNote
        .watch(noteId)
        .map((note) => note?.text)
        .listen(values.add);
    await settle();

    await localSync.transaction(
      (tx) => tx.models.localNote.create(
        id: noteId.value,
        text: 'First',
        status: LocalNoteStatus.active,
      ),
    );
    await settle();
    await localSync.transaction(
      (tx) => tx.models.localNote.update(id: noteId, text: 'Second'),
    );
    await settle();

    expect(values, [null, 'First', 'Second']);
    await subscription.cancel();
  });
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
