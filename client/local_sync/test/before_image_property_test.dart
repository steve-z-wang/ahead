import 'dart:math';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import 'support/test_database.dart';
import 'support/test_model.dart';

/// CAP-393 spec §7, pinned rather than argued: after every step, for every
/// row, the main table equals its truth with the surviving edits replayed on
/// top, and a before-image exists exactly for the rows that carry pending
/// edits.
///
/// The sequences are randomized but seeded, so a failure names the seed and
/// replays exactly.
void main() {
  const clientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
  const rowCount = 4;

  for (final seed in [1, 7, 42, 1337, 90210]) {
    test('holds over a random history (seed $seed)', () async {
      final random = Random(seed);
      final fixture = await TestLocalDatabase.open(
        modelStatements: testModelStatements,
      );
      addTearDown(fixture.close);

      final main = SqlCanonicalStore<TestId>(
        database: fixture.scope,
        descriptor: testDescriptor,
      );
      final before = BeforeImageStore<TestId>(
        database: fixture.scope,
        main: testDescriptor,
        before: testBeforeDescriptor,
      );
      final mutations = SqlMutationStore<TestId>(
        database: fixture.scope,
        schema: testSchema,
      );
      final writer = ModelMutationWriter<TestId>(
        mutations,
        before: before,
        main: main,
      );
      final registry = ModelRegistry([
        TypedModelRegistryEntry<TestId>(
          schema: testSchema,
          canonical: main,
          before: before,
          mutations: mutations,
        ),
      ]);
      final direct = DirectModelWriter<TestId>(
        main,
        before: before,
        mutations: mutations,
      );
      final contexts =
          TransactionContextFactory<ModelWriter<TestId>, _TestMutations>(
            database: fixture.scope,
            registry: registry,
            targets: Map.fromEntries([mutationTarget<TestId>('Test', writer)]),
            buildModels: (context) => TransactionModelWriter<TestId>(
              context: context,
              direct: direct,
              queued: writer,
            ),
            buildTransactionScopes: (_) => const _TestScopes(),
            buildMutationScopes: (_) => const _TestScopes(),
            buildMutations: _TestMutations.new,
          );
      final executor = TransactionExecutor<ModelWriter<TestId>, _TestMutations>(
        database: fixture.scope,
        contexts: contexts,
      );
      final outbox = MutationQueue(fixture.scope, registry: registry);
      await outbox.initialize(clientId);
      final entry = registry['Test']!;
      final replay = MutationReducer(testSchema);

      final ids = [
        for (var index = 0; index < rowCount; index += 1) testId(index),
      ];
      var step = 0;

      Future<void> assertInvariant() async {
        for (final id in ids) {
          final truth = await before.read(id);
          final queue = await mutations.read(id);
          final actual = await main.get(id);

          // Sparsity: truth is held only for a row that carries pending
          // edits. A row with nothing pending IS truth, so holding a copy of
          // it would be dead weight the next rebuild would act on.
          if (truth != null) {
            expect(
              queue,
              isNotEmpty,
              reason:
                  'seed $seed step $step row $id: truth is held for a row '
                  'with nothing pending',
            );
          }

          // The merged view: for a dirty row, main is truth with the
          // surviving edits replayed on top. A clean row is truth itself,
          // and nothing is held to compare it against.
          if (queue.isEmpty) continue;
          final ModelRecord<TestId>? expected;
          try {
            expected = replay.reduce(truth, queue);
          } on ProjectionIntegrityException {
            // The queue can no longer be replayed against the truth beneath
            // it — the server deleted a row being edited, or created one
            // being created. Those edits are doomed and the rejection on its
            // way restores the row; until then there is no merged view to
            // compare against, by definition.
            continue;
          }
          expect(
            actual?.fields,
            expected?.fields,
            reason:
                'seed $seed step $step row $id: main is not '
                'replay(before, queue)',
          );
        }
      }

      /// One named act, applied as one transaction: a failure part way through
      /// applies nothing at all, which is itself part of what is under test.
      Future<void> act(String name, ModelOperation operation) async {
        try {
          await executor.run(
            (tx) => tx.mutate.run(
              name: name,
              build: (_) async => (operation: operation),
              record: (result) => MutationRecord(
                name: name,
                slotOperations: [
                  MutationSlotOperation(
                    slotName: 'wire',
                    operation: result.operation,
                    allowedPatchFields: result.operation is ModelUpdateOperation
                        ? (result.operation as ModelUpdateOperation).patch.keys
                        : null,
                  ),
                ],
              ),
            ),
          );
        } on DatabaseException {
          // A double create, or an edit of a row that is not there.
        } on LocalStorageException {
          // Same, surfaced by the store's affected-row check.
        }
      }

      for (; step < 120; step += 1) {
        final id = ids[random.nextInt(ids.length)];
        switch (random.nextInt(6)) {
          case 0:
            await act(
              'Create',
              ModelCreateOperation(
                model: 'Test',
                id: id,
                values: {
                  'name': 'created-$step',
                  'note': random.nextBool() ? 'note-$step' : null,
                },
              ),
            );
          case 1:
            await act(
              'Rename',
              ModelUpdateOperation(
                model: 'Test',
                id: id,
                patch: {'name': 'updated-$step'},
              ),
            );
          case 2:
            await act('Remove', ModelDeleteOperation(model: 'Test', id: id));
          case 3:
            // Server truth arrives for this row.
            await fixture.scope.transaction((_) async {
              await entry.replaceTruth(id, {
                'name': 'truth-$step',
                'note': null,
              });
              await entry.rebuild(id);
            });
          case 4:
            // Server deletes the row.
            await fixture.scope.transaction((_) async {
              await entry.replaceTruth(id, null);
              await entry.rebuild(id);
            });
          case 5:
            // The server answers the queue. Its claim always lands first —
            // settlement is gated on the Downlink having caught up — so the
            // truth for each touched row arrives before its edits settle.
            final pending = await mutations.readAll();
            if (pending.isEmpty) break;
            final rejected = pending
                .where((mutation) => random.nextBool())
                .map((mutation) => mutation.position.mutationOrdinal)
                .toSet();
            final touched = {for (final mutation in pending) mutation.id};
            await fixture.scope.transaction((_) async {
              for (final rowId in touched) {
                final current = await main.get(rowId);
                await entry.replaceTruth(
                  rowId,
                  current == null
                      ? null
                      : {
                          'name': current.fields['name'],
                          'note': current.fields['note'],
                        },
                );
                await entry.rebuild(rowId);
              }
              for (final mutation in pending) {
                await fixture.scope.current.execute(
                  DatabaseStatement(
                    sql: 'DELETE FROM pending_mutations WHERE ordinal = ?',
                    variables: [mutation.position.mutationOrdinal],
                  ),
                );
                if (rejected.contains(mutation.position.mutationOrdinal)) {
                  await entry.rebuild(mutation.id);
                } else {
                  await entry.settle(mutation.id);
                }
              }
            });
        }
        await assertInvariant();
      }

      // Reject everything the server never answered. Convergence is the
      // point: whatever history ran, once no edit is pending the client holds
      // no truth aside — every twin is empty and main IS the truth.
      final remaining = await mutations.readAll();
      await fixture.scope.transaction((_) async {
        for (final mutation in remaining) {
          await fixture.scope.current.execute(
            DatabaseStatement(
              sql: 'DELETE FROM pending_mutations WHERE ordinal = ?',
              variables: [mutation.position.mutationOrdinal],
            ),
          );
          await entry.rebuild(mutation.id);
        }
      });
      for (final id in ids) {
        expect(
          await before.exists(id),
          isFalse,
          reason: 'seed $seed: a settled client holds no before-images',
        );
      }
      expect(await mutations.readAll(), isEmpty);
    });
  }
}

final class _TestMutations {
  const _TestMutations(this._executor);

  final MutationScopeExecutor<ModelWriter<TestId>> _executor;

  Future<void> run<R extends Object>({
    required String name,
    required Future<R?> Function(LocalSyncMutationScope<ModelWriter<TestId>>)
    build,
    required MutationRecord Function(R) record,
  }) => _executor.run(name: name, build: build, record: record);
}

final class _TestScopes implements TransactionScopes, MutationScopes {
  const _TestScopes();

  @override
  Future<void> remove(String scope) =>
      throw UnsupportedError('scope writes are outside this property');

  @override
  Future<void> set(String scope) =>
      throw UnsupportedError('scope writes are outside this property');
}
