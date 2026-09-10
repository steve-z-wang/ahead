import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

/// A live channel the test drives frame by frame.
final class _FakeSocket implements LocalSyncSocket {
  final _frames = StreamController<Uint8List>();
  final sent = <Uint8List>[];
  int closeCalls = 0;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> send(Uint8List frame) async => sent.add(frame);

  @override
  Future<void> close() async {
    closeCalls += 1;
    if (!_frames.isClosed) await _frames.close();
  }

  void deliver(Uint8List page) => _frames.add(page);

  Future<void> drop() async {
    if (!_frames.isClosed) await _frames.close();
  }
}

/// One recorded request, as the far side saw it.
final class _Received {
  _Received(this.path, this.authorization, this.contentType, this.body);
  final String path;
  final String? authorization;
  final String? contentType;
  final String body;
}

void main() {
  late HttpServer server;
  late List<_Received> received;
  late int status;
  late String responseBody;

  setUp(() async {
    received = <_Received>[];
    status = 200;
    responseBody = '{"ok":true}';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      server.forEach((request) async {
        received.add(
          _Received(
            request.uri.path,
            request.headers.value(HttpHeaders.authorizationHeader),
            request.headers.contentType?.mimeType,
            await utf8.decoder.bind(request).join(),
          ),
        );
        request.response.statusCode = status;
        request.response.write(responseBody);
        await request.response.close();
      }),
    );
  });

  tearDown(() async => server.close(force: true));

  Uri baseUri() => Uri.parse('http://127.0.0.1:${server.port}/');

  RestWsTransport build({
    LocalSyncSocketConnector? connect,
    RestWsSleep? sleep,
    LocalSyncClientFailureObserver? failureObserver,
  }) => RestWsTransport(
    baseUri: baseUri(),
    getAccessToken: () async => 'token-1',
    connect: connect,
    sleep: sleep ?? (_) async {},
    failureObserver: failureObserver,
  );

  group('the two request calls', () {
    test('an Uplink goes to the mutations route with its credential', () async {
      final transport = build();

      final response = await transport.sendUplink(
        Uint8List.fromList(utf8.encode('{"clientId":"c"}')),
      );
      await transport.close();

      expect(response.statusCode, 200);
      expect(utf8.decode(response.body), '{"ok":true}');
      expect(received.single.path, '/sync/mutations');
      expect(received.single.authorization, 'Bearer token-1');
      expect(received.single.contentType, 'application/json');
      expect(received.single.body, '{"clientId":"c"}');
    });

    test('a Downlink pull goes to the pull route', () async {
      final transport = build();

      await transport.fetchDownlink(
        Uint8List.fromList(utf8.encode('{"fromCursor":0}')),
      );
      await transport.close();

      expect(received.single.path, '/sync/pull');
    });

    test('a refusal is carried back as its status, not an exception', () async {
      status = 503;
      responseBody = 'busy';
      final transport = build();

      final response = await transport.sendUplink(Uint8List(0));
      await transport.close();

      expect(response.statusCode, 503);
      expect(
        () => localSyncResponseBody(response),
        throwsA(isA<LocalSyncRetryableTransportFailure>()),
      );
    });

    test('a call that never reached an answer is retryable', () async {
      final transport = RestWsTransport(
        baseUri: Uri.parse('http://127.0.0.1:1/'),
        getAccessToken: () async => 'token-1',
        connect: (_, _) async => _FakeSocket(),
        sleep: (_) async {},
      );

      await expectLater(
        transport.sendUplink(Uint8List(0)),
        throwsA(isA<LocalSyncRetryableTransportFailure>()),
      );
      await transport.close();
    });

    test('a cancelled call ends as cancelled', () async {
      final transport = build();
      final cancellation = LocalSyncCancellation();
      unawaited(cancellation.cancel());

      await expectLater(
        transport.sendUplink(Uint8List(0), cancellation: cancellation),
        throwsA(isA<LocalSyncCancelledTransportFailure>()),
      );
      await transport.close();
    });

    test('a call after close is cancelled rather than attempted', () async {
      final transport = build();
      await transport.close();

      await expectLater(
        transport.sendUplink(Uint8List(0)),
        throwsA(isA<LocalSyncCancelledTransportFailure>()),
      );
      expect(received, isEmpty);
    });
  });

  group('the live channel', () {
    test('sends an opaque application frame on the open socket', () async {
      final socket = _FakeSocket();
      final transport = build(connect: (_, _) async => socket);

      await transport.start();
      await pumpEventQueue();
      await transport.sendDownlinkFrame(
        Uint8List.fromList(utf8.encode('subscribe')),
      );
      await transport.close();

      expect(utf8.decode(socket.sent.single), 'subscribe');
    });

    test(
      'restarting the live connection closes it and opens another',
      () async {
        final sockets = <_FakeSocket>[];
        final transport = build(
          connect: (_, _) async {
            final socket = _FakeSocket();
            sockets.add(socket);
            return socket;
          },
        );

        await transport.start();
        await pumpUntil(() => sockets.isNotEmpty);
        await transport.restartDownlinkConnection();
        await pumpUntil(() => sockets.length == 2);
        await transport.close();

        expect(sockets.first.closeCalls, 1);
      },
    );

    test('says it is open, then hands pages up as they arrive', () async {
      final socket = _FakeSocket();
      final transport = build(connect: (_, _) async => socket);
      final events = <DownlinkTransportEvent>[];
      transport.downlinkEvents.listen(events.add);

      await transport.start();
      await pumpEventQueue();
      socket.deliver(Uint8List.fromList(utf8.encode('page-1')));
      await pumpEventQueue();
      await transport.close();

      expect(events.first, isA<DownlinkConnected>());
      expect(utf8.decode((events[1] as DownlinkPageReceived).page), 'page-1');
    });

    test('carries the credential into the handshake', () async {
      final tokens = <String>[];
      final transport = build(
        connect: (_, token) async {
          tokens.add(token);
          return _FakeSocket();
        },
      );

      await transport.start();
      await pumpEventQueue();
      await transport.close();

      expect(tokens, ['token-1']);
    });

    test('opens the live route as a socket scheme', () async {
      final uris = <Uri>[];
      final transport = build(
        connect: (uri, _) async {
          uris.add(uri);
          return _FakeSocket();
        },
      );

      await transport.start();
      await pumpEventQueue();
      await transport.close();

      expect(uris.single.scheme, 'ws');
      expect(uris.single.path, '/sync/live');
    });

    test('a dropped channel is opened again, and says so', () async {
      final sockets = <_FakeSocket>[];
      final transport = build(
        connect: (_, _) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
      );
      final connects = <DownlinkTransportEvent>[];
      transport.downlinkEvents
          .where((event) => event is DownlinkConnected)
          .listen(connects.add);

      await transport.start();
      await pumpUntil(() => sockets.isNotEmpty);
      await sockets.first.drop();
      await pumpUntil(() => connects.length >= 2);
      await transport.close();

      expect(connects.length, greaterThanOrEqualTo(2));
      expect(sockets.length, greaterThanOrEqualTo(2));
    });

    test('a channel that will not open is retried, not given up on', () async {
      var attempts = 0;
      final transport = build(
        connect: (_, _) async {
          attempts += 1;
          if (attempts < 3) throw const SocketException('refused');
          return _FakeSocket();
        },
      );
      final connects = <DownlinkTransportEvent>[];
      transport.downlinkEvents
          .where((event) => event is DownlinkConnected)
          .listen(connects.add);

      await transport.start();
      await pumpUntil(() => connects.isNotEmpty);
      await transport.close();

      expect(attempts, 3);
      expect(connects, hasLength(1));
    });

    test(
      'reports one unknown reconnect failure per connection episode',
      () async {
        final failures = <LocalSyncClientFailure>[];
        final firstError = StateError('first');
        final secondError = StateError('second');
        var attempts = 0;
        late _FakeSocket firstSocket;
        final transport = build(
          failureObserver: failures.add,
          connect: (_, _) async {
            attempts += 1;
            if (attempts <= 2) throw firstError;
            if (attempts == 3) return firstSocket = _FakeSocket();
            if (attempts == 4) throw secondError;
            return _FakeSocket();
          },
        );

        await transport.start();
        await pumpUntil(() => attempts == 3);
        expect(failures, hasLength(1));
        expect(failures.single.error, same(firstError));
        expect(failures.single.boundary, LocalSyncClientFailureBoundary.live);
        expect(failures.single.fate, LocalSyncClientFailureFate.retrying);

        await firstSocket.drop();
        await pumpUntil(() => attempts >= 5);
        await transport.close();

        expect(failures, hasLength(2));
        expect(failures.last.error, same(secondError));
      },
    );

    for (final weather in <Object>[
      const SocketException('offline'),
      const WebSocketException('closed'),
      const HandshakeException('handshake'),
      const HttpException('upgrade'),
    ]) {
      test('${weather.runtimeType} weather is not observed', () async {
        final failures = <LocalSyncClientFailure>[];
        var attempts = 0;
        final transport = build(
          failureObserver: failures.add,
          connect: (_, _) async {
            attempts += 1;
            if (attempts == 1) throw weather;
            return _FakeSocket();
          },
        );

        await transport.start();
        await pumpUntil(() => attempts == 2);
        await transport.close();

        expect(failures, isEmpty);
      });
    }

    test('a throwing observer cannot stop reconnect', () async {
      var attempts = 0;
      final transport = build(
        failureObserver: (_) => throw StateError('observer'),
        connect: (_, _) async {
          attempts += 1;
          if (attempts == 1) throw StateError('unknown');
          return _FakeSocket();
        },
      );

      await transport.start();
      await pumpUntil(() => attempts == 2);
      await transport.close();

      expect(attempts, 2);
    });

    test('close stops the channel and reopens nothing', () async {
      final sockets = <_FakeSocket>[];
      final transport = build(
        connect: (_, _) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
      );

      await transport.start();
      await pumpUntil(() => sockets.isNotEmpty);
      await transport.close();
      final opened = sockets.length;
      await pumpEventQueue();

      expect(sockets.length, opened);
      expect(sockets.first.closeCalls, greaterThan(0));
    });

    // The App's three-layer convention, on the upgrade as well as the calls.
    test('a refused upgrade refreshes once and opens', () async {
      final tokens = <String>[];
      var attempts = 0;
      final transport = RestWsTransport(
        baseUri: baseUri(),
        getAccessToken: () async => 'stale',
        getRefreshedAccessToken: () async => 'fresh',
        connect: (_, token) async {
          tokens.add(token);
          attempts += 1;
          if (attempts == 1) throw const LocalSyncSocketRefused(401);
          return _FakeSocket();
        },
        sleep: (_) async {},
      );
      final connects = <DownlinkTransportEvent>[];
      transport.downlinkEvents
          .where((event) => event is DownlinkConnected)
          .listen(connects.add);

      await transport.start();
      await pumpUntil(() => connects.isNotEmpty);
      await transport.close();

      expect(tokens, ['stale', 'fresh']);
    });

    // A revoked account is not a network hiccup: saying so once beats
    // reconnecting against it until the process dies.
    test('a second refusal is said out loud, not retried forever', () async {
      var attempts = 0;
      final transport = build(
        connect: (_, _) async {
          attempts += 1;
          throw const LocalSyncSocketRefused(401);
        },
      );
      final failures = <DownlinkFailed>[];
      transport.downlinkEvents
          .where((event) => event is DownlinkFailed)
          .listen((event) => failures.add(event as DownlinkFailed));

      await transport.start();
      await pumpUntil(() => failures.isNotEmpty);
      await transport.close();

      expect(attempts, 2);
      expect(failures.single.failure, isA<LocalSyncTerminalTransportFailure>());
    });

    test('names the build it is, so the floor can refuse it', () async {
      final uris = <Uri>[];
      final transport = RestWsTransport(
        baseUri: baseUri(),
        getAccessToken: () async => 'token-1',
        clientBuild: 202608080000,
        connect: (uri, _) async {
          uris.add(uri);
          return _FakeSocket();
        },
        sleep: (_) async {},
      );

      await transport.start();
      await pumpUntil(() => uris.isNotEmpty);
      await transport.close();

      expect(uris.single.queryParameters['build'], '202608080000');
    });

    // close() used to await a reconnect parked in its backoff — up to a
    // minute of shutdown for nothing.
    test('close does not wait out the backoff', () async {
      final transport = build(
        connect: (_, _) async => throw const SocketException('refused'),
        sleep: (_) => Future<void>.delayed(const Duration(seconds: 30)),
      );

      await transport.start();
      await pumpEventQueue();

      await transport.close().timeout(const Duration(seconds: 2));
    });

    test('starting twice is a mistake, not a second channel', () async {
      final transport = build(connect: (_, _) async => _FakeSocket());
      await transport.start();

      await expectLater(transport.start(), throwsStateError);
      await transport.close();
    });
  });
}

Future<void> pumpUntil(bool Function() done) async {
  for (var attempt = 0; attempt < 200; attempt += 1) {
    if (done()) return;
    await pumpEventQueue(times: 1);
  }
  throw StateError('condition never held');
}
