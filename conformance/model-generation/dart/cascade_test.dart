import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

/// CAP-396 end to end, over the generated definitions: deleting a row applies
/// the declared cascade to the whole local subtree, in one transaction, and
/// puts exactly one thing on the wire — the row the user named.
void main() {
  test('a delete takes its declared subtree with it', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final transport = SuccessLocalSyncTransport();
    final localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
    );
    // Keep this local-atomicity assertion offline; an acknowledgement may
    // otherwise settle the queue between the two membership reads.
    addTearDown(localSync.close);

    final userId = UserId(uuid(1));
    final momentId = MomentId(uuid(2));
    final spaceId = SpaceId(uuid(3));
    final starId = StarId(userId: userId.value, momentId: momentId.value);
    final firstTagId = StarTagId(uuid(6));
    final secondTagId = StarTagId(uuid(7));

    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: userId.value,
            name: 'Family',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    await localSync.transaction(
      (outerTx) => outerTx.mutate.captureMoment(
        (tx) async => (
          moment: Moment.create(
            id: momentId.value,
            spaceId: spaceId.value,
            capturedAt: DateTime.utc(2026, 8, 6),
            caption: null,
          ),
          tags: [
            for (final tagId in [firstTagId, secondTagId])
              StarTag.create(
                id: tagId.value,
                userId: userId.value,
                momentId: momentId.value,
                label: 'favorite',
              ),
          ],
          star: Star.create(userId: userId.value, momentId: momentId.value),
        ),
      ),
    );

    final queuedBeforeDelete = await pendingMutationCount(localSync);

    await localSync.transaction(
      (outerTx) => outerTx.mutate.unstar(
        (tx) async =>
            (star: (await localSync.models.star.get(starId))!.delete()),
      ),
    );

    expect(await localSync.models.star.get(starId), isNull);
    expect(await localSync.models.starTag.get(firstTagId), isNull);
    expect(await localSync.models.starTag.get(secondTagId), isNull);
    // The page the Star hangs off is not part of the Star: only what the
    // schema declares Cascade falls.
    expect(await localSync.models.moment.get(momentId), isNotNull);
    // One action, one entry — the tags are the server's own expansion to run.
    expect(await pendingMutationCount(localSync), queuedBeforeDelete + 1);
  });
}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);

Future<int> pendingMutationCount(LocalSync localSync) async =>
    (await localSync.readOnlySql.query(
      'SELECT ordinal FROM pending_mutations',
    )).length;
