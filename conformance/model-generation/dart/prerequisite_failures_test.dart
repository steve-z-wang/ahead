import 'dart:async';
import 'dart:io';

import 'package:local_sync/local_sync.dart' show PrerequisiteAttemptResult;
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test(
    'generated runtime exposes both inbox APIs and closes their streams',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'prerequisite_facade_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final wire = SuccessLocalSyncTransport();
      final sync = await LocalSync.open(
        driver: localSyncDatabaseDriver(path: '${directory.path}/local.sqlite'),
        clientId: testClientId,
        transport: wire,
        prerequisites: LocalSyncPrerequisiteHandlers(
          remoteLabel: ({required key}) async =>
              PrerequisiteAttemptResult.failed,
        ),
      );
      addTearDown(sync.close);
      final owner = UUID.withValidation(testClientId);
      final id = UUID.withValidation('11111111-1111-4111-8111-111111111111');
      final values = <List<LocalSyncPrerequisiteFailure>>[];
      final closed = Completer<void>();
      final sub = sync.prerequisites.watchFailures().listen(
        values.add,
        onDone: closed.complete,
      );
      addTearDown(sub.cancel);
      final requiredClosed = Completer<void>();
      final required = sync.prerequisites.watchRequired().listen(
        (_) {},
        onDone: requiredClosed.complete,
      );
      addTearDown(required.cancel);
      await sync.transaction((tx) async {
        await tx.models.user.create(id: owner, handle: 'owner');
        await tx.mutate.createSpace((mutation) async {
          await mutation.scopes.set('companion-scope');
          await mutation.models.user.update(
            id: UserId(owner),
            handle: 'optimistic companion',
          );
          return (
            space: Space.create(
              id: id,
              ownerId: owner,
              name: 'Local space',
              kind: SpaceKind.personal,
              avatarKey: 'failed-label',
            ),
          );
        });
      });
      await activateTestScopes(sync);
      final LocalSyncPrerequisiteFailure item =
          (await sync.prerequisites
                  .watchFailures()
                  .firstWhere((items) => items.isNotEmpty)
                  .timeout(const Duration(seconds: 5)))
              .single;
      final LocalSyncPrerequisiteFailureId handle = item.id;
      final LocalSyncFailedPrerequisite cause = item.causes.single;
      final LocalSyncPrerequisiteBinding binding = cause.bindings.single;
      expect(item.mutationName, 'CreateSpace');
      expect(cause.invocation.name, 'RemoteLabel');
      expect(cause.invocation.arguments, {'key': 'failed-label'});
      expect(binding.slotName, 'space');
      expect(binding.field, 'avatarKey');
      expect(await sync.models.space.get(SpaceId(id)), isNotNull);
      expect(wire.bodies, isEmpty);
      expect(
        (await sync.models.user.get(UserId(owner)))!.handle,
        'optimistic companion',
      );
      expect(
        (await sync.readOnlySql.query(
          "SELECT scope FROM pending_mutation_scopes WHERE scope = 'companion-scope'",
        )).rows,
        isNotEmpty,
      );
      expect(await sync.mutations.watchRejections().first, isEmpty);
      final LocalSyncOperationSnapshot operation = item.operations.last;
      expect(operation.slotName, 'space');
      await sync.transaction((tx) async {
        final TransactionPrerequisites prerequisites = tx.prerequisites;
        expect((await prerequisites.getFailure(handle))!.id, handle);
        await prerequisites.discard(handle);
        await prerequisites.retry([cause.invocation]);
        expect(await prerequisites.getFailure(handle), isNull);
      });
      expect(await sync.models.space.get(SpaceId(id)), isNull);
      expect((await sync.models.user.get(UserId(owner)))!.handle, 'owner');
      expect(
        (await sync.readOnlySql.query(
          "SELECT scope FROM pending_mutation_scopes WHERE scope = 'companion-scope'",
        )).rows,
        isEmpty,
      );
      expect(await sync.prerequisites.watchFailures().first, isEmpty);
      expect(await sync.mutations.watchRejections().first, isEmpty);
      await sync.close();
      await closed.future.timeout(const Duration(seconds: 2));
      await requiredClosed.future.timeout(const Duration(seconds: 2));
    },
  );
}
