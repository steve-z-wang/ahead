import 'dart:async';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

void main() {
  test('first nonempty scope set starts workers and transport once', () async {
    final events = <String>[];
    final downlink = FakeDownlinkWorker(events);
    final lifecycle = LocalSyncLifecycle(
      uplinkWorker: FakeWorker('uplink', events),
      downlinkWorker: downlink,
      transport: FakeTransport(events),
      bindLegacyCheckpointScope: (scopes) async =>
          events.add('legacy.bind:${scopes.join(',')}'),
    );

    await lifecycle.replaceScopes(const []);
    expect(events, isEmpty);

    await lifecycle.replaceScopes([userScope]);
    await lifecycle.replaceScopes([userScope, bookScope]);
    await lifecycle.close(() async => events.add('database.close'));

    expect(events, [
      'legacy.bind:User:a',
      'downlink.replace:User:a',
      'downlink.start',
      'uplink.start',
      'transport.start',
      'downlink.replace:User:a,Book:b',
      'downlink.close',
      'uplink.close',
      'transport.close',
      'database.close',
    ]);
  });

  test('close before first activation still closes every owner', () async {
    final events = <String>[];
    final lifecycle = LocalSyncLifecycle(
      uplinkWorker: FakeWorker('uplink', events),
      downlinkWorker: FakeDownlinkWorker(events),
      transport: FakeTransport(events),
      bindLegacyCheckpointScope: (_) async => events.add('legacy.bind'),
    );

    await lifecycle.close(() async => events.add('database.close'));

    expect(events, [
      'downlink.close',
      'uplink.close',
      'transport.close',
      'database.close',
    ]);
  });

  test('an open failure closes the transport and the database', () async {
    final events = <String>[];

    await LocalSyncLifecycle.closeAfterOpenFailure(
      transport: FakeTransport(events),
      closeDatabase: () async => events.add('database.close'),
    );

    expect(events, ['transport.close', 'database.close']);
  });
}

const userScope = 'User:a';
const bookScope = 'Book:b';

final class FakeWorker implements LocalSyncBackgroundWorker {
  const FakeWorker(this.name, this.events);
  final String name;
  final List<String> events;
  @override
  void start() => events.add('$name.start');
  @override
  Future<void> close() async => events.add('$name.close');
}

final class FakeDownlinkWorker implements LocalSyncDownlinkWorker {
  const FakeDownlinkWorker(this.events);
  final List<String> events;

  @override
  Future<void> replaceScopes(Iterable<String> scopes) async =>
      events.add('downlink.replace:${scopes.join(',')}');

  @override
  void start() => events.add('downlink.start');

  @override
  Future<void> close() async => events.add('downlink.close');
}

final class FakeTransport implements LocalSyncTransport {
  FakeTransport(this.events);
  final List<String> events;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents =>
      const Stream<DownlinkTransportEvent>.empty();
  @override
  Future<void> start() async => events.add('transport.start');
  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {}
  @override
  Future<void> restartDownlinkConnection() async {}
  @override
  Future<void> close() async => events.add('transport.close');
  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => throw UnimplementedError();
  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => throw UnimplementedError();
}
