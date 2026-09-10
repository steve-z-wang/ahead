import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test(
    'public package exposes typed scalar and composite Model APIs',
    () async {
      final database = await TestDatabase.create();
      addTearDown(database.dispose);
      const String publicScope = testScope;
      final localSync = await LocalSync.open(
        driver: database.driver,
        clientId: testClientId,
        transport: successLocalSyncTransport,
        prerequisites: readyPrerequisites(),
      );
      await activateTestScopes(localSync, [publicScope]);
      addTearDown(localSync.close);
      final userId = UserId(uuid(1));
      final momentId = MomentId(uuid(2));
      final starId = StarId(userId: userId.value, momentId: momentId.value);
      final starTagId = StarTagId(uuid(6));
      final scalarId = ScalarSampleId(uuid(4));
      final accountStateId = AccountStateId(userId.value);

      Stream<User?> userWatch = localSync.models.user.watch(userId);
      ModelQuery<Space, SpaceFields> spaces = localSync.models.space.query();
      expect(userWatch, isA<Stream<User?>>());
      expect(spaces, isA<ModelQuery<Space, SpaceFields>>());

      await localSync.transaction(
        (tx) => tx.mutate.registerUser(
          (mutation) async =>
              (user: User.create(id: userId.value, handle: 'steve')),
        ),
      );
      await localSync.transaction(
        (tx) => tx.mutate.createSpace(
          (mutation) async => (
            space: Space.create(
              id: uuid(3),
              ownerId: userId.value,
              name: 'Family',
              kind: SpaceKind.group,
              avatarKey: null,
            ),
          ),
        ),
      );
      await localSync.transaction(
        (tx) => tx.mutate.saveAccountState(
          (mutation) async => (
            accountState: AccountState.create(
              userId: userId.value,
              spaceOrder: [uuid(3)],
              inboxSeenAt: null,
            ),
          ),
        ),
      );
      await localSync.transaction(
        (tx) => tx.mutate.captureMoment(
          (mutation) async => (
            moment: Moment.create(
              id: momentId.value,
              spaceId: uuid(3),
              capturedAt: DateTime.utc(2026, 8, 3),
              caption: null,
            ),
            tags: [
              StarTag.create(
                id: starTagId.value,
                userId: userId.value,
                momentId: momentId.value,
                label: 'favorite',
              ),
            ],
            star: Star.create(userId: userId.value, momentId: momentId.value),
          ),
        ),
      );
      await localSync.transaction(
        (tx) => tx.mutate.recordSample(
          (mutation) async => (
            sample: ScalarSample.create(
              id: scalarId.value,
              enabled: true,
              rank: 7,
              score: 1.5,
              optionalAt: DateTime.parse('2026-08-03T12:00:00-07:00'),
              optionalUuid: uuid(5),
            ),
          ),
        ),
      );

      expect(await localSync.models.star.get(starId), isNotNull);
      expect(await localSync.models.starTag.get(starTagId), isNotNull);
      final scalar = await localSync.models.scalarSample.get(scalarId);
      expect(scalar?.enabled, isTrue);
      expect(scalar?.rank, 7);
      expect(scalar?.score, 1.5);
      expect(scalar?.optionalAt?.isUtc, isTrue);
      expect(scalar?.optionalUuid, uuid(5));
      final accountState = await localSync.models.accountState.get(
        accountStateId,
      );
      expect(accountState?.spaceOrder, [uuid(3)]);
      expect(
        () => accountState!.spaceOrder.add(uuid(4)),
        throwsUnsupportedError,
      );
      expect(
        (await localSync.models.space.get(SpaceId(uuid(3))))?.kind,
        SpaceKind.group,
      );

      await localSync.transaction(
        (tx) => tx.mutate.reviseSample(
          (mutation) async => (
            sample: mutation.sample.update(
              (await mutation.models.scalarSample.get(scalarId))!,
              optionalAt: const FieldUpdate.set(null),
              optionalUuid: const FieldUpdate.set(null),
            ),
          ),
        ),
      );
      expect(
        (await localSync.models.scalarSample.get(scalarId))?.optionalAt,
        isNull,
      );

      await localSync.transaction(
        (tx) => tx.mutate.unstar(
          (mutation) async =>
              (star: (await mutation.models.star.get(starId))!.delete()),
        ),
      );
      expect(await localSync.models.star.get(starId), isNull);
      // CAP-396: deleting the Star is one action, and the schema says what
      // falls with it — the tag goes now, on the device, without a queue entry
      // of its own and without waiting for the Backend to claim its death.
      expect(await localSync.models.starTag.get(starTagId), isNull);
    },
  );
}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
