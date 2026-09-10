import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('catches up on subscribe, then applies live and empty pages', () async {
    final directory = await Directory.systemTemp.createTemp(
      'local_sync_downlink_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/local-sync.sqlite';
    final transport = IntegrationTransport();
    final changeFailure = Completer<LocalSyncClientFailure>();
    final localSync = await LocalSync.open(
      driver: localSyncDatabaseDriver(path: path),
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
      failureObserver: (failure) {
        if (failure.error is DownlinkChangeException &&
            !changeFailure.isCompleted) {
          changeFailure.complete(failure);
        }
      },
    );
    await activateTestScopes(localSync);
    await transport.caughtUp.future;
    final userId = UserId(uuid(1));

    await localSync.transaction(
      (outerTx) => outerTx.mutate.registerUser(
        (tx) async => (user: User.create(id: userId.value, handle: 'steve')),
      ),
    );
    expect((await localSync.models.user.get(userId))?.handle, 'steve');

    await transport.uplinkRequest.future;
    transport.completeUplink();
    await pollDatabase(path, (database) {
      final rows = database.select(
        'SELECT required_sync_id FROM uplink_batches',
      );
      return rows.length == 1 && rows.single['required_sync_id'] == 102;
    });

    transport.emitPage(
      pageBytes(
        fromSyncId: 0,
        throughSyncId: 102,
        changes: [
          // A kind no SpaceKind member spells: the change fails, the page
          // does not, and the User beside it still lands. (Until CAP-407 this
          // change failed on the owner's missing FOREIGN KEY, which the
          // replica no longer has; then on a schema version, which CAP-481
          // deleted. An enum is what is left that is genuinely undecodable —
          // a value outside a closed set, rather than a shape the client
          // simply has not caught up to.)
          {
            'syncId': 101,
            'model': 'Space',
            'identity': {'id': uuid(9).uuid},
            'state': {
              'ownerId': uuid(8).uuid,
              'name': 'Missing',
              'kind': 'nonsense',
            },
          },
          {
            'syncId': 102,
            'model': 'User',
            'identity': {'id': uuid(1).uuid},
            'state': {'handle': 'steve'},
          },
        ],
      ),
    );
    final failure = await changeFailure.future;
    expect(failure.boundary, LocalSyncClientFailureBoundary.downlink);
    expect(failure.fate, LocalSyncClientFailureFate.continuing);
    final changeError = failure.error as DownlinkChangeException;
    expect(changeError.syncId, 101);
    expect(changeError.model, 'Space');
    expect((await localSync.models.user.get(userId))?.handle, 'steve');

    transport.emitPage(
      pageBytes(
        fromSyncId: 102,
        throughSyncId: 120,
        changes: const <Map<String, Object?>>[],
      ),
    );
    await pollDatabase(path, (database) {
      return database
              .select('SELECT last_applied_sync_id FROM downlink_scope_state')
              .single['last_applied_sync_id'] ==
          120;
    });
    expect(transport.downlinkPulls, 1);
    await localSync.close();

    final database = sqlite.sqlite3.open(path);
    database.execute('PRAGMA busy_timeout = 1000');
    expect(
      database
          .select('SELECT last_applied_sync_id FROM downlink_scope_state')
          .single['last_applied_sync_id'],
      120,
    );
    expect(
      database
          .select('SELECT COUNT(*) AS count FROM model_user')
          .single['count'],
      1,
    );
    expect(
      database
          .select('SELECT COUNT(*) AS count FROM pending_mutation_operations')
          .single['count'],
      0,
    );
    expect(
      database
          .select('SELECT COUNT(*) AS count FROM uplink_batches')
          .single['count'],
      0,
    );
    database.close();

    final reopenedTransport = ReopenTransport();
    final reopened = await LocalSync.open(
      driver: localSyncDatabaseDriver(path: path),
      clientId: testClientId,
      transport: reopenedTransport,
      prerequisites: readyPrerequisites(),
    );
    await activateTestScopes(reopened);
    await reopenedTransport.caughtUp.future;
    expect(reopenedTransport.downlinkPulls, 1);
    expect(reopenedTransport.requests.single, {
      'clientId': testClientId,
      'scope': testScope,
      'afterSyncId': 120,
    });
    expect((await reopened.models.user.get(userId))?.handle, 'steve');
    await reopened.close();
  });

  // CAP-407 spec §2. The replica tolerates arrival order: a child written
  // before anyone claimed its parent stands as written, and the parent's own
  // claim — whenever it lands — completes the picture.
  test('keeps a child written before its parent, then completes it', () async {
    final directory = await Directory.systemTemp.createTemp(
      'local_sync_arrival_order_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final transport = IntegrationTransport();
    final localSync = await LocalSync.open(
      driver: localSyncDatabaseDriver(
        path: '${directory.path}/local-sync.sqlite',
      ),
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
    );
    await activateTestScopes(localSync);
    addTearDown(localSync.close);
    await transport.caughtUp.future;
    await pumpUntil(() => transport.connects >= 1);

    final ownerId = UserId(uuid(4));
    final spaceId = SpaceId(uuid(5));
    await localSync.transaction(
      (outerTx) => outerTx.mutate.createSpace(
        (tx) async => (
          space: Space.create(
            id: spaceId.value,
            ownerId: ownerId.value,
            name: 'Child first',
            kind: SpaceKind.group,
            avatarKey: null,
          ),
        ),
      ),
    );
    transport.completeUplink();

    expect((await localSync.models.space.get(spaceId))?.name, 'Child first');
    expect(await localSync.models.user.get(ownerId), isNull);

    transport.emitPage(
      pageBytes(
        fromSyncId: 0,
        throughSyncId: 102,
        changes: [
          {
            'syncId': 102,
            'model': 'User',
            'identity': {'id': ownerId.value.uuid},
            'state': {'handle': 'owner'},
          },
        ],
      ),
    );

    await pumpUntilAsync(
      () async => await localSync.models.user.get(ownerId) != null,
    );
    expect((await localSync.models.space.get(spaceId))?.name, 'Child first');
  });

  test('a dropped stream reconnects and catches up from the cursor', () async {
    final directory = await Directory.systemTemp.createTemp(
      'local_sync_reconnect_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final transport = IntegrationTransport();
    final localSync = await LocalSync.open(
      driver: localSyncDatabaseDriver(
        path: '${directory.path}/local-sync.sqlite',
      ),
      clientId: testClientId,
      transport: transport,
      prerequisites: readyPrerequisites(),
    );
    await activateTestScopes(localSync);
    addTearDown(localSync.close);
    await transport.caughtUp.future;
    await pumpUntil(() => transport.connects >= 1);

    transport.emitPage(
      pageBytes(
        fromSyncId: 0,
        throughSyncId: 12,
        changes: [
          {
            'syncId': 12,
            'model': 'User',
            'identity': {'id': uuid(2).uuid},
            'state': {'handle': 'ana'},
          },
        ],
      ),
    );
    await pumpUntilAsync(
      () async => await localSync.models.user.get(UserId(uuid(2))) != null,
    );

    // The server goes away mid-stream. The page it never delivered arrives
    // through the catch-up the reconnect schedules.
    transport.nextPull = pageBytes(
      fromSyncId: 12,
      throughSyncId: 30,
      changes: [
        {
          'syncId': 30,
          'model': 'User',
          'identity': {'id': uuid(3).uuid},
          'state': {'handle': 'bo'},
        },
      ],
    );
    await transport.dropStream();

    await pumpUntil(() => transport.connects >= 2);
    await pumpUntilAsync(
      () async => await localSync.models.user.get(UserId(uuid(3))) != null,
    );
    expect((await localSync.models.user.get(UserId(uuid(3))))?.handle, 'bo');
    expect(
      transport.requests,
      anyElement(
        equals({
          'clientId': testClientId,
          'scope': testScope,
          'afterSyncId': 12,
        }),
      ),
    );
  });
}

Future<void> pollDatabase(
  String path,
  bool Function(sqlite.Database database) condition,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final database = sqlite.sqlite3.open(path);
    try {
      database.execute('PRAGMA busy_timeout = 1000');
      if (condition(database)) return;
    } finally {
      database.close();
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('database condition was not reached');
}

Future<void> pumpUntil(bool Function() condition) =>
    pumpUntilAsync(() async => condition());

Future<void> pumpUntilAsync(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 500; attempt += 1) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('condition was not reached');
}

class IntegrationTransport implements LocalSyncTransport {
  final uplinkRequest = Completer<void>();
  final caughtUp = Completer<void>();
  final _uplinkResponse = Completer<void>();
  final requests = <Map<String, Object?>>[];
  int downlinkPulls = 0;
  int connects = 0;

  /// The page the next catch-up answers with, instead of "nothing new".
  Uint8List? nextPull;

  final _events = StreamController<DownlinkTransportEvent>.broadcast();

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async => connect();

  /// The channel is open — the first time and after every reconnect.
  void connect() {
    connects += 1;
    if (!_events.isClosed) _events.add(const DownlinkConnected());
  }

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    final request = (jsonDecode(utf8.decode(frame)) as Map)
        .cast<String, Object?>();
    emitPage(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'type': 'subscribed',
            'scopes': request['scopes'],
            'rejections': <Object?>[],
          }),
        ),
      ),
    );
  }

  @override
  Future<void> restartDownlinkConnection() async => connect();

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    if (!uplinkRequest.isCompleted) uplinkRequest.complete();
    await _uplinkResponse.future;
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: uplinkResponseBytes(102),
    );
  }

  void completeUplink() => _uplinkResponse.complete();

  void emitPage(Uint8List page) {
    if (!_events.isClosed) _events.add(DownlinkPageReceived(page));
  }

  /// A dropped channel is one the transport opens again, and says so.
  Future<void> dropStream() async {
    connect();
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    downlinkPulls += 1;
    final cursor = afterSyncIdOf(body);
    requests.add({
      'clientId': clientIdOf(body),
      'scope': scopeOf(body),
      'afterSyncId': cursor,
    });
    if (!caughtUp.isCompleted) caughtUp.complete();
    final scripted = nextPull;
    if (scripted != null) {
      nextPull = null;
      return LocalSyncHttpResponse(statusCode: 200, body: scripted);
    }
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: emptyPageBytes(cursor, scope: scopeOf(body)),
    );
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

final class ReopenTransport extends IntegrationTransport {}

UUID uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
