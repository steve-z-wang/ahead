import 'dart:typed_data';

import 'local_sync_transport.dart';
import 'local_sync_transport_failure.dart';

/// The one status this wrapper acts on by name: an expired credential heals by
/// being fetched again, so the auth wrapper retries it exactly once.
const int localSyncUnauthorizedStatus = 401;

/// The single classification table, shared with the TypeScript host.
///
/// Retryable is the narrow set whose answer can change on its own: the server
/// was busy, slow, or briefly gone. Everything else the server said is
/// terminal, because asking again with the same bytes cannot change a refusal
/// it decided from the request itself.
LocalSyncTransportFailure classifyLocalSyncHttpStatus(
  int status,
  String? message,
) {
  final detail = (message == null || message.isEmpty)
      ? 'LocalSync HTTP status $status'
      : message;
  if (status == 408 || status == 429 || status >= 500) {
    return LocalSyncRetryableTransportFailure(detail, status: status);
  }
  return LocalSyncTerminalTransportFailure(detail, status: status);
}

/// The body of a successful answer, or the failure the status names.
///
/// Workers read this rather than a status code: what a status means for retry
/// is the protocol's decision, made once, here.
Uint8List localSyncResponseBody(LocalSyncHttpResponse response) {
  if (response.isSuccess) return response.body;
  throw classifyLocalSyncHttpStatus(response.statusCode, _detail(response));
}

String? _detail(LocalSyncHttpResponse response) {
  if (response.body.isEmpty) return null;
  try {
    // A short server message helps a report; a long body is never worth
    // carrying into an exception message.
    final text = String.fromCharCodes(response.body.take(200));
    return text.trim().isEmpty ? null : text.trim();
  } catch (_) {
    return null;
  }
}
