import 'dart:async';

import '../local_sync_client_failure.dart';
import 'scope_store.dart';

typedef ScopeRetryDelay = Future<void> Function(Duration duration);

/// Repeatedly installs durable desired scope state until the worker agrees.
/// Notifications are hints; startup and every retry re-read SQLite.
final class ScopeReconciler {
  ScopeReconciler({
    required this.store,
    required this.replaceScopes,
    ScopeRetryDelay? retryDelay,
    LocalSyncClientFailureObserver? failureObserver,
  }) : _retryDelay = retryDelay ?? Future<void>.delayed,
       _failureObserver = failureObserver;

  final ScopeStore store;
  final Future<void> Function(List<String> scopes) replaceScopes;
  final ScopeRetryDelay _retryDelay;
  final LocalSyncClientFailureObserver? _failureObserver;

  final Completer<void> _closing = Completer<void>();
  final Completer<void> _firstConvergence = Completer<void>();
  StreamSubscription<void>? _subscription;
  Future<void>? _startFuture;
  Future<void>? _drainFuture;
  bool _dirty = false;
  bool _draining = false;
  bool _closed = false;
  int _attempt = 0;
  List<String>? _installed;
  bool _failureReported = false;

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    if (_closed) throw StateError('ScopeReconciler is closed');
    _subscription = store.watchCommittedChanges().listen((_) => notify());
    notify();
    await _firstConvergence.future;
  }

  void notify() {
    if (_closed) return;
    _dirty = true;
    if (_draining) return;
    _draining = true;
    _drainFuture = _drain();
  }

  Future<void> _drain() async {
    while (_dirty && !_closed) {
      _dirty = false;
      try {
        final desired = await store.effectiveDesiredScopes();
        if (!_sameScopes(_installed, desired)) {
          await replaceScopes(desired);
          _installed = List.unmodifiable(desired);
        }
        _attempt = 0;
        _failureReported = false;
        if (!_firstConvergence.isCompleted) _firstConvergence.complete();
      } on Object catch (error, stackTrace) {
        if (!_failureReported) {
          _failureReported = true;
          notifyLocalSyncClientFailure(
            _failureObserver,
            LocalSyncClientFailure(
              error: error,
              stackTrace: stackTrace,
              boundary: LocalSyncClientFailureBoundary.scopes,
              fate: LocalSyncClientFailureFate.retrying,
            ),
          );
        }
        _dirty = true;
        _attempt += 1;
        await Future.any<void>([
          _retryDelay(_delay(_attempt)),
          _closing.future,
        ]);
      }
    }
    _draining = false;
    if (_dirty && !_closed) notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_closing.isCompleted) _closing.complete();
    await _subscription?.cancel();
    await _drainFuture;
    if (!_firstConvergence.isCompleted) _firstConvergence.complete();
  }
}

Duration _delay(int attempt) {
  final exponent = attempt.clamp(1, 6) - 1;
  return Duration(milliseconds: 100 * (1 << exponent));
}

bool _sameScopes(List<String>? left, List<String> right) {
  if (left == null || left.length != right.length) return false;
  for (var index = 0; index < right.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
