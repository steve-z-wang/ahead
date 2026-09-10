import 'dart:async';

import '../local_sync_client_failure.dart';
import 'prerequisite.dart';
import 'readiness_ledger.dart';

final class PrerequisiteRunner {
  PrerequisiteRunner({
    required this.ledger,
    required this.handlers,
    required Duration Function(int attempt) retryDelay,
    this.parallelism = 2,
    LocalSyncClientFailureObserver? failureObserver,
  }) : _retryDelay = retryDelay,
       _failureObserver = failureObserver {
    if (parallelism < 1) {
      throw ArgumentError.value(parallelism, 'parallelism');
    }
  }

  final ReadinessLedger ledger;
  final PrerequisiteHandlerRegistry handlers;
  final int parallelism;
  final Duration Function(int attempt) _retryDelay;
  final LocalSyncClientFailureObserver? _failureObserver;

  Set<PrerequisiteInvocation> _desired = const {};
  final _checking = <PrerequisiteInvocation>{};
  final _ready = <PrerequisiteInvocation>{};
  final _inFlight = <PrerequisiteInvocation>{};
  final _faulted = <PrerequisiteInvocation>{};
  final _retryAttempts = <PrerequisiteInvocation, int>{};
  final _retryTimers = <PrerequisiteInvocation, Timer>{};
  final _writes = <Future<void>>{};
  bool _closed = false;

  void reconcile(Iterable<PrerequisiteInvocation> desired) {
    if (_closed) return;
    _desired = Set.unmodifiable(desired);
    for (final entry in _retryTimers.entries.toList()) {
      if (_desired.contains(entry.key)) continue;
      entry.value.cancel();
      _retryTimers.remove(entry.key);
      _retryAttempts.remove(entry.key);
    }
    _ready.retainAll(_desired);
    _faulted.retainAll(_desired);
    _pump();
  }

  Future<void> close() async {
    _closed = true;
    _desired = const {};
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _ready.clear();
    _faulted.clear();
    while (_writes.isNotEmpty) {
      await Future.wait(_writes.toList());
    }
  }

  void _pump() {
    if (_closed) return;
    for (final invocation in _desired) {
      if (_checking.contains(invocation) ||
          _ready.contains(invocation) ||
          _inFlight.contains(invocation) ||
          _faulted.contains(invocation) ||
          _retryTimers.containsKey(invocation)) {
        continue;
      }
      _checking.add(invocation);
      unawaited(_consider(invocation));
    }
    _startReady();
  }

  Future<void> _consider(PrerequisiteInvocation invocation) async {
    try {
      final state = await ledger.read(invocation);
      if (!_closed &&
          _desired.contains(invocation) &&
          state == ReadinessState.pending) {
        _ready.add(invocation);
      }
    } catch (error, stackTrace) {
      if (!_closed) {
        if (_desired.contains(invocation)) _faulted.add(invocation);
        _report(error, stackTrace);
      }
    } finally {
      _checking.remove(invocation);
      _startReady();
    }
  }

  void _startReady() {
    if (_closed) return;
    while (_inFlight.length < parallelism && _ready.isNotEmpty) {
      final invocation = _ready.first;
      _ready.remove(invocation);
      if (!_desired.contains(invocation)) continue;
      _inFlight.add(invocation);
      unawaited(_attempt(invocation));
    }
  }

  Future<void> _attempt(PrerequisiteInvocation invocation) async {
    try {
      final result = await handlers.dispatch(invocation);
      if (_closed || !_desired.contains(invocation)) return;
      switch (result) {
        case PrerequisiteAttemptResult.ready:
          _retryAttempts.remove(invocation);
          await _trackWrite(() => ledger.markReady(invocation));
        case PrerequisiteAttemptResult.failed:
          _retryAttempts.remove(invocation);
          await _trackWrite(() => ledger.markFailed(invocation));
        case PrerequisiteAttemptResult.retry:
          _scheduleRetry(invocation);
      }
    } catch (error, stackTrace) {
      if (!_closed) {
        if (_desired.contains(invocation)) _faulted.add(invocation);
        _report(error, stackTrace);
      }
    } finally {
      _inFlight.remove(invocation);
      _pump();
    }
  }

  void _scheduleRetry(PrerequisiteInvocation invocation) {
    if (_closed || !_desired.contains(invocation)) return;
    final attempt = (_retryAttempts[invocation] ?? 0) + 1;
    _retryAttempts[invocation] = attempt;
    _retryTimers[invocation] = Timer(_retryDelay(attempt), () {
      _retryTimers.remove(invocation);
      _pump();
    });
  }

  Future<void> _trackWrite(Future<void> Function() operation) async {
    final write = operation();
    _writes.add(write);
    try {
      await write;
    } finally {
      _writes.remove(write);
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    notifyLocalSyncClientFailure(
      _failureObserver,
      LocalSyncClientFailure(
        error: error,
        stackTrace: stackTrace,
        boundary: LocalSyncClientFailureBoundary.prerequisite,
        fate: LocalSyncClientFailureFate.continuing,
      ),
    );
  }
}
