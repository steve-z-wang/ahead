import 'dart:async';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

/// A stand-in for a real transport: it binds each call to the caller's token
/// and asks for a credential exactly as one does.
final class _FakeTransport implements LocalSyncTransport {
  _FakeTransport(this.getAccessToken);

  final Future<String> Function() getAccessToken;
  final List<String> tokens = <String>[];
  final List<Uint8List> bodies = <Uint8List>[];
  int cancelCalls = 0;
  int closeCalls = 0;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents =>
      const Stream<DownlinkTransportEvent>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    tokens.add(await getAccessToken());
    bodies.add(body);
    bindLocalSyncCancellation(cancellation, _cancel);
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(const [1]),
    );
  }

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) async {
    tokens.add(await getAccessToken());
    bindLocalSyncCancellation(cancellation, _cancel);
    return LocalSyncHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(const [2]),
    );
  }

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async => bodies.add(frame);

  @override
  Future<void> restartDownlinkConnection() async {}

  @override
  Future<void> close() async {
    closeCalls += 1;
  }

  Future<void> _cancel() async {
    cancelCalls += 1;
  }
}

void main() {
  test(
    'every call asks for the latest credential and caches nothing',
    () async {
      var issued = 0;
      final transport = _FakeTransport(() async => 'token-${++issued}');

      await transport.sendUplink(Uint8List.fromList(const [9]));
      await transport.fetchDownlink(Uint8List.fromList(const [9]));

      expect(transport.tokens, ['token-1', 'token-2']);
    },
  );

  test('a bound call is cancelled through the caller token', () async {
    final transport = _FakeTransport(() async => 'token');
    final cancellation = LocalSyncCancellation();

    await transport.sendUplink(
      Uint8List.fromList(const [9]),
      cancellation: cancellation,
    );
    await cancellation.cancel();

    expect(cancellation.isCancelled, isTrue);
    expect(transport.cancelCalls, 1);
  });

  test('cancelling twice cancels each bound call once', () async {
    final transport = _FakeTransport(() async => 'token');
    final cancellation = LocalSyncCancellation();

    await transport.sendUplink(
      Uint8List.fromList(const [9]),
      cancellation: cancellation,
    );
    await cancellation.cancel();
    await cancellation.cancel();

    expect(transport.cancelCalls, 1);
  });

  test('a call bound to a spent token is cancelled at once', () async {
    final transport = _FakeTransport(() async => 'token');
    final cancellation = LocalSyncCancellation();
    await cancellation.cancel();

    await transport.sendUplink(
      Uint8List.fromList(const [9]),
      cancellation: cancellation,
    );
    await pumpEventQueue();

    expect(transport.cancelCalls, 1);
  });

  group('a status decides retry once, for every caller', () {
    test('a success carries its body through', () {
      expect(
        localSyncResponseBody(
          LocalSyncHttpResponse(
            statusCode: 200,
            body: Uint8List.fromList(const [7]),
          ),
        ),
        Uint8List.fromList(const [7]),
      );
    });

    for (final status in [408, 429, 500, 502, 503, 504]) {
      test('$status is retryable', () {
        expect(
          () => localSyncResponseBody(
            LocalSyncHttpResponse(statusCode: status, body: Uint8List(0)),
          ),
          throwsA(isA<LocalSyncRetryableTransportFailure>()),
        );
      });
    }

    for (final status in [400, 401, 403, 404, 409, 422, 426]) {
      test('$status is terminal', () {
        expect(
          () => localSyncResponseBody(
            LocalSyncHttpResponse(statusCode: status, body: Uint8List(0)),
          ),
          throwsA(isA<LocalSyncTerminalTransportFailure>()),
        );
      });
    }

    test('the failure keeps the status that named it', () {
      try {
        localSyncResponseBody(
          LocalSyncHttpResponse(statusCode: 503, body: Uint8List(0)),
        );
        fail('expected a failure');
      } on LocalSyncTransportFailure catch (failure) {
        expect(failure.status, 503);
      }
    });
  });
}
