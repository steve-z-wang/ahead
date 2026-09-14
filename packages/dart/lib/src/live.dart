import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'connection.dart';

/// WebSocket catch-up and streaming with authenticated HTTP mutation push.
class LiveTransport {
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
  LiveTransport._(this._base, this._token);

  /// Creates independent request cancellation state while reusing configuration.
  LiveTransport createSession() => LiveTransport._(_base, _token);

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

  Uri _endpoint(String path, bool websocket) => _base.replace(
    scheme: websocket
        ? (_base.scheme == 'https' || _base.scheme == 'wss' ? 'wss' : 'ws')
        : (_base.scheme == 'https' || _base.scheme == 'wss' ? 'https' : 'http'),
    path: '${_base.path.replaceFirst(RegExp(r'/$'), '')}/sync/$path',
  );

  Future<void> stream(
    Map<String, dynamic> cursors,
    Future<void> Function(Map<String, dynamic>) apply,
    Future<void> cancellation,
  ) {
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
        final scopes = cursors.keys.toList()..sort();
        opened.add(
          jsonEncode({
            'type': 'subscribe',
            'scopes': scopes,
            'cursors': cursors,
          }),
        );
        subscription = opened.listen(
          (dynamic raw) {
            subscription!.pause();
            unawaited(
              Future<void>(() async {
                if (ended) return;
                final text = raw is String
                    ? raw
                    : utf8.decode(raw as List<int>);
                if (text.length > 8 * 1024 * 1024)
                  throw const FormatException('live page too large');
                final page = jsonDecode(text) as Map<String, dynamic>;
                if (!subscribed) {
                  final accepted = (page['scopes'] as List?)
                      ?.cast<String>()
                      .toList();
                  accepted?.sort();
                  if (page['type'] != 'subscribed' ||
                      jsonEncode(accepted) != jsonEncode(scopes) ||
                      (page['rejections'] as List?)?.isEmpty != true)
                    throw const FormatException(
                      'invalid live subscription acknowledgement',
                    );
                  subscribed = true;
                } else {
                  if (page.containsKey('type'))
                    throw const FormatException('invalid live page');
                  await apply(page);
                }
              }).then(
                (_) {
                  if (!ended) subscription?.resume();
                },
                onError: (Object error, StackTrace stack) =>
                    finish(error, stack),
              ),
            );
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

LiveTransport websocketTransport({
  required String url,
  required FutureOr<String> Function() token,
}) => LiveTransport._(Uri.parse(url), token);
