/// The durable worker boundary that consumed a LocalSync client failure.
enum LocalSyncClientFailureBoundary {
  uplink,
  downlink,
  scopes,
  prerequisite,
  live,
}

/// What LocalSync did after consuming a failure.
enum LocalSyncClientFailureFate { retrying, continuing, terminal }

/// A privacy-safe failure signal from LocalSync to its host application.
///
/// It deliberately carries no request, credential, scope, mutation, URI, or
/// payload. The host receives the original error and stack for grouping plus
/// fixed framework vocabulary describing the boundary and fate.
final class LocalSyncClientFailure {
  const LocalSyncClientFailure({
    required this.error,
    required this.stackTrace,
    required this.boundary,
    required this.fate,
  });

  final Object error;
  final StackTrace stackTrace;
  final LocalSyncClientFailureBoundary boundary;
  final LocalSyncClientFailureFate fate;
}

typedef LocalSyncClientFailureObserver =
    void Function(LocalSyncClientFailure failure);

/// Delivers diagnostics without allowing diagnostics to change sync fate.
void notifyLocalSyncClientFailure(
  LocalSyncClientFailureObserver? observer,
  LocalSyncClientFailure failure,
) {
  if (observer == null) return;
  try {
    observer(failure);
  } catch (_) {
    // Reporting cannot interrupt retry, continuation, or shutdown.
  }
}
