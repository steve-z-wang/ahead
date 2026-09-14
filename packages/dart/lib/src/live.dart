import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'connection.dart';

/// Immutable configuration reusable across independent client connections.
class SyncServer {
  final String url;
  final FutureOr<String> Function() token;
  const SyncServer({required this.url, required this.token});
}

/// Internal per-client network session.
class ServerSession {
  int _pushEpoch = 0;
  final _requests = <HttpClient>{};
  void cancelPush() {
    _pushEpoch++;
    for (final client in _requests.toList()) {
      client.close(force: true);
    }
    _requests.clear();
  }

  final Uri _base;
  final FutureOr<String> Function() _token;
  ServerSession(SyncServer server)
    : _base = Uri.parse(server.url),
      _token = server.token;

  Future<String> push(String kind, String body) async {
    final epoch = _pushEpoch;
    final token = await _token();
    if (epoch != _pushEpoch) throw StateError('connection_paused_or_closed');
    final http = HttpClient();
    _requests.add(http);
    try {
      final request = await http.postUrl(_endpoint('mutations', false));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close();
      final result = await utf8.decoder.bind(response).join();
      if (response.statusCode == 401) throw const AuthenticationExpired();
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw HttpException('push failed: ${response.statusCode} $result');
      return result;
    } finally {
      _requests.remove(http);
      http.close(force: true);
    }
  }

  Future<String> pull(String body, Future<void> cancellation) async {
    var cancelled = false;
    HttpClient? http;
    final stopped = Completer<String>();
    unawaited(
      cancellation.then((_) {
        cancelled = true;
        http?.close(force: true);
        if (!stopped.isCompleted)
          stopped.completeError(StateError('connection_paused_or_closed'));
      }),
    );
    final fetching = Future<String>(() async {
      final token = await _token();
      if (cancelled) throw StateError('connection_paused_or_closed');
      final client = HttpClient();
      http = client;
      try {
        final request = await client.postUrl(_endpoint('pull', false));
        if (cancelled) throw StateError('connection_paused_or_closed');
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.contentType = ContentType.json;
        request.write(body);
        final response = await request.close();
        final result = await utf8.decoder.bind(response).join();
        if (response.statusCode == 401) throw const AuthenticationExpired();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('pull failed: ${response.statusCode} $result');
        }
        return result;
      } finally {
        client.close(force: true);
      }
    });
    try {
      return await Future.any([fetching, stopped.future]);
    } finally {
      http = null;
      // Settle the losing future so a completed page is not retained until
      // the connection eventually ends. The cancellation callback has no IO.
      if (!stopped.isCompleted) stopped.complete('');
    }
  }

  Uri _endpoint(String path, bool websocket) => _base.replace(
    scheme: websocket
        ? (_base.scheme == 'https' || _base.scheme == 'wss' ? 'wss' : 'ws')
        : (_base.scheme == 'https' || _base.scheme == 'wss' ? 'https' : 'http'),
    path: '${_base.path.replaceFirst(RegExp(r'/$'), '')}/sync/$path',
  );

  Future<void> stream(
    List<String> channels,
    Future<void> Function(Map<String, dynamic>) apply,
    Future<void> cancellation, {
    Future<void> Function()? catchUp,
  }) {
    final done = Completer<void>();
    WebSocket? socket;
    StreamSubscription<dynamic>? subscription;
    final http = HttpClient();
    bool ended = false;
    bool subscribed = false;
    void finish([Object? error, StackTrace? stack]) {
      if (ended) return;
      ended = true;
      http.close(force: true);
      unawaited(subscription?.cancel());
      unawaited(socket?.close());
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error, stack);
      }
    }

    unawaited(
      cancellation.then(
        (_) => finish(),
        onError: (Object error) => finish(error),
      ),
    );
    unawaited(
      Future<void>(() async {
        final token = await _token();
        if (ended) return;
        WebSocket opened;
        try {
          opened = await WebSocket.connect(
            _endpoint('live', true).toString(),
            headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
            customClient: http,
          );
        } on WebSocketException catch (error) {
          if (error.httpStatusCode == 401) throw const AuthenticationExpired();
          rethrow;
        }
        socket = opened;
        if (ended) {
          unawaited(opened.close());
          return;
        }
        final scopes = channels.toList()..sort();
        opened.add(jsonEncode({'type': 'subscribe', 'scopes': scopes}));
        final pending = <Map<String, dynamic>>[];
        int pendingBytes = 0;
        bool draining = false;
        bool overflowed = false;
        Future<void> drain({bool initial = false}) async {
          if (draining || ended || !subscribed) return;
          draining = true;
          try {
            if (initial) await catchUp?.call();
            while (!ended) {
              if (overflowed) {
                overflowed = false;
                pending.clear();
                pendingBytes = 0;
                await catchUp?.call();
                continue;
              }
              if (pending.isEmpty) break;
              final page = pending.removeAt(0);
              pendingBytes -= jsonEncode(page).length;
              await apply(page);
            }
          } finally {
            draining = false;
          }
        }

        subscription = opened.listen(
          (dynamic raw) {
            if (ended) return;
            try {
              final text = raw is String ? raw : utf8.decode(raw as List<int>);
              if (text.length > 8 * 1024 * 1024) {
                throw const FormatException('live page too large');
              }
              final page = jsonDecode(text) as Map<String, dynamic>;
              if (!subscribed) {
                final accepted = (page['scopes'] as List?)
                    ?.cast<String>()
                    .toList();
                accepted?.sort();
                if (page['type'] != 'subscribed' ||
                    jsonEncode(accepted) != jsonEncode(scopes) ||
                    (page['rejections'] as List?)?.isEmpty != true) {
                  throw const FormatException(
                    'invalid live subscription acknowledgement',
                  );
                }
                subscribed = true;
                unawaited(
                  drain(
                    initial: true,
                  ).catchError((Object e, StackTrace s) => finish(e, s)),
                );
              } else {
                if (page.containsKey('type'))
                  throw const FormatException('invalid live page');
                if (pending.length >= 128 ||
                    pendingBytes + text.length > 8 * 1024 * 1024) {
                  // Keep the listener active and recover from durable cursors.
                  // Never restart an in-flight HTTP page because traffic is busy.
                  overflowed = true;
                  pending.clear();
                  pendingBytes = 0;
                } else if (!overflowed) {
                  pending.add(page);
                  pendingBytes += jsonEncode(page).length;
                }
                unawaited(
                  drain().catchError((Object e, StackTrace s) => finish(e, s)),
                );
              }
            } catch (e, s) {
              finish(e, s);
            }
          },
          onError: (Object error, StackTrace stack) => finish(error, stack),
          onDone: () => finish(
            StateError(
              'live disconnected: ${opened.closeCode} ${opened.closeReason}',
            ),
          ),
        );
      }).catchError((Object error, StackTrace stack) => finish(error, stack)),
    );
    return done.future;
  }
}
