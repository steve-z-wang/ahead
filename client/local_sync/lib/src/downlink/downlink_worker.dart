import 'dart:async';
import 'dart:typed_data';

import '../local_sync_client_failure.dart';
import '../transport/http_status_classifier.dart';
import '../transport/local_sync_cancellation.dart';
import '../transport/local_sync_lifecycle.dart';
import '../transport/local_sync_protocol_codec.dart';
import '../transport/local_sync_transport.dart';
import '../transport/local_sync_transport_failure.dart';
import '../uplink/local_sync_terminal_exception.dart';
import '../uplink/retry_policy.dart';
import 'downlink_exception.dart';
import 'downlink_page_queue.dart';
import 'downlink_protocol.dart';
import 'downlink_page_processor.dart';

typedef DownlinkSleep = Future<void> Function(Duration duration);

/// Coordinates one live connection and one independent cursor stream per
/// demanded scope. Each state is a cancellable generation; removing and later
/// readding the same key can never make an old response current again.
final class DownlinkWorker implements LocalSyncDownlinkWorker {
  DownlinkWorker({
    required this.state,
    required this.processor,
    required this.transport,
    required this.codec,
    required RetryPolicy Function() retryPolicyFactory,
    LocalSyncClientFailureObserver? failureObserver,
    DownlinkPageQueue Function()? pageQueueFactory,
    DownlinkSleep? sleep,
  }) : _retryPolicyFactory = retryPolicyFactory,
       _failureObserver = failureObserver,
       _pageQueueFactory = pageQueueFactory ?? DownlinkPageQueue.new,
       _sleep = sleep ?? _defaultSleep;

  final DownlinkStateReader state;
  final DownlinkPageHandler processor;
  final LocalSyncTransport transport;
  final LocalSyncProtocolCodec codec;
  final LocalSyncClientFailureObserver? _failureObserver;
  final RetryPolicy Function() _retryPolicyFactory;
  final DownlinkPageQueue Function() _pageQueueFactory;
  final DownlinkSleep _sleep;
  final Map<String, _DownlinkScopeState> _states = {};

  StreamSubscription<DownlinkTransportEvent>? _events;
  final Completer<void> _closing = Completer<void>();
  List<String> _requestedScopes = const [];
  int _connectionVersion = 0;
  bool _awaitingAck = false;
  bool _restarting = false;
  bool _terminal = false;
  bool _closed = false;
  bool _protocolFailureReported = false;

  @override
  Future<void> replaceScopes(Iterable<String> scopes) async {
    if (_closed) return;
    final desired = _normalizeAllowEmpty(scopes);
    if (_sameScopeSet(desired, _activeScopes)) return;

    final desiredSet = desired.toSet();
    final removed = _states.keys
        .where((scope) => !desiredSet.contains(scope))
        .toList(growable: false);
    final added = desired
        .where((scope) => !_states.containsKey(scope))
        .toList(growable: false);

    await _cancelAndRemove(removed);
    for (final scope in added) {
      _states[scope] = _DownlinkScopeState(
        scope: scope,
        pageQueue: _pageQueueFactory(),
        retryPolicy: _retryPolicyFactory(),
      );
    }
    if (_events != null && !_terminal) await _restartForLatestSet();
  }

  List<String> get _activeScopes => _states.keys.toList()..sort();

