import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';
import 'package:local_sync_database/local_sync_database.dart';

const testClientId = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
const testScope = 'User:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
final testInitialScopes = [testScope];

/// A transport that accepts every Uplink batch and never has a page to give.
/// The live channel stays open for the life of the test: a client that is up
/// to date is a client sitting on a silent channel.
final class SuccessLocalSyncTransport implements LocalSyncTransport {
  final bodies = <Uint8List>[];
  final firstSend = Completer<void>();
  final _events = StreamController<DownlinkTransportEvent>.broadcast(
    onListen: () {},
  );

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async {
    if (!_events.isClosed) _events.add(const DownlinkConnected());
  }

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    bodies.add(body);
    if (!firstSend.isCompleted) firstSend.complete();
    // This fixture never publishes canonical rows, so acknowledge a future
    // checkpoint and leave optimism pending. Zero would falsely claim that
    // the empty Downlink already includes the write.
    return _ok(uplinkResponseBytes(1));
  }

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async => _ok(emptyPageBytes(afterSyncIdOf(body), scope: scopeOf(body)));

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    final envelope = _decode(frame);
    if (envelope['type'] != 'subscribe') {
      throw StateError('expected subscribe handshake');
    }
    _events.add(
      DownlinkPageReceived(
        _encode({
          'type': 'subscribed',
          'scopes': envelope['scopes'],
          'rejections': <Object?>[],
        }),
      ),
    );
  }

  @override
  Future<void> restartDownlinkConnection() async {
    if (!_events.isClosed) _events.add(const DownlinkConnected());
  }

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

LocalSyncHttpResponse _ok(Uint8List body) =>
    LocalSyncHttpResponse(statusCode: 200, body: body);

final successLocalSyncTransport = SuccessLocalSyncTransport();

Future<void> activateTestScopes(
  LocalSync localSync, [
  Iterable<String>? scopes,
]) async {
  await localSync.transaction((tx) async {
    for (final scope in scopes ?? testInitialScopes) {
      await tx.scopes.set(scope);
    }
  });
  await localSync.start();
}

Map<String, Object?> _decode(Uint8List bytes) =>
    (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

Uint8List _encode(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

int afterSyncIdOf(Uint8List requestBytes) =>
    _decode(requestBytes)['fromCursor']! as int;

String scopeOf(Uint8List requestBytes) =>
    _decode(requestBytes)['scope']! as String;

String clientIdOf(Uint8List requestBytes) =>
    _decode(requestBytes)['clientId']! as String;

Uint8List uplinkResponseBytes(int requiredSyncId, {String? scope}) => _encode({
  'requiredScope': scope ?? testScope,
  'requiredSyncId': requiredSyncId,
  'rejections': <Object?>[],
});

Uint8List emptyPageBytes(int syncId, {String? scope}) => pageBytes(
  scope: scope,
  fromSyncId: syncId,
  throughSyncId: syncId,
  changes: const <Map<String, Object?>>[],
);

Uint8List pageBytes({
  String? scope,
  required int fromSyncId,
  required int throughSyncId,
  required List<Map<String, Object?>> changes,
}) => _encode({
  'scope': scope ?? testScope,
  'fromCursor': fromSyncId,
  'toCursor': throughSyncId,
  'changes': changes,
});

final class TestDatabase {
  TestDatabase._(this.directory);

  final Directory directory;

  String get path => '${directory.path}/local-sync.sqlite';

  DatabaseDriver get driver => localSyncDatabaseDriver(path: path);

  static Future<TestDatabase> create() async => TestDatabase._(
    await Directory.systemTemp.createTemp('local_sync_conformance_'),
  );

  Future<void> dispose() async {
    try {
      await directory.delete(recursive: true);
    } on PathNotFoundException {
      // Cleanup may race another teardown after both observed the directory.
      // Absence is already the postcondition, so disposal stays idempotent.
    }
  }
}
