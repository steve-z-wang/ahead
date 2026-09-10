import 'package:local_sync_database/local_sync_database.dart'
    show DatabaseException;
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `mutate` is the one write boundary (CAP-444): a write exists only as a
/// letter of a named act, and the act is the unit of fate — it applies whole,
/// it fails whole, and it reaches the queue as one record.
void main() {
  late LocalSync localSync;
  late SuccessLocalSyncTransport transport;
  late TestDatabase database;

  setUp(() async {
    transport = SuccessLocalSyncTransport();
    database = await TestDatabase.create();
    localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
    );
    await activateTestScopes(localSync);
  });

  tearDown(() async {
    await localSync.close();
    await database.dispose();
  });

  test('one act writes every Model it names, as one record', () async {
    final userId = UserId(uuid(1));
    final momentId = MomentId(uuid(2));
    final starId = StarId(userId: userId.value, momentId: momentId.value);

    await localSync.transaction(
      (tx) => tx.mutate.captureMoment(
        (mutation) async => (
          moment: Moment.create(
            id: momentId.value,
            spaceId: uuid(3),
            capturedAt: DateTime.utc(2026, 8, 6),
            caption: 'a page',
          ),
          tags: const <StarTagCreate>[],
          star: Star.create(userId: userId.value, momentId: momentId.value),
        ),
      ),
    );

    expect((await localSync.models.moment.get(momentId))?.caption, 'a page');
    expect(await localSync.models.star.get(starId), isNotNull);
    // One act, one queue record, and the operations beneath it are the letters
    // it is spelled with.
    expect(await recordCount(localSync), 1);
    expect(await operationCount(localSync), 2);
    await transport.firstSend.future;
    expect(transport.bodies, hasLength(1));
  });

  test('a write never wakes Uplink, whichever Model it names', () async {
    final noteId = LocalNoteId(uuid(14));

    await localSync.transaction(
      (tx) => tx.models.localNote.create(
        id: noteId.value,
        text: 'Device only',
        status: LocalNoteStatus.active,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect((await localSync.models.localNote.get(noteId))?.text, 'Device only');
    // `write` means commit only to this device: no record, no queue row, no
    // request (CAP-488). The same Model reaches the wire below, through an
    // act that names it.
    expect(await recordCount(localSync), 0);
    expect(transport.bodies, isEmpty);
  });

  // CAP-407 spec §2: the store is a replica and must tolerate arrival order,
  // so a row naming a parent no claim has delivered yet is written as it
  // stands. Nothing enforces the relation here — integrity is the server's,
  // and a write it refuses comes back as a rejection.
  test('writes a child whose parent is not there yet', () async {
    final userId = UserId(uuid(1));
    final spaceId = SpaceId(uuid(2));

    await localSync.transaction(
      (tx) => tx.mutate.createSpace(
        (mutation) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Child first',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );

    expect((await localSync.models.space.get(spaceId))?.name, 'Child first');
    expect(await localSync.models.user.get(userId), isNull);
  });

  // CAP-393 spec §6: no commit-time validation pass. A write is refused as it
  // is written — here by the unique index — and the act carrying it is what
  // leaves nothing behind.
  test('a caught write failure leaves nothing behind', () async {
    final userId = UserId(uuid(1));
    final twinId = UserId(uuid(3));

    await localSync.transaction(
      (tx) => tx.mutate.registerUser(
        (mutation) async =>
            (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );

    await expectLater(
      localSync.transaction(
        (tx) => tx.mutate.registerUser(
          (mutation) async =>
              (user: User.create(id: twinId.value, handle: 'steve')),
        ),
      ),
      throwsA(isA<DatabaseException>()),
    );

    expect(await localSync.models.user.get(twinId), isNull);
    expect((await localSync.models.user.get(userId))?.handle, 'steve');
    expect(await recordCount(localSync), 1);
  });

  test('a failure part-way through one act applies nothing', () async {
    final userId = UserId(uuid(1));
    final momentId = MomentId(uuid(2));
    final starId = StarId(userId: userId.value, momentId: momentId.value);
    final tagId = StarTagId(uuid(6));

    // The second tag repeats the first tag's identity, so the act fails after
    // its page and its first tag are already written.
    await expectLater(
      localSync.transaction(
        (tx) => tx.mutate.captureMoment(
          (mutation) async => (
            moment: Moment.create(
              id: momentId.value,
              spaceId: uuid(3),
              capturedAt: DateTime.utc(2026, 8, 6),
              caption: 'written twice',
            ),
            tags: [
              for (var attempt = 0; attempt < 2; attempt += 1)
                StarTag.create(
                  id: tagId.value,
                  userId: userId.value,
                  momentId: momentId.value,
                  label: 'holiday',
                ),
            ],
            star: Star.create(userId: userId.value, momentId: momentId.value),
          ),
        ),
      ),
      throwsA(anything),
    );

    // Nothing the act named survives — not the operations that had already
    // applied, and not the record they were about to be sent under.
    expect(await localSync.models.moment.get(momentId), isNull);
    expect(await localSync.models.starTag.get(tagId), isNull);
    expect(await localSync.models.star.get(starId), isNull);
    expect(await recordCount(localSync), 0);
    expect(await operationCount(localSync), 0);
    await Future<void>.delayed(Duration.zero);
    expect(transport.bodies, isEmpty);
  });
}

Future<int> recordCount(LocalSync localSync) async =>
    (await localSync.readOnlySql.query(
      'SELECT ordinal FROM pending_mutations',
    )).length;

Future<int> operationCount(LocalSync localSync) async =>
    (await localSync.readOnlySql.query(
      'SELECT mutation_ordinal, position FROM pending_mutation_operations',
    )).length;

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
