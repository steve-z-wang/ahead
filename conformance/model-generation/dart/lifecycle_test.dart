import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_database/local_sync_database.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('open stays dormant until the first scope is activated', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final driver = TrackingDatabaseDriver(database.driver);
    final transport = LifecycleTransport();

    final localSync = await LocalSync.open(
      driver: driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
    );

    expect(transport.connects, 0);
    expect(transport.pullRequests, isEmpty);
    await localSync.close();
    expect(driver.opened?.closed, isTrue);
    expect(transport.closed, isTrue);
  });

  test('an arbitrary text scope does not need registration', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final driver = TrackingDatabaseDriver(database.driver);
    final transport = LifecycleTransport();

    final localSync = await LocalSync.open(
      driver: driver,
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
    );
    await localSync.transaction(
      (tx) => tx.scopes.set('Bogus:punctuation/and spaces'),
    );
    await localSync.start();
    await transport.pulled.future;
    expect(transport.connects, 1);
    await localSync.transaction(
      (tx) => tx.scopes.remove('Bogus:punctuation/and spaces'),
    );
    await localSync.close();
    expect(driver.opened?.closed, isTrue);
    expect(transport.closed, isTrue);
  });

  test('close delegates database lifecycle failures', () async {
    final database = await TestDatabase.create();
    addTearDown(database.dispose);
    final localSync = await LocalSync.open(
      driver: database.driver,
      clientId: testClientId,
      transport: successLocalSyncTransport,
      prerequisites: readyPrerequisites(),
    );
    await localSync.close();

    await expectLater(
      localSync.models.user.get(UserId(uuid(1))),
      throwsA(anything),
    );
    await expectLater(
      localSync.transaction(
        (outerTx) => outerTx.mutate.registerUser(
          (tx) async => (user: User.create(id: uuid(1), handle: 'steve')),
        ),
      ),
      throwsA(anything),
    );
  });

  test(
    'subscribes, catches up from the durable cursor, and owns close',
    () async {
      final transport = LifecycleTransport();
      final database = await TestDatabase.create();
      addTearDown(database.dispose);
      final localSync = await LocalSync.open(
        driver: database.driver,
        clientId: testClientId,
        transport: transport,
        prerequisites: readyPrerequisites(),
      );
      await activateTestScopes(localSync);

      await transport.pulled.future;
      // The live channel carries no cursor; the pull is where the client says
      // where it stands, and opening the channel is what asks it to.
      expect(transport.connects, 1);
      expect(transport.pullRequests.first, {
        'clientId': testClientId,
        'scope': testScope,
        'afterSyncId': 0,
      });

      await localSync.close();
      expect(transport.closed, isTrue);
    },
  );
}

final class TrackingDatabaseDriver implements DatabaseDriver {
  TrackingDatabaseDriver(this.delegate);

  final DatabaseDriver delegate;
  TrackingDatabase? opened;

  @override
  Future<Database> open() async {
    final database = TrackingDatabase(await delegate.open());
    opened = database;
    return database;
  }
}

final class TrackingDatabase implements Database {
  TrackingDatabase(this.delegate);

  final Database delegate;
  bool closed = false;

  @override
  Future<DatabaseExecutionResult> execute(DatabaseStatement statement) =>
      delegate.execute(statement);

  @override
  Future<DatabaseQueryResult> query(DatabaseQuery query) =>
      delegate.query(query);

  @override
  Future<T> transaction<T>(
    Future<T> Function(DatabaseTransaction transaction) work,
  ) => delegate.transaction(work);

  @override
  Stream<DatabaseQueryResult> watch(DatabaseQuery query) =>
      delegate.watch(query);

  @override
  Stream<void> watchTables(Set<String> tables) => delegate.watchTables(tables);

  @override
  Future<void> close() async {
    await delegate.close();
    closed = true;
  }
}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);

final class LifecycleTransport implements LocalSyncTransport {
  final pulled = Completer<void>();
  final pullRequests = <Map<String, Object?>>[];
  final _events = StreamController<DownlinkTransportEvent>.broadcast();
  int connects = 0;
  bool closed = false;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async {
    connects += 1;
    if (!_events.isClosed) _events.add(const DownlinkConnected());
  }

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    final request = (jsonDecode(utf8.decode(frame)) as Map)
        .cast<String, Object?>();
    _events.add(
      DownlinkPageReceived(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'type': 'subscribed',
              'scopes': request['scopes'],
              'rejections': <Object?>[],
            }),
          ),
        ),
      ),
    );
  }

  @override
  Future<void> restartDownlinkConnection() => start();

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => throw StateError('no Uplink request expected');

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    pullRequests.add(_describe(body));
    if (!pulled.isCompleted) pulled.complete();
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: emptyPageBytes(afterSyncIdOf(body), scope: scopeOf(body)),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_events.isClosed) await _events.close();
  }

  Map<String, Object?> _describe(Uint8List body) => {
    'clientId': clientIdOf(body),
    'scope': scopeOf(body),
    'afterSyncId': afterSyncIdOf(body),
  };
}
