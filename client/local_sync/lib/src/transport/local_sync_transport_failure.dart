/// How a transport failure must be treated. The wire protocol decides the
/// disposition once; every caller reads it instead of re-reading status codes.
sealed class LocalSyncTransportFailure implements Exception {
  const LocalSyncTransportFailure(this.message, {this.status});

  final String message;

  /// The transport status that produced this failure, when there was one.
  final int? status;

  @override
  String toString() => '$runtimeType: $message';
}

/// Retry with backoff, retaining the frozen batch bytes.
final class LocalSyncRetryableTransportFailure
    extends LocalSyncTransportFailure {
  const LocalSyncRetryableTransportFailure(super.message, {super.status});
}

/// Never retried: retrying cannot change the answer.
final class LocalSyncTerminalTransportFailure
    extends LocalSyncTransportFailure {
  const LocalSyncTerminalTransportFailure(super.message, {super.status});
}

/// The call was cancelled. The caller alone knows whether it did the
/// cancelling: if it did, stop; otherwise this is an ordinary retry.
final class LocalSyncCancelledTransportFailure
    extends LocalSyncTransportFailure {
  const LocalSyncCancelledTransportFailure(super.message, {super.status});
}