  @override
  void start() {
    if (_events != null) {
      throw StateError('DownlinkWorker already started');
    }
    _events = transport.downlinkEvents.listen((event) {
      if (_closed || _terminal) return;
      switch (event) {
        case DownlinkConnected():
          _onConnected();
        case DownlinkPageReceived(:final page):
          _receive(page);
        case DownlinkFailed(:final failure):
          _terminate(
            LocalSyncTerminalException('terminal Downlink failure', failure),
            StackTrace.current,
          );
      }
    });
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      if (!_closing.isCompleted) _closing.complete();
    }
    await _events?.cancel();
    await _cancelAndRemove(_states.keys.toList(growable: false));
  }

  Future<void> _cancelAndRemove(Iterable<String> scopes) async {
    final removed = <_DownlinkScopeState>[];
    for (final scope in scopes) {
      final scoped = _states.remove(scope);
      if (scoped == null) continue;
      scoped.pageQueue.clear();
      scoped.deactivate();
      removed.add(scoped);
    }
    await Future.wait<void>([
      for (final scoped in removed) scoped.cancellation.cancel(),
    ]);
    await Future.wait<void>([
      for (final scoped in removed)
        if (scoped.loop != null) scoped.loop!,
    ]);
  }

  void _onConnected() {
    _protocolFailureReported = false;
    _connectionVersion += 1;
    final version = _connectionVersion;
    _restarting = false;
    _requestedScopes = List.unmodifiable(_activeScopes);
    for (final scoped in _states.values) {
      scoped.pageQueue.clear();
    }
    if (_requestedScopes.isEmpty) {
      _awaitingAck = false;
      return;
    }
    _awaitingAck = true;

    late final Uint8List frame;
    try {
      frame = codec.encodeDownlinkSubscribe(_requestedScopes);
    } catch (error, stackTrace) {
      _terminate(
        LocalSyncTerminalException('invalid durable Downlink scope set', error),
        stackTrace,
      );
      return;
    }
    unawaited(_sendSubscribe(version, frame));
  }

  Future<void> _sendSubscribe(int version, Uint8List frame) async {
    try {
      await transport.sendDownlinkFrame(frame);
    } catch (error, stackTrace) {
      if (_closed || _terminal || version != _connectionVersion) return;
      _protocolReconnect(
        DownlinkPageException('could not send Downlink subscription', error),
        stackTrace,
      );
    }
  }

  void _receive(Uint8List bytes) {
    if (_restarting) return;
    late final DownlinkLiveMessage message;
    try {
      message = codec.decodeDownlinkLiveMessage(bytes);
    } catch (error, stackTrace) {
      _protocolReconnect(
        DownlinkPageException('invalid live Downlink message', error),
        stackTrace,
      );
      return;
    }

    switch (message) {
      case DownlinkSubscribed(:final scopes, :final rejections):
        if (!_awaitingAck) {
          _protocolReconnect(
            const DownlinkPageException(
              'duplicate Downlink subscription acknowledgement',
            ),
            StackTrace.current,
          );
          return;
        }
        final rejectedScopes = rejections
            .map((rejection) => rejection.scope)
            .toList(growable: false);
        if (!_isExactPartition(scopes, rejectedScopes, _requestedScopes)) {
          _terminate(
            const LocalSyncTerminalException(
              'Downlink subscription acknowledgement changed the scope partition',
            ),
            StackTrace.current,
          );
          return;
        }
        _awaitingAck = false;
        for (final rejection in rejections) {
          final scoped = _states[rejection.scope];
          if (scoped != null) _disable(scoped);
        }
        for (final scope in scopes) {
          final scoped = _states[scope];
          if (scoped == null) continue;
          scoped.disabledConnectionVersion = null;
          _requireCatchUp(scoped);
          _wake(scoped);
        }
      case DownlinkLivePage(:final page):
        if (_awaitingAck) {
          _protocolReconnect(
            const DownlinkPageException(
              'live Downlink page arrived before subscription acknowledgement',
            ),
            StackTrace.current,
          );
          return;
        }
        final scoped = _states[page.scope];
        if (scoped == null) {
          _protocolReconnect(
            DownlinkPageException(
              'live Downlink page belongs to inactive ${page.scope}',
            ),
            StackTrace.current,
          );
          return;
        }
        if (scoped.disabledConnectionVersion == _connectionVersion) return;
        if (!scoped.pageQueue.add(page)) _requireCatchUp(scoped);
        _wake(scoped);
    }
  }

  void _protocolReconnect(Object error, StackTrace stackTrace) {
    if (_closed || _terminal || _restarting) return;
    _prepareRestart();
    _reportRetrying(null, error, stackTrace);
    unawaited(_restartConnection());
  }

  Future<void> _restartForLatestSet() async {
    if (_closed || _terminal) return;
    _prepareRestart();
    await _restartConnection();
  }

  void _prepareRestart() {
    _restarting = true;
    _awaitingAck = true;
    _connectionVersion += 1;
    for (final scoped in _states.values) {
      scoped.pageQueue.clear();
    }
  }

  Future<void> _restartConnection() async {
    try {
      await transport.restartDownlinkConnection();
    } catch (error, stackTrace) {
      if (_closed || _terminal) return;
      _restarting = false;
      _reportRetrying(null, error, stackTrace);
    }
  }

  void _wake(_DownlinkScopeState scoped) {
    if (!_canSync(scoped)) return;
    scoped.wakeVersion += 1;
    _schedule(scoped);
  }

  void _schedule(_DownlinkScopeState scoped) {
    if (!_canSync(scoped) || scoped.loop != null) return;
    final scheduledAt = scoped.wakeVersion;
    final created = _run(scoped);
    scoped.loop = created;
    unawaited(
      created.whenComplete(() {
        if (identical(scoped.loop, created)) scoped.loop = null;
        if (_canSync(scoped) && scoped.wakeVersion != scheduledAt) {
          _schedule(scoped);
        }
      }),
    );
  }

  Future<void> _run(_DownlinkScopeState scoped) async {
    while (_canSync(scoped)) {
      final cursor = await _readCursor(scoped);
      if (cursor == null || !_canSync(scoped)) return;

      if (scoped.catchUpRequired) {
        final catchUpVersion = scoped.catchUpVersion;
        if (!await _fetchAndApply(scoped, cursor, catchUpVersion)) return;
        continue;
      }

      final queued = scoped.pageQueue.first;
      if (queued == null) return;
      if (queued.throughSyncId <= cursor) {
        scoped.pageQueue.removeFirst();
        continue;
      }
      if (queued.fromSyncId == cursor) {
        scoped.pageQueue.removeFirst();
        if (!await _applyPage(scoped, queued, cursor)) return;
        continue;
      }
      if (queued.fromSyncId < cursor) {
        scoped.pageQueue.removeFirst();
      }
      _requireCatchUp(scoped);
    }
  }

  Future<int?> _readCursor(_DownlinkScopeState scoped) async {
    while (_canSync(scoped)) {
      try {
        final cursor = await state.readLastAppliedSyncId(scoped.scope);
        return _canSync(scoped) ? cursor : null;
      } catch (error, stackTrace) {
        if (!await _retryPage(scoped, error, stackTrace)) {
          return null;
        }
      }
    }
    return null;
  }

  Future<bool> _fetchAndApply(
    _DownlinkScopeState scoped,
    int cursor,
    int catchUpVersion,
  ) async {
    late final Uint8List body;
    try {
      final clientId = await state.readClientId();
      if (!_canSync(scoped)) return false;
      body = codec.encodeDownlinkRequest(
        clientId: clientId,
        scope: scoped.scope,
        afterSyncId: cursor,
      );
    } catch (error, stackTrace) {
      if (!_canSync(scoped)) return false;
      _terminate(
        LocalSyncTerminalException('invalid durable Downlink state', error),
        stackTrace,
      );
      return false;
    }

    final response = await _fetchUntilResponse(scoped, body);
    if (response == null || !_canSync(scoped)) return false;
    try {
      final page = codec.decodeDownlinkPage(response);
      if (!_canSync(scoped)) return false;
      if (page.scope != scoped.scope) {
        throw DownlinkPageException(
          'pulled Downlink page belongs to ${page.scope}, '
          'expected ${scoped.scope}',
        );
      }
      if (page.fromSyncId != cursor) {
        throw DownlinkPageException(
          'pulled Downlink page starts at ${page.fromSyncId}, expected $cursor',
        );
      }
      if (page.throughSyncId == cursor) {
        if (catchUpVersion > scoped.caughtUpVersion) {
          scoped.caughtUpVersion = catchUpVersion;
        }
        scoped.retryPolicy.reset();
        scoped.failureReported = false;
        return true;
      }
      return _applyPage(scoped, page, cursor);
    } catch (error, stackTrace) {
      if (!_canSync(scoped)) return false;
      return _retryPage(scoped, error, stackTrace);
    }
  }

  Future<bool> _applyPage(
    _DownlinkScopeState scoped,
    DownlinkPage page,
    int cursor,
  ) async {
    if (!_canSync(scoped)) return false;
    try {
      final result = await processor.apply(page, afterSyncId: cursor);
      if (!_canSync(scoped)) return false;
      scoped.retryPolicy.reset();
      scoped.failureReported = false;
      for (final failure in result.failures) {
        _reportContinuing(failure, failure.stackTrace);
      }
      return true;
    } catch (error, stackTrace) {
      if (!_canSync(scoped)) return false;
      _requireCatchUp(scoped);
      return _retryPage(scoped, error, stackTrace);
    }
  }

  Future<Uint8List?> _fetchUntilResponse(
    _DownlinkScopeState scoped,
    Uint8List body,
  ) async {
    while (_canSync(scoped)) {
      try {
        final response = await Future.any<LocalSyncHttpResponse?>([
          transport.fetchDownlink(body, cancellation: scoped.cancellation),
          scoped.inactive.future.then<LocalSyncHttpResponse?>((_) => null),
        ]);
        if (response == null || !_canSync(scoped)) return null;
        return localSyncResponseBody(response);
      } on LocalSyncRetryableTransportFailure {
        if (!await _waitForRetry(scoped, scoped.retryPolicy.nextDelay())) {
          return null;
        }
      } on LocalSyncCancelledTransportFailure {
        if (!_canSync(scoped) ||
            !await _waitForRetry(scoped, scoped.retryPolicy.nextDelay())) {
          return null;
        }
      } on LocalSyncTerminalTransportFailure catch (error, stackTrace) {
        if (!_canSync(scoped)) return null;
        if (error.status == 403) {
          _disable(scoped);
          return null;
        }
        _terminate(
          LocalSyncTerminalException('terminal Downlink failure', error),
          stackTrace,
        );
        return null;
      } catch (error, stackTrace) {
        if (!_canSync(scoped)) return null;
        _reportRetrying(scoped, error, stackTrace);
        if (!await _waitForRetry(scoped, scoped.retryPolicy.nextDelay())) {
          return null;
        }
      }
    }
    return null;
  }

  Future<bool> _retryPage(
    _DownlinkScopeState scoped,
    Object error,
    StackTrace stackTrace,
  ) async {
    if (!_canSync(scoped)) return false;
    _reportRetrying(scoped, error, stackTrace);
    return _waitForRetry(scoped, scoped.retryPolicy.nextDelay());
  }

  Future<bool> _waitForRetry(
    _DownlinkScopeState scoped,
    Duration duration,
  ) async {
    await Future.any<void>([
      _sleep(duration),
      _closing.future,
      scoped.inactive.future,
    ]);
    return _canSync(scoped);
  }

  bool _isCurrent(_DownlinkScopeState scoped) =>
      !_closed &&
      !_terminal &&
      identical(_states[scoped.scope], scoped) &&
      !scoped.inactive.isCompleted;

  bool _canSync(_DownlinkScopeState scoped) =>
      _isCurrent(scoped) &&
      scoped.disabledConnectionVersion != _connectionVersion;

  void _disable(_DownlinkScopeState scoped) {
    if (!_isCurrent(scoped)) return;
    final disabledVersion = _connectionVersion;
    scoped.disabledConnectionVersion = disabledVersion;
    scoped.pageQueue.clear();
    unawaited(_retryRejectedScope(scoped, disabledVersion));
  }

  Future<void> _retryRejectedScope(
    _DownlinkScopeState scoped,
    int disabledVersion,
  ) async {
    await Future.any<void>([
      _sleep(scoped.retryPolicy.nextDelay()),
      _closing.future,
      scoped.inactive.future,
    ]);
    if (!_isCurrent(scoped) ||
        scoped.disabledConnectionVersion != disabledVersion ||
        disabledVersion != _connectionVersion ||
        _restarting) {
      return;
    }
    await _restartForLatestSet();
  }

  void _reportRetrying(
    _DownlinkScopeState? scoped,
    Object error,
    StackTrace stackTrace,
  ) {
    if (scoped == null) {
      if (_protocolFailureReported) return;
      _protocolFailureReported = true;
    } else {
      if (scoped.failureReported) return;
      scoped.failureReported = true;
    }
    _notify(error, stackTrace, LocalSyncClientFailureFate.retrying);
  }

  void _reportContinuing(Object error, StackTrace stackTrace) {
    _notify(error, stackTrace, LocalSyncClientFailureFate.continuing);
  }

  void _notify(
    Object error,
    StackTrace stackTrace,
    LocalSyncClientFailureFate fate,
  ) {
    notifyLocalSyncClientFailure(
      _failureObserver,
      LocalSyncClientFailure(
        error: error,
        stackTrace: stackTrace,
        boundary: LocalSyncClientFailureBoundary.downlink,
        fate: fate,
      ),
    );
  }

  void _terminate(Object error, StackTrace stackTrace) {
    if (_closed || _terminal) return;
    _terminal = true;
    for (final scoped in _states.values) {
      scoped.pageQueue.clear();
      scoped.deactivate();
      unawaited(scoped.cancellation.cancel());
    }
    _notify(error, stackTrace, LocalSyncClientFailureFate.terminal);
  }

  void _requireCatchUp(_DownlinkScopeState scoped) {
    if (_isCurrent(scoped)) scoped.catchUpVersion += 1;
  }
}

