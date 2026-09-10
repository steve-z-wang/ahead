import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:math';

import '../local_sync_client_failure.dart';
import '../uplink/retry_policy.dart';
import 'http_status_classifier.dart';
import 'local_sync_cancellation.dart';
import 'local_sync_transport.dart';
import 'local_sync_transport_failure.dart';

/// One open live channel, reduced to what the transport needs of it: frames in,
/// and a way to hang up. The socket library sits behind this so the transport's
/// reconnect rule can be tested without a network.
abstract interface class LocalSyncSocket {
  Stream<Uint8List> get frames;

  Future<void> send(Uint8List frame);

  Future<void> close();
}

typedef LocalSyncSocketConnector =
    Future<LocalSyncSocket> Function(Uri uri, String accessToken);

/// What a refused upgrade looked like. The status is the only thing the
/// transport needs of it: 401 heals by refreshing, and the rest do not.
final class LocalSyncSocketRefused implements Exception {
  const LocalSyncSocketRefused(this.status);

  final int status;

  @override
  String toString() => 'LocalSyncSocketRefused($status)';
}

typedef RestWsSleep = Future<void> Function(Duration duration);

/// The wire, over the two things the platform's edge already carries: ordinary
/// HTTPS for the two request/response calls, and a WebSocket for the live one.
///
/// Three fixed routes, so there is no router and no service discovery: the
/// product hands this a base URI and a credential, and everything else about
/// where the server is has no bearing on the protocol.
final class RestWsTransport implements LocalSyncTransport {
  RestWsTransport({
    required Uri baseUri,
    required Future<String> Function() getAccessToken,
    LocalSyncSocketConnector? connect,
    HttpClient? httpClient,
    RetryPolicy? reconnectPolicy,
    RestWsSleep? sleep,
    Future<String> Function()? getRefreshedAccessToken,
    int? clientBuild,
    Duration requestTimeout = const Duration(seconds: 30),
    Future<void> Function()? onClosed,
    LocalSyncClientFailureObserver? failureObserver,
  }) : _baseUri = baseUri,
       _onClosed = onClosed,
       _getAccessToken = getAccessToken,
       _getRefreshedAccessToken = getRefreshedAccessToken ?? getAccessToken,
       _clientBuild = clientBuild,
       _requestTimeout = requestTimeout,
       _httpClient =
           httpClient ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 15)),
       _ownsHttpClient = httpClient == null,
       _connect = connect ?? _connectWebSocket,
       _failureObserver = failureObserver,
       _reconnectPolicy =
           reconnectPolicy ?? RetryPolicy(randomDouble: Random().nextDouble),
       _sleep = sleep ?? _defaultSleep;

  final Uri _baseUri;
  final Future<String> Function() _getAccessToken;
  final Future<String> Function() _getRefreshedAccessToken;
  final int? _clientBuild;
  final Duration _requestTimeout;

  /// Released when this transport closes. An injected [HttpClient] is the
  /// caller's, so only the caller knows when the last user of it is done.
  final Future<void> Function()? _onClosed;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final LocalSyncSocketConnector _connect;
  final LocalSyncClientFailureObserver? _failureObserver;
  final RetryPolicy _reconnectPolicy;
  final RestWsSleep _sleep;

  final StreamController<DownlinkTransportEvent> _events =
      StreamController<DownlinkTransportEvent>.broadcast();
  Future<void>? _liveLoop;
  LocalSyncSocket? _socket;

  /// Completed by [close], so a reconnect parked in its backoff wakes at once
  /// rather than holding shutdown for up to a minute.
  final Completer<void> _closing = Completer<void>();
  bool _closed = false;
  bool _unexpectedLiveFailureReported = false;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _events.stream;

  @override
  Future<void> start() async {
    if (_liveLoop != null) throw StateError('RestWsTransport already started');
    _liveLoop = _stayConnected();
  }

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _post('sync/mutations', body, cancellation);

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _post('sync/pull', body, cancellation);

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) async {
    if (_closed) {
      throw const LocalSyncCancelledTransportFailure('transport is closed');
    }
    final socket = _socket;
    if (socket == null) {
      throw const LocalSyncRetryableTransportFailure(
        'Downlink socket is not connected',
      );
    }
    try {
      await socket.send(frame);
    } catch (error) {
      if (_closed) {
        throw LocalSyncCancelledTransportFailure('$error');
      }
      throw LocalSyncRetryableTransportFailure(
        'Downlink frame send failed: $error',
      );
    }
  }

  @override
  Future<void> restartDownlinkConnection() async {
    if (_closed) return;
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_closing.isCompleted) _closing.complete();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _liveLoop;
    await _events.close();
    if (_ownsHttpClient) _httpClient.close(force: true);
    await _onClosed?.call();
  }

  Future<LocalSyncHttpResponse> _post(
    String path,
    Uint8List body,
    LocalSyncCancellation? cancellation,
  ) async {
    if (_closed) {
      throw const LocalSyncCancelledTransportFailure('transport is closed');
    }
    var aborted = false;
    try {
      final token = await _getAccessToken();
      final request = await _httpClient.postUrl(_baseUri.resolve(path));
      bindLocalSyncCancellation(cancellation, () async {
        aborted = true;
        request.abort();
      });
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(body);
      final response = await request.close().timeout(_requestTimeout);
      final bytes = await _readBody(response).timeout(_requestTimeout);
      return LocalSyncHttpResponse(
        statusCode: response.statusCode,
        body: bytes,
      );
    } on Object catch (error) {
      if (aborted || _closed) {
        throw LocalSyncCancelledTransportFailure('$error');
      }
      // The call never reached an answer — no status to read, and the frozen
      // batch outlives it, so this is the retryable case by construction.
      throw LocalSyncRetryableTransportFailure(
        'LocalSync request failed: $error',
      );
    }
  }

  Future<Uint8List> _readBody(HttpClientResponse response) async {
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  /// The live channel is the transport's own business: it reconnects on its
  /// own schedule and says so, and the worker above reads only "open again".
  ///
  /// Two things it will not do: reconnect forever against a refusal that
  /// cannot change, and swallow one silently. A refused upgrade is retried
  /// once with a forcibly refreshed credential — the App's three-layer
  /// convention, which the request calls already follow — and a second refusal
  /// is said out loud on [downlinkEvents] and ends the loop.
  Future<void> _stayConnected() async {
    var refreshed = false;
    while (!_closed) {
      try {
        final token = refreshed
            ? await _getRefreshedAccessToken()
            : await _getAccessToken();
        final socket = await _connect(_liveUri, token);
        _unexpectedLiveFailureReported = false;
        refreshed = false;
        if (_closed) {
          await socket.close();
          return;
        }
        _socket = socket;
        _reconnectPolicy.reset();
        _emit(const DownlinkConnected());
        await for (final frame in socket.frames) {
          if (_closed) break;
          _emit(DownlinkPageReceived(frame));
        }
      } on LocalSyncSocketRefused catch (refusal) {
        if (refusal.status == localSyncUnauthorizedStatus && !refreshed) {
          refreshed = true;
        } else {
          final failure = classifyLocalSyncHttpStatus(refusal.status, null);
          if (failure is LocalSyncTerminalTransportFailure) {
            _emit(DownlinkFailed(failure));
            return;
          }
        }
      } on SocketException {
        // Expected connection weather. Reconnect below.
      } on WebSocketException {
        // Expected connection weather. Reconnect below.
      } on HandshakeException {
        // Expected connection weather. Reconnect below.
      } on HttpException {
        // Expected connection weather. Reconnect below.
      } catch (error, stackTrace) {
        if (!_unexpectedLiveFailureReported) {
          _unexpectedLiveFailureReported = true;
          notifyLocalSyncClientFailure(
            _failureObserver,
            LocalSyncClientFailure(
              error: error,
              stackTrace: stackTrace,
              boundary: LocalSyncClientFailureBoundary.live,
              fate: LocalSyncClientFailureFate.retrying,
            ),
          );
        }
      } finally {
        final socket = _socket;
        _socket = null;
        await socket?.close();
      }
      if (_closed) return;
      // Whichever comes first: the backoff, or the shutdown that makes it
      // pointless to wait out.
      await Future.any<void>([
        _sleep(_reconnectPolicy.nextDelay()),
        _closing.future,
      ]);
    }
  }

  Uri get _liveUri {
    final live = _baseUri.resolve('sync/live');
    return live.replace(
      scheme: live.scheme == 'https' ? 'wss' : 'ws',
      // The min-build gate reads this (CAP-157). A build the client does not
      // know is simply not named, which the host passes.
      queryParameters: _clientBuild == null ? null : {'build': '$_clientBuild'},
    );
  }

  void _emit(DownlinkTransportEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

Future<LocalSyncSocket> _connectWebSocket(Uri uri, String accessToken) async {
  final WebSocket socket;
  try {
    socket = await WebSocket.connect(
      uri.toString(),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $accessToken'},
    );
  } on WebSocketException catch (error) {
    // dart:io states a refused upgrade only in the message, so the status is
    // read back out of it — the one place that parsing belongs.
    final status = RegExp(r'status[^0-9]*([0-9]{3})').firstMatch('$error');
    if (status != null) {
      throw LocalSyncSocketRefused(int.parse(status.group(1)!));
    }
    rethrow;
  }
  // A half-open socket looks alive forever; the ping is what makes it die.
  socket.pingInterval = const Duration(seconds: 30);
  return _WebSocketAdapter(socket);
}

final class _WebSocketAdapter implements LocalSyncSocket {
  _WebSocketAdapter(this._socket);

  final WebSocket _socket;

  @override
  Stream<Uint8List> get frames => _socket.map(_asBytes);

  @override
  Future<void> send(Uint8List frame) async => _socket.add(frame);

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

Uint8List _asBytes(dynamic frame) {
  if (frame is Uint8List) return frame;
  if (frame is List<int>) return Uint8List.fromList(frame);
  return Uint8List.fromList(utf8.encode(frame as String));
}

Future<void> _defaultSleep(Duration duration) => Future<void>.delayed(duration);
