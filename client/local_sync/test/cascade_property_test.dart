import 'dart:math';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import 'support/cascade_family.dart';
import 'support/test_database.dart';

/// CAP-396 spec §11.5, pinned rather than argued: whatever the history, every
/// row equals its truth with its *effective* edits replayed on top — its own,
/// plus the deletes it inherits from an ancestor — and truth is held aside
/// only for rows that still diverge.
///
/// The generalization of the CAP-393 property: a cascade writes nothing to the
/// queue, so a row's history is no longer readable from its own queue alone.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const userScope = 'User:$clientId';

  for (final seed in [3, 17, 4242]) {
    test('holds over a random history with cascades (seed $seed)', () async {
      final random = Random(seed);
      final fixture = await TestLocalDatabase.open(
        modelStatements: familyModelStatements,
      );
      addTearDown(fixture.close);

      final family = FamilyRegistry(fixture.scope);
      final runtimes = FamilyRuntimes(fixture.scope, family.registry);
      final outbox = MutationQueue(fixture.scope, registry: family.registry);
      await ReadinessLedger(fixture.scope).markReady(remoteObject('k'));
      await outbox.initialize(clientId);
      final downlink = DownlinkPageProcessor(
        database: fixture.scope,
        registry: family.registry,
        decoder: ModelChangeDecoder(family.registry),
      );
      await setTestScopes(fixture.scope, [userScope]);

      final spaceIds = [
        for (var index = 0; index < 2; index += 1)
          FamilySpaceId(familyUuid(index)),
      ];
      final momentIds = [
        for (var index = 0; index < 3; index += 1)
          FamilyMomentId(familyUuid(10 + index)),
      ];
      final photoIds = [
        for (var index = 0; index < 3; index += 1)
          FamilyPhotoId(familyUuid(20 + index)),
      ];
      FamilySpaceId parentOf(int index) => spaceIds[index % spaceIds.length];
      FamilyMomentId momentOf(int index) => momentIds[index % momentIds.length];

      var syncId = 0;
      var step = 0;

      /// The invariant, for one Model.
      Future<void> assertModel<I extends ModelId>(
        TypedModelRegistryEntry<I> entry,
        List<I> ids,
      ) async {
        final effective = EffectiveMutations<I>(
          registry: family.registry,
          entry: entry,
          own: entry.mutations,
        );
        final replay = MutationReducer<I>(entry.schema);
        for (final id in ids) {
          final truth = await entry.before.read(id);
          final standing = await effective.read(id);
          final actual = await entry.canonical.get(id);

          if (truth != null) {
            expect(
              standing,
              isNotEmpty,
              reason:
                  'seed $seed step $step ${entry.schema.name} $id: truth is '
                  'held for a row with nothing standing over it',
            );
          }

          if (standing.isEmpty) continue;
          final ModelRecord<I>? expected;
          try {
            expected = replay.reduce(truth, standing);
          } on ProjectionIntegrityException {
            // Doomed edits: the server moved the ground under them and the
            // rejection on its way is what restores the row.
            continue;
          }
          expect(
            actual?.fields,
            expected?.fields,
            reason:
                'seed $seed step $step ${entry.schema.name} $id: main is not '
                'replay(before, effective)',
          );
        }
      }

      Future<void> assertInvariant() async {
        await assertModel(family.space, spaceIds);
        await assertModel(family.moment, momentIds);
        await assertModel(family.photo, photoIds);
      }

      /// One named act, applied as one transaction: a failure part way through
      /// applies nothing at all, so there is nothing to undo by hand.
      Future<void> act(String name, List<ModelOperation> operations) async {
        try {
          await runtimes.mutate(name, operations);
        } on DatabaseException {
          // A double create, or an edit of a row that is not there.
        } on LocalStorageException {
          // Same, surfaced by the store's affected-row check.
        }
      }

      /// One claim from the Backend — a value, or absence.
      Future<void> claim(
        String model,
        Map<String, Object?> identity,
        Map<String, Object?>? data,
      ) async {
        final next = syncId + 1;
        final result = await downlink.apply(
          DownlinkPage(
            scope: userScope,
            fromSyncId: syncId,
            throughSyncId: next,
            changes: [
              AddressedModelChange(
                syncId: next,
                raw: {
                  'syncId': next,
                  'model': model,
                  'operation': data == null ? 'delete' : 'upsert',
                  'id': identity,
                  if (data != null) 'data': data,
                },
              ),
            ],
          ),
          afterSyncId: syncId,
        );
        expect(result.failures, isEmpty);
        syncId = next;
      }

      /// The server answers the queue, then its claims catch up so the batch
      /// settles.
      Future<void> answerQueue({int? limit}) async {
        final candidate = await outbox.scheduledCandidate(
          limit: limit ?? 2 + random.nextInt(3),
        );
        if (candidate == null) return;
        final batch = await outbox.freeze(
          expectedSequence: candidate.batchSequence,
          mutationOrdinals: candidate.records.keys.toList(),
        );
        final rejections = [
          for (final record in batch.records.values)
            if (random.nextInt(3) == 0)
              UplinkMutationRejection(
                mutationId: record.legacyWireOrdinal ?? record.ordinal,
                code: 'refused',
              ),
        ];
        final required = syncId + 1;
        await outbox.recordResponse(
          batchSequence: batch.batchSequence,
          requiredCheckpoints: [
            UplinkCheckpoint(scope: userScope, syncId: required),
          ],
          legacyPrincipalCheckpoint: UplinkCheckpoint(
            scope: userScope,
            syncId: required,
          ),
          rejections: rejections,
        );
        await downlink.apply(
          DownlinkPage(
            scope: userScope,
            fromSyncId: syncId,
            throughSyncId: required,
            changes: const [],
          ),
          afterSyncId: syncId,
        );
        syncId = required;
      }

      for (; step < 80; step += 1) {
        switch (random.nextInt(9)) {
          case 0:
            final id = spaceIds[random.nextInt(spaceIds.length)];
            await act('FoundBook', [
              ModelCreateOperation(
                model: 'FamilySpace',
                id: id,
                values: {'name': 'book-$step'},
              ),
            ]);
          case 1:
            final index = random.nextInt(momentIds.length);
            await act('WritePage', [
              ModelCreateOperation(
                model: 'FamilyMoment',
                id: momentIds[index],
                values: {
                  'spaceId': parentOf(index).value,
                  'caption': 'page-$step',
                },
              ),
            ]);
          case 2:
            final index = random.nextInt(photoIds.length);
            await act('AttachPhoto', [
              ModelCreateOperation(
                model: 'FamilyPhoto',
                id: photoIds[index],
                values: {'momentId': momentOf(index).value},
              ),
            ]);
          case 3:
            await act('EditPage', [
              ModelUpdateOperation(
                model: 'FamilyMoment',
                id: momentIds[random.nextInt(momentIds.length)],
                patch: {'caption': 'edited-$step'},
              ),
            ]);
          case 4:
            // The cascade delete itself: a book takes its pages and photos.
            await act('BurnBook', [
              ModelDeleteOperation(
                model: 'FamilySpace',
                id: spaceIds[random.nextInt(spaceIds.length)],
              ),
            ]);
          case 5:
            await act('DeletePage', [
              ModelDeleteOperation(
                model: 'FamilyMoment',
                id: momentIds[random.nextInt(momentIds.length)],
              ),
            ]);
          case 6:
            final index = random.nextInt(momentIds.length);
            await claim(
              'FamilyMoment',
              {'id': momentOf(index).value.uuid},
              {'spaceId': parentOf(index).value.uuid, 'caption': 'truth-$step'},
            );
          case 7:
            // The Backend says a book is gone, or no longer visible.
            await claim('FamilySpace', {
              'id': spaceIds[random.nextInt(spaceIds.length)].value.uuid,
            }, null);
          case 8:
            await answerQueue();
        }
        await assertInvariant();
      }

      // Convergence: once the server has answered everything, no row is left
      // holding truth aside — every twin is empty and main IS the truth.
      // A window that fits any group: a small one can leave a group it cannot
      // hold whole standing, and convergence needs the queue actually empty.
      while ((await outbox.scheduledCandidate(limit: 100)) != null) {
        await answerQueue(limit: 100);
      }
      for (final id in spaceIds) {
        expect(await family.space.readBefore(id), isNull, reason: 'seed $seed');
      }
      for (final id in momentIds) {
        expect(
          await family.moment.readBefore(id),
          isNull,
          reason: 'seed $seed',
        );
      }
      for (final id in photoIds) {
        expect(await family.photo.readBefore(id), isNull, reason: 'seed $seed');
      }
    });
  }
}
