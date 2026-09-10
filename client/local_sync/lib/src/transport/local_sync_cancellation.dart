import 'dart:async';

/// A one-way cancellation token. The caller cancels; the transport binds its
/// in-flight call to it. There is no un-cancel, so a token is single use.
final class LocalSyncCancellation {
  LocalSyncCancellation();

  final List<Future<void> Function()> _bound = <Future<void> Function()>[];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// Cancel every call bound to this token, now and later.
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    final bound = List<Future<void> Function()>.of(_bound);
    _bound.clear();
    for (final cancelCall in bound) {
      await cancelCall();
    }
  }

  void _bind(Future<void> Function() cancelCall) {
    if (_cancelled) {
      unawaited(cancelCall());
      return;
    }
    _bound.add(cancelCall);
  }
}

/// Bind a live call to the caller's token. A transport calls this instead of
/// holding any cancellation policy of its own.
void bindLocalSyncCancellation(
  LocalSyncCancellation? cancellation,
  Future<void> Function() cancelCall,
) {
  cancellation?._bind(cancelCall);
}