final class _DownlinkScopeState {
  _DownlinkScopeState({
    required this.scope,
    required this.pageQueue,
    required this.retryPolicy,
  });

  final String scope;
  final DownlinkPageQueue pageQueue;
  final RetryPolicy retryPolicy;
  final LocalSyncCancellation cancellation = LocalSyncCancellation();
  final Completer<void> inactive = Completer<void>();
  Future<void>? loop;
  int wakeVersion = 0;
  int catchUpVersion = 0;
  int caughtUpVersion = 0;
  int? disabledConnectionVersion;
  bool failureReported = false;

  bool get catchUpRequired => caughtUpVersion < catchUpVersion;

  void deactivate() {
    if (!inactive.isCompleted) inactive.complete();
  }
}

List<String> _normalizeAllowEmpty(Iterable<String> scopes) {
  final normalized = scopes.toSet().toList()..sort();
  return List.unmodifiable(normalized);
}

bool _sameScopeSet(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _isExactPartition(
  List<String> accepted,
  List<String> rejected,
  List<String> requested,
) {
  final acceptedSet = accepted.toSet();
  final rejectedSet = rejected.toSet();
  if (acceptedSet.intersection(rejectedSet).isNotEmpty) return false;
  return acceptedSet.union(rejectedSet).length == requested.length &&
      acceptedSet.union(rejectedSet).containsAll(requested);
}

Future<void> _defaultSleep(Duration duration) => Future<void>.delayed(duration);
