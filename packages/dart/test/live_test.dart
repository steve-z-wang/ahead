import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ahead/ahead.dart';
import 'package:ahead/src/live.dart' show ServerSession;
import 'package:test/test.dart';

void main() {
  test('cancellation ends a stalled WebSocket token', () async {
    final cancel = Completer<void>();
    final live = ServerSession(
      SyncServer(
        url: 'http://127.0.0.1:1',
        token: () => Completer<String>().future,
      ),
    );
    final running = live.stream(['scope'], (_) async {}, cancel.future);
    cancel.complete();
    await running.timeout(const Duration(seconds: 2));
  });
  test(
    'WebSocket establishes listeners without cursor catch-up mode',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handshake = Completer<Map>();
      final finished = Completer<void>();
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer secret');
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          handshake.complete(jsonDecode(message as String) as Map);
          socket.add(
            jsonEncode({
              'type': 'subscribed',
              'scopes': ['scope'],
              'rejections': [],
            }),
          );
          socket.add(
            jsonEncode({
              'scope': 'scope',
              'fromCursor': 7,
              'toCursor': 8,
              'changes': [],
            }),
          );
        }, onDone: () => finished.complete());
      });
      final cancel = Completer<void>();
      final received = Completer<Map>();
      final live = ServerSession(
        SyncServer(
          url: 'http://127.0.0.1:${server.port}',
          token: () => 'secret',
        ),
      );
      final running = live.stream(['scope'], (page) async {
        received.complete(page);
      }, cancel.future);
      try {
        expect(await handshake.future.timeout(const Duration(seconds: 2)), {
          'type': 'subscribe',
          'scopes': ['scope'],
        });
        expect(
          (await received.future.timeout(
            const Duration(seconds: 2),
          ))['toCursor'],
          8,
        );
        cancel.complete();
        await running.timeout(const Duration(seconds: 2));
        await finished.future.timeout(const Duration(seconds: 2));
      } finally {
        if (!cancel.isCompleted) cancel.complete();
        await server.close(force: true);
      }
    },
  );
  test(
    'cancel push before token resolution prevents any later HTTP request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((r) {
        requests++;
        r.response.close();
      });
      final token = Completer<String>();
      final live = ServerSession(
        SyncServer(
          url: 'http://127.0.0.1:${server.port}',
          token: () => token.future,
        ),
      );
      final pushing = live.push('push', '{}');
      live.cancelPush();
      token.complete('late');
      await expectLater(pushing, throwsStateError);
      expect(requests, 0);
      await server.close(force: true);
    },
  );

  test(
    'HTTP catch-up cancellation ends stalled token and in-flight response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final entered = Completer<void>();
      server.listen((request) {
        requests++;
        entered.complete();
      });
      final token = Completer<String>();
      final session = ServerSession(
        SyncServer(
          url: 'http://127.0.0.1:${server.port}',
          token: () => token.future,
        ),
      );
      final firstCancel = Completer<void>();
      final first = session.pull('{}', firstCancel.future);
      final stopped = expectLater(first, throwsStateError);
      firstCancel.complete();
      await stopped.timeout(const Duration(seconds: 2));
      token.complete('late');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 0);
      final secondCancel = Completer<void>();
      final second = session.pull('{}', secondCancel.future);
      final aborted = expectLater(second, throwsStateError);
      await entered.future.timeout(const Duration(seconds: 2));
      secondCancel.complete();
      await aborted.timeout(const Duration(seconds: 2));
      expect(requests, 1);
      await server.close(force: true);
    },
  );

  test('close during an opening handshake cancels its socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entered = Completer<void>();
    server.listen((r) {
      entered.complete();
    });
    final cancelled = Completer<void>();
    final live = ServerSession(
      SyncServer(url: 'http://127.0.0.1:${server.port}', token: () => 'secret'),
    );
    final running = live.stream(['scope'], (_) async {}, cancelled.future);
    await entered.future.timeout(const Duration(seconds: 2));
    cancelled.complete();
    await running.timeout(const Duration(seconds: 2));
    await server.close(force: true);
  });

  test(
    'unsubscribe invalidates a pending token before a held transaction drains',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ahead-dart-token-generation-',
      );
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.response.close();
      });
      final token = Completer<String>(), tokenEntered = Completer<void>();
      final txEntered = Completer<void>(), held = Completer<void>();
      final errors = <Object>[];
      try {
        await client.subscribe('scope');
        await client.connect(
          SyncServer(
            url: 'http://127.0.0.1:${server.port}',
            token: () {
              tokenEntered.complete();
              return token.future;
            },
          ),
          onError: errors.add,
        );
        await tokenEntered.future.timeout(const Duration(seconds: 2));
        final transaction = client.transaction((_) async {
          txEntered.complete();
          await held.future;
        });
        await txEntered.future;
        final removing = client.unsubscribe('scope');
        token.complete('obsolete');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          requests,
          0,
          reason: 'network cancellation must not await the database queue',
        );
        held.complete();
        await transaction;
        await removing;
        expect(errors, isEmpty);
      } finally {
        if (!held.isCompleted) held.complete();
        if (!token.isCompleted) token.complete('cleanup');
        await client.close();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'native live client retries failed authentication refresh and closes without leaks',
    () async {
      final dir = await Directory.systemTemp.createTemp('ahead-dart-live-');
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var token = 'expired', refreshes = 0;
      final accepted = Completer<void>();
      final errors = <Object>[];
      final sockets = <WebSocket>[];
      server.listen((request) async {
        if (request.headers.value('authorization') != 'Bearer valid') {
          request.response.statusCode = 401;
          await request.response.close();
          return;
        }
        if (request.uri.path == '/sync/pull') {
          final pull =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          request.response.write(
            jsonEncode({
              'scope': pull['scope'],
              'fromCursor': pull['fromCursor'],
              'toCursor': pull['fromCursor'],
              'changes': [],
            }),
          );
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((message) {
          final sub = jsonDecode(message as String) as Map;
          socket.add(
            jsonEncode({
              'type': 'subscribed',
              'scopes': sub['scopes'],
              'rejections': [],
            }),
          );
          if (!accepted.isCompleted) accepted.complete();
        });
      });
      try {
        await client.subscribe('scope');
        final connection = await client.connect(
          SyncServer(
            url: 'http://127.0.0.1:${server.port}',
            token: () => token,
          ),
          onError: errors.add,
          refreshAuth: () async {
            if (++refreshes == 1) throw StateError('refresh failed');
            token = 'valid';
          },
        );
        await accepted.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw StateError('refreshes=$refreshes errors=$errors'),
        );
        expect(refreshes, 2);
        expect(
          errors.any((e) => e.toString().contains('refresh failed')),
          isTrue,
        );
        await connection.pause();
        await connection.resume();
        await connection.close();
      } finally {
        await client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'native subscription changes discard old pages and HTTP recovers live gaps',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'ahead-dart-generation-',
      );
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final handshakes = <Map>[];
      final errors = <Object>[];
      Future<void> until(FutureOr<bool> Function() check) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          if (await check()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('condition timed out: $errors');
      }

      Map<String, dynamic> page(String text, int cursor) => {
        'scope': 'scope',
        'fromCursor': cursor,
        'toCursor': cursor + 1,
        'changes': [
          {
            'syncId': cursor + 1,
            'model': 'Entry',
            'identity': {'id': 'live'},
            'stamp': cursor + 1,
            'state': {'text': text, 'note': null},
          },
        ],
      };
      var pulls = 0;
      Map<String, dynamic>? recovery;
      server.listen((r) async {
        if (r.uri.path == '/sync/pull') {
          pulls++;
          final pull = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
          r.response.write(
            jsonEncode(
              recovery ??
                  {
                    'scope': pull['scope'],
                    'fromCursor': pull['fromCursor'],
                    'toCursor': pull['fromCursor'],
                    'changes': [],
                  },
            ),
          );
          await r.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(r);
        sockets.add(socket);
        socket.listen((message) {
          final sub = jsonDecode(message as String) as Map;
          handshakes.add(sub);
          socket.add(
            jsonEncode({
              'type': 'subscribed',
              'scopes': sub['scopes'],
              'rejections': [],
            }),
          );
        });
      });
      try {
        await client.subscribe('scope');
        final connection = await client.connect(
          SyncServer(
            url: 'http://127.0.0.1:${server.port}',
            token: () => 'secret',
          ),
          onError: errors.add,
        );
        await until(() => handshakes.length == 1);
        sockets.first.add(jsonEncode(page('first', 0)));
        await until(
          () async =>
              (await client.read('Entry', {'id': 'live'}))?['text'] == 'first',
        );
        final held = Completer<void>(), entered = Completer<void>();
        final tx = client.transaction((_) async {
          entered.complete();
          await held.future;
        });
        await entered.future;
        sockets.first.add(jsonEncode(page('obsolete', 1)));
        final remove = client.unsubscribe('scope'),
            restore = client.subscribe('scope');
        held.complete();
        await tx;
        await remove;
        await restore;
        await until(() => handshakes.length >= 2);
        expect(await client.read('Entry', {'id': 'live'}), isNull);
        expect(handshakes.last.containsKey('cursors'), isFalse);
        sockets.last.add(jsonEncode(page('fresh', 0)));
        await until(
          () async =>
              (await client.read('Entry', {'id': 'live'}))?['text'] == 'fresh',
        );
        expect(errors, isEmpty);
        final beforeOverlap = pulls;
        recovery = page('overlap recovered', 1);
        sockets.last.add(jsonEncode({...page('overlap', 1), 'fromCursor': 0}));
        await until(
          () async =>
              (await client.read('Entry', {'id': 'live'}))?['text'] ==
              'overlap',
        );
        expect(
          pulls,
          beforeOverlap,
          reason: 'overlap applies directly without HTTP',
        );
        expect((await client.status())['cursors']['scope'], 2);
        sockets.last.add(
          jsonEncode({...page('duplicate', 1), 'fromCursor': 0}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(pulls, beforeOverlap);
        expect(
          (await client.read('Entry', {'id': 'live'}))?['text'],
          'overlap',
        );
        final before = pulls;
        recovery = page('recovered', 2);
        sockets.last.add(jsonEncode(page('gap', 10)));
        await until(
          () async =>
              (await client.read('Entry', {'id': 'live'}))?['text'] ==
              'recovered',
        );
        expect(pulls, greaterThan(before));
        expect(errors, isEmpty);
        await connection.close();
      } finally {
        await client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'HTTP catch-up pages after ack, queues overlap, and rejects obsolete HTTP completion',
    () async {
      final dir = await Directory.systemTemp.createTemp('ahead-dart-http-');
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final errors = <Object>[];
      final requests = <int>[];
      var acknowledged = false;
      var hold = Completer<void>();
      var entered = Completer<void>();
      var held = true;
      var version = 'initial';
      Map<String, dynamic> page(int from, int to, String text) => {
        'scope': 'scope',
        'fromCursor': from,
        'toCursor': to,
        'changes': [
          for (var cursor = from + 1; cursor <= to; cursor++)
            {
              'syncId': cursor,
              'model': 'Entry',
              'identity': {'id': 'e$cursor'},
              'stamp': cursor,
              'state': {'text': text, 'note': null},
            },
        ],
      };
      Future<void> until(FutureOr<bool> Function() check) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          if (await check()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('timeout: $errors requests=$requests');
      }

      server.listen((request) async {
        if (request.uri.path == '/sync/pull') {
          expect(acknowledged, isTrue, reason: 'listeners must precede HTTP');
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final from = body['fromCursor'] as int;
          requests.add(from);
          final result = page(from, from == 0 ? 50 : 55, version);
          if (held) {
            held = false;
            entered.complete();
            await hold.future;
          }
          try {
            request.response.write(jsonEncode(result));
            await request.response.close();
          } catch (_) {}
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((message) {
          final sub = jsonDecode(message as String) as Map;
          expect(sub.containsKey('cursors'), isFalse);
          acknowledged = true;
          socket.add(
            jsonEncode({
              'type': 'subscribed',
              'scopes': sub['scopes'],
              'rejections': [],
            }),
          );
        });
      });
      try {
        await client.subscribe('scope');
        final connection = await client.connect(
          SyncServer(
            url: 'http://127.0.0.1:${server.port}',
            token: () => 'secret',
          ),
          onError: errors.add,
        );
        await entered.future.timeout(const Duration(seconds: 3));
        expect(await client.query('Entry'), isEmpty);
        // A commit observed live during catch-up is buffered, then recognized as covered.
        sockets.last.add(jsonEncode(page(50, 55, 'initial')));
        hold.complete();
        await until(() async => (await client.query('Entry')).length == 55);
        expect(requests, [0, 50]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(requests, [0, 50], reason: 'steady state must not poll HTTP');
        sockets.last.add(jsonEncode(page(55, 56, 'live')));
        await until(() async => (await client.query('Entry')).length == 56);
        expect(requests, [0, 50]);
        // Reconnect catches up from the durable cursor. Hold that obsolete response
        // while unsubscribe/resubscribe resets the scope and starts a fresh session.
        await connection.pause();
        held = true;
        hold = Completer<void>();
        entered = Completer<void>();
        await connection.resume();
        await entered.future.timeout(const Duration(seconds: 3));
        expect(requests.last, 56);
        await client.unsubscribe('scope');
        version = 'fresh';
        await client.subscribe('scope');
        hold.complete();
        await until(() async => (await client.query('Entry')).length == 55);
        expect((await client.read('Entry', {'id': 'e1'}))?['text'], 'fresh');
        expect(await client.read('Entry', {'id': 'e56'}), isNull);
        expect(errors, isEmpty);
        await connection.close();
      } finally {
        if (!hold.isCompleted) hold.complete();
        await client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'shared live factory isolates cancellation and pushes with no subscribed channels',
    () async {
      final dir = await Directory.systemTemp.createTemp('ahead-shared-live-');
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final first = await Client.open(
        path: '${dir.path}/first',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final second = await Client.open(
        path: '${dir.path}/second',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final entered = Completer<void>(), token = Completer<String>();
      final errors = <Object>[];
      server.listen((request) async {
        requests++;
        expect(request.uri.path, '/sync/mutations');
        expect(WebSocketTransformer.isUpgradeRequest(request), isFalse);
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'requiredScope': 'scope',
            'requiredSyncId': 1,
            'requiredCheckpoints': [
              {'scope': 'scope', 'syncId': 1},
            ],
            'rejections': [],
          }),
        );
        await request.response.close();
      });
      final live = SyncServer(
        url: 'http://127.0.0.1:${server.port}',
        token: () {
          if (!entered.isCompleted) entered.complete();
          return token.future;
        },
      );
      try {
        await second.transaction(
          (tx) => tx.direct({
            'model': 'Entry',
            'op': 'create',
            'identity': {'id': 'local'},
            'values': {'text': 'base'},
          }),
        );
        await second.mutate({
          'name': 'Edit',
          'operations': [
            {
              'model': 'Entry',
              'op': 'update',
              'identity': {'id': 'local'},
              'values': {'text': 'edited'},
            },
          ],
        });
        final a = await first.connect(live);
        await second.connect(live, onError: errors.add);
        await entered.future.timeout(const Duration(seconds: 2));
        await a.pause();
        await a.close();
        token.complete('secret');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline) &&
            (await second.status())['pending'] != 0 &&
            errors.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          errors,
          isEmpty,
          reason: 'pausing another client must not cancel this push',
        );
        expect((await second.status())['pending'], 0);
        expect(requests, 1);
      } finally {
        if (!token.isCompleted) token.complete('cleanup');
        await first.close();
        await second.close();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'pause blocks a selected parent request before awaiting child pause',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((r) async {
        requests++;
        r.response.write('{}');
        await r.response.close();
      });
      final token = Completer<String>(),
          syncEntered = Completer<void>(),
          pushFinished = Completer<void>();
      var tokenCalls = 0;
      final live = ServerSession(
        SyncServer(
          url: 'http://127.0.0.1:${server.port}',
          token: () {
            tokenCalls++;
            return token.future;
          },
        ),
      );
      final next = Completer<void>(), childPause = Completer<void>();
      var first = true;
      final parent = await RuntimeConnection.start(
        control: (event, now, entropy) async {
          if (event == 'next') {
            if (first) {
              first = false;
              await next.future;
              return {'type': 'sync'};
            }
            return {'type': 'idle'};
          }
          return null;
        },
        sync: (request) async {
          syncEntered.complete();
          await request('push', '{}');
        },
        transport: (kind, body) async {
          try {
            return await live.push(kind, body);
          } finally {
            pushFinished.complete();
          }
        },
      );
      final child = await RuntimeConnection.start(
        control: (event, now, entropy) async {
          if (event == 'pause') await childPause.future;
          return event == 'next' ? {'type': 'idle'} : null;
        },
        sync: (_) async {},
        transport: (_, __) async => '',
      );
      parent.attachLive(child, () {
        live.cancelPush();
        if (!next.isCompleted) next.complete();
      });
      try {
        final pausing = parent.pause();
        await syncEntered.future.timeout(const Duration(seconds: 2));
        childPause.complete();
        await pausing.timeout(const Duration(seconds: 2));
        token.complete('late');
        if (tokenCalls > 0)
          await pushFinished.future.timeout(const Duration(seconds: 2));
        expect(tokenCalls, 0);
        expect(requests, 0);
      } finally {
        if (!childPause.isCompleted) childPause.complete();
        if (!token.isCompleted) token.complete('cleanup');
        await parent.close();
        await server.close(force: true);
      }
    },
  );
  moreTests();
}

void moreTests() {
  test(
    'push succeeds while the WebSocket upgrade is refused; nothing settles until the upgrade is allowed and HTTP catch-up runs',
    () async {
      final dir = await Directory.systemTemp.createTemp('ahead-dart-blocked-');
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final errors = <Object>[];
      var allowUpgrades = false, upgradeAttempts = 0, pushes = 0, pulls = 0;
      Future<void> until(FutureOr<bool> Function() check) async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          if (await check()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('condition timed out: $errors');
      }

      server.listen((r) async {
        if (WebSocketTransformer.isUpgradeRequest(r)) {
          upgradeAttempts++;
          if (!allowUpgrades) {
            r.response.statusCode = HttpStatus.serviceUnavailable;
            await r.response.close();
            return;
          }
          final socket = await WebSocketTransformer.upgrade(r);
          sockets.add(socket);
          socket.listen((message) {
            final sub = jsonDecode(message as String) as Map;
            socket.add(
              jsonEncode({
                'type': 'subscribed',
                'scopes': sub['scopes'],
                'rejections': [],
              }),
            );
          });
          return;
        }
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        r.response.headers.contentType = ContentType.json;
        if (r.uri.path == '/sync/mutations') {
          pushes++;
          r.response.write(
            jsonEncode({
              'requiredScope': 'scope',
              'requiredSyncId': 1,
              'requiredCheckpoints': [
                {'scope': 'scope', 'syncId': 1},
              ],
              'rejections': [],
            }),
          );
        } else {
          pulls++;
          final from = body['fromCursor'] as int;
          r.response.write(
            jsonEncode({
              'scope': 'scope',
              'fromCursor': from,
              'toCursor': from + 1,
              'changes': [
                {
                  'syncId': from + 1,
                  'model': 'Entry',
                  'identity': {'id': 'live'},
                  'stamp': from + 1,
                  'state': {'text': 'from catch-up', 'note': null},
                },
              ],
            }),
          );
        }
        await r.response.close();
      });
      try {
        await client.transaction(
          (tx) => tx.direct({
            'model': 'Entry',
            'op': 'create',
            'identity': {'id': 'live'},
            'values': {'text': 'local'},
          }),
        );
        await client.subscribe('scope');
        await client.mutate({
          'name': 'Edit',
          'operations': [
            {
              'model': 'Entry',
              'op': 'update',
              'identity': {'id': 'live'},
              'values': {'text': 'edited offline'},
            },
          ],
        });
        final connection = await client.connect(
          SyncServer(
            url: 'http://127.0.0.1:${server.port}',
            token: () => 'secret',
          ),
          onError: errors.add,
        );
        await until(() => pushes == 1 && upgradeAttempts >= 2);
        expect(
          pulls,
          0,
          reason: 'no HTTP catch-up without an acknowledged WebSocket',
        );
        expect((await client.status())['pending'], 1);
        expect(
          (await client.read('Entry', {'id': 'live'}))?['text'],
          'edited offline',
        );
        expect(
          errors.any((e) => e.toString().contains('503')),
          isTrue,
          reason: 'upgrade refusals reach onError: $errors',
        );
        allowUpgrades = true;
        await until(() async => (await client.status())['pending'] == 0);
        expect(pushes, 1, reason: 'the receipt was not re-requested');
        expect(pulls, greaterThanOrEqualTo(1));
        expect(
          (await client.read('Entry', {'id': 'live'}))?['text'],
          'from catch-up',
        );
        await connection.close();
      } finally {
        await client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'bounded receive buffer (128 pages) overflows into recovery without restarting the in-flight HTTP catch-up',
    () async {
      final dir = await Directory.systemTemp.createTemp('ahead-dart-overflow-');
      final schema =
          jsonDecode(
                await File('../../fixtures/schemas/entry.json').readAsString(),
              )
              as Map<String, dynamic>;
      final client = await Client.open(
        path: '${dir.path}/db',
        schema: schema,
        libraryPath: Platform.environment['AHEAD_LIBRARY']!,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final errors = <Object>[];
      final entered = Completer<void>(), gate = Completer<void>();
      var head = 1, pulls = 0;
      final pullCursors = <int>[];
      Map<String, dynamic> page(String text, int cursor, int to) => {
        'scope': 'scope',
        'fromCursor': cursor,
        'toCursor': to,
        'changes': [
          {
            'syncId': to,
            'model': 'Entry',
            'identity': {'id': 'live'},
            'stamp': to,
            'state': {'text': text, 'note': null},
          },
        ],
      };
      Future<void> until(FutureOr<bool> Function() check) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          if (await check()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('condition timed out: $errors');
      }

      server.listen((r) async {
        if (WebSocketTransformer.isUpgradeRequest(r)) {
          final socket = await WebSocketTransformer.upgrade(r);
          sockets.add(socket);
          socket.listen((message) {
            final sub = jsonDecode(message as String) as Map;
            socket.add(
              jsonEncode({
                'type': 'subscribed',
                'scopes': sub['scopes'],
                'rejections': [],
              }),
            );
          });
          return;
        }
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        pulls++;
        final from = body['fromCursor'] as int;
        pullCursors.add(from);
        final response = page('head $head', from, head);
        if (pulls == 1) {
          entered.complete();
          await gate.future;
        }
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(response));
        await r.response.close();
      });
      try {
        await client.subscribe('scope');
        final connection = await client.connect(
          SyncServer(
            url: 'http://127.0.0.1:${server.port}',
            token: () => 'secret',
          ),
          onError: errors.add,
        );
        await entered.future.timeout(const Duration(seconds: 5));
        // Flush more pages than the 128-page bound, then let the listener
        // receive them while the initial HTTP response remains held.
        await sockets.first.addStream(
          Stream.fromIterable([
            for (var cursor = 1; cursor <= 200; cursor++)
              jsonEncode(page('live $cursor', cursor, cursor + 1)),
          ]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Only HTTP can reveal this state: replaying every buffered live page
        // reaches 201, so an unbounded buffer cannot satisfy this assertion.
        head = 202;
        gate.complete();
        await until(
          () async => (await client.status())['cursors']['scope'] >= 201,
        );
        expect((await client.status())['cursors']['scope'], 202);
        expect(
          (await client.read('Entry', {'id': 'live'}))?['text'],
          'head 202',
        );
        expect(
          pullCursors,
          contains(1),
          reason: 'recovery preserves the held HTTP page before pulling again',
        );
        expect(
          sockets.length,
          1,
          reason: 'overflow must not restart the socket and starve catch-up',
        );
        expect(
          pulls,
          inInclusiveRange(2, 4),
          reason: 'overflow requires HTTP recovery and coalesces its work',
        );
        expect(errors, isEmpty);
        await connection.close();
      } finally {
        if (!gate.isCompleted) gate.complete();
        await client.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
}
