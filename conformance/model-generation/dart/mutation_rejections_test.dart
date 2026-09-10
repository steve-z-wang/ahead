import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart'
    show
        LocalSyncTransport,
        LocalSyncHttpResponse,
        LocalSyncCancellation,
        DownlinkTransportEvent;
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('closing LocalSync completes active rejection subscriptions', () async {
    final directory = await Directory.systemTemp.createTemp('rejection_close_');
    addTearDown(() => directory.delete(recursive: true));
    final sync = await LocalSync.open(
      driver: localSyncDatabaseDriver(path: '${directory.path}/local.sqlite'),
      clientId: testClientId,
      transport: _RejectingTransport(),
      prerequisites: readyPrerequisites(),
    );
    final initial = Completer<void>();
    final done = Completer<void>();
    final subscription = sync.mutations.watchRejections().listen((_) {
      if (!initial.isCompleted) initial.complete();
    }, onDone: done.complete);
    addTearDown(subscription.cancel);
    await initial.future.timeout(const Duration(seconds: 5));
    await sync.close();
    await done.future.timeout(const Duration(seconds: 2));
  });
  test(
    'generated LocalSync exposes durable rejection values and acknowledgment',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rejection_facade_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final driver = localSyncDatabaseDriver(
        path: '${directory.path}/local.sqlite',
      );
      var sync = await LocalSync.open(
        driver: driver,
        clientId: testClientId,
        transport: _RejectingTransport(),
        prerequisites: readyPrerequisites(),
      );
      final results = StreamIterator<List<LocalSyncMutationRejection>>(
        sync.mutations.watchRejections(),
      );
      expect(await results.moveNext(), isTrue);
      expect(results.current, isEmpty);
      final id = UserId(UUID.withValidation(testClientId));
      await sync.transaction(
        (tx) => tx.mutate.registerUser((mutation) async {
          await mutation.scopes.set('Custom:companion');
          return (user: User.create(id: id.value, handle: 'unsent handle'));
        }),
      );
      await activateTestScopes(sync);
      expect(
        await results.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      final LocalSyncMutationRejection rejection = results.current.single;
      final LocalSyncMutationRejectionId handle = rejection.id;
      final LocalSyncRejectedOperation operation = rejection.operations.single;
      expect(rejection.mutationName, 'RegisterUser');
      expect(rejection.code, 'unknown.future_reason');
      final LocalSyncRejectedScope scope = rejection.scopes.single;
      expect(scope.scope, 'Custom:companion');
      expect(scope.desired, isTrue);
      expect(operation.values['handle'], 'unsent handle');
      expect(await sync.models.user.get(id), isNull);
      await results.cancel();
      await sync.close();

      sync = await LocalSync.open(
        driver: driver,
        clientId: testClientId,
        transport: _RejectingTransport(),
        prerequisites: readyPrerequisites(),
      );
      addTearDown(() => sync.close());
      expect((await sync.mutations.watchRejections().first).single.id, handle);
      await sync.transaction((tx) async {
        final TransactionMutationsInbox mutations = tx.mutations;
        expect((await mutations.getRejection(handle))!.id, handle);
        await mutations.acknowledgeRejection(handle);
        expect(await mutations.getRejection(handle), isNull);
      });
      expect(await sync.mutations.watchRejections().first, isEmpty);
    },
  );
}

final class _RejectingTransport implements LocalSyncTransport {
  final _delegate = SuccessLocalSyncTransport();

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _delegate.downlinkEvents;
  @override
  Future<void> start() => _delegate.start();
  @override
  Future<void> close() => _delegate.close();
  @override
  Future<void> restartDownlinkConnection() =>
      _delegate.restartDownlinkConnection();
  @override
  Future<void> sendDownlinkFrame(Uint8List frame) =>
      _delegate.sendDownlinkFrame(frame);
  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _delegate.fetchDownlink(body, cancellation: cancellation);
  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    final request = jsonDecode(utf8.decode(body)) as Map;
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'requiredScope': testScope,
            'requiredSyncId': 0,
            'rejections': [
              for (final mutation in request['mutations'] as List)
                {
                  'ordinal': (mutation as Map)['ordinal'],
                  'code': 'unknown.future_reason',
                },
            ],
          }),
        ),
      ),
    );
  }
}
