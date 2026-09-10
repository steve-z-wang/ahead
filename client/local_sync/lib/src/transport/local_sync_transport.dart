import 'dart:typed_data';

import 'local_sync_cancellation.dart';
import 'local_sync_transport_failure.dart';

/// What the live channel tells the worker. Nothing here is a page's meaning —
/// the bytes stay opaque until the codec above reads them.
sealed class DownlinkTransportEvent {
  const DownlinkTransportEvent();
}

/// The channel is open. Every connection — the first and every reconnect —
/// says this, because a client that was away may have missed changes and owes
/// itself a catch-up.
final class DownlinkConnected extends DownlinkTransportEvent {
  const DownlinkConnected();
}

/// One complete page, exactly as the server framed it.
final class DownlinkPageReceived extends DownlinkTransportEvent {
  const DownlinkPageReceived(this.page);

  final Uint8List page;
}

/// The channel will not open, and opening it again cannot change that — a
/// revoked credential, a build below the floor. Said once, rather than
/// reconnected against forever.
final class DownlinkFailed extends DownlinkTransportEvent {
  const DownlinkFailed(this.failure);

  final LocalSyncTransportFailure failure;
}

/// One answer from the far side: a status and a body, nothing interpreted.
final class LocalSyncHttpResponse {
  LocalSyncHttpResponse({
    required this.statusCode,
    required this.body,
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable(headers);

  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// The byte pipe. Requests and responses are already encoded, so no transport
/// implementation reads a Model — the codec sits above it, the socket below.
abstract interface class LocalSyncTransport {
  /// The live channel, opened by [start] and kept open until [close].
  Stream<DownlinkTransportEvent> get downlinkEvents;

  Future<void> start();

  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  });

  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  });

  /// Sends one already-encoded application frame on the current live socket.
  Future<void> sendDownlinkFrame(Uint8List frame);

  /// Ends the current live socket so the transport reconnects normally.
  Future<void> restartDownlinkConnection();

  /// Releases whatever the transport holds open. The runtime's lifecycle calls
  /// this once, after both workers have stopped.
  Future<void> close();
}
