import 'dart:async';
import 'dart:math';

typedef Transport = Future<String> Function(String kind, String body);
typedef ConnectionControl =
    Future<dynamic> Function(String event, int now, int entropy);

/// Rust owns scheduling; this class supplies timers and cancellable network waits.
class RuntimeConnection {
  final ConnectionControl _control;
  final Future<void> Function(Transport) _sync;
  final Transport _transport;
  final void Function(Object)? onError;
  final Future<void> Function()? refreshAuth;
  final _requests = <Completer<String>>{};
  final _closed = Completer<void>();
  Future<void>? _activeSync;
  bool _paused = false;
  bool _stopped = false;
  int _epoch = 0;
  Completer<void>? _wake;
  Timer? _timer;
  RuntimeConnection._(
    this._control,
    this._sync,
    this._transport,
    this.onError,
    this.refreshAuth,
  );
  Future<void> get closed => _closed.future;
  static Future<RuntimeConnection> start({
    required ConnectionControl control,
    required Future<void> Function(Transport) sync,
    required Transport transport,
    void Function(Object)? onError,
    Future<void> Function()? refreshAuth,
  }) async {
    final connection = RuntimeConnection._(
      control,
      sync,
      transport,
      onError,
      refreshAuth,
    );
    await connection._command('start');
    unawaited(
      connection._loop().catchError((Object error) {
        if (!connection._stopped) connection.onError?.call(error);
      }),
    );
    return connection;
  }

  Future<dynamic> _command(String event) => _control(
    event,
    DateTime.now().millisecondsSinceEpoch,
    Random().nextInt(0x100000000),
  );
  void _notify() {
    _epoch++;
    _timer?.cancel();
    if (_wake?.isCompleted == false) _wake!.complete();
    _wake = null;
  }

  Future<void> _wait(int? millis) {
    final wake = Completer<void>();
    _wake = wake;
    if (millis != null)
      _timer = Timer(Duration(milliseconds: millis), () {
        if (!wake.isCompleted) wake.complete();
        if (identical(_wake, wake)) _wake = null;
      });
    return wake.future;
  }

  Future<String> _request(String kind, String body) {
    if (_stopped || _paused)
      return Future.error(StateError('connection_paused_or_closed'));
    final cancellation = Completer<String>();
    _requests.add(cancellation);
    return Future.any([
      Future.sync(() => _transport(kind, body)),
      cancellation.future,
    ]).whenComplete(() {
      _requests.remove(cancellation);
    });
  }

  void _cancelRequests() {
    for (final request in _requests.toList()) {
      if (!request.isCompleted)
        request.completeError(StateError('connection_paused_or_closed'));
    }
  }

  Future<void> _loop() async {
    while (!_stopped) {
      final observed = _epoch;
      final action = await _command('next') as Map;
      if (_stopped) return;
      if (action['type'] == 'sync') {
        try {
          _activeSync = _sync(_request);
          await _activeSync;
          if (!_stopped) await _command('success');
        } catch (error) {
          if (_stopped) return;
          if (_paused) {
            await _command('success');
            continue;
          }
          onError?.call(error);
          if (error is AuthenticationExpired && refreshAuth != null) {
            try {
              await refreshAuth!();
            } catch (error) {
              onError?.call(error);
            }
          }
          if (!_stopped) await _command('failure');
        } finally {
          _activeSync = null;
        }
      } else {
        if (observed != _epoch) continue;
        await _wait(action['type'] == 'wait' ? action['millis'] as int : null);
      }
    }
  }

  Future<void> pause() async {
    if (_stopped) return;
    _paused = true;
    _cancelRequests();
    await _command('pause');
    try {
      await _activeSync;
    } catch (_) {}
    _notify();
  }

  Future<void> resume() async {
    if (_stopped) return;
    _paused = false;
    await _command('resume');
    _notify();
  }

  Future<void> wake() async {
    if (_stopped) return;
    await _command('wake');
    _notify();
  }

  Future<void> close() async {
    if (_stopped) return;
    _stopped = true;
    _cancelRequests();
    _notify();
    try {
      await _command('stop');
    } finally {
      _closed.complete();
    }
  }
}

class AuthenticationExpired implements Exception {
  const AuthenticationExpired();
}
