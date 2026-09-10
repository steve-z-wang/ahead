import 'dart:async';
import 'dart:typed_data';

import 'http_status_classifier.dart';
import 'local_sync_access_token_provider.dart';
import 'local_sync_cancellation.dart';
import 'local_sync_transport.dart';

/// The App's three-layer authentication convention, as a transport wrapper.
///
/// A call carries the cached credential. Refused as unauthorized, it is made
/// again exactly once with a forcibly refreshed one — an expired token heals
/// silently. A second refusal is the revoked account: its 401 reaches the
/// worker unchanged and is terminal there. Signing out is never this wrapper's
/// business; the product's auth stream tears the session down.
///
/// `inner` is a factory, not an instance, because the credential intent is
/// fixed when the transport is built. It is invoked at most twice — once for
/// cached credentials, once more the first time a refresh is needed — so it
/// must be a cheap wrapper over already-shared resources. [start], [close] and
/// the live channel belong to the cached-credential instance alone, for the
/// same reason: both speak over the one connection, opened and shut once.
final class AuthRefreshingTransport implements LocalSyncTransport {
  AuthRefreshingTransport({
    required LocalSyncAccessTokenProvider provider,
    required LocalSyncTransport Function(
      Future<String> Function() getAccessToken,
    )
    inner,
  }) : _provider = provider,
       _inner = inner;

  final LocalSyncAccessTokenProvider _provider;
  final LocalSyncTransport Function(Future<String> Function()) _inner;

  late final LocalSyncTransport _cached = _inner(
    () => _provider(forceRefresh: false),
  );
  late final LocalSyncTransport _refreshed = _inner(
    () => _provider(forceRefresh: true),
  );

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => _cached.downlinkEvents;

  @override
  Future<void> start() => _cached.start();

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _retryingOnce(
    (transport) => transport.sendUplink(body, cancellation: cancellation),
  );

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => _retryingOnce(
    (transport) => transport.fetchDownlink(body, cancellation: cancellation),
  );

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) =>
      _cached.sendDownlinkFrame(frame);

  @override
  Future<void> restartDownlinkConnection() =>
      _cached.restartDownlinkConnection();

  @override
  Future<void> close() => _cached.close();

  Future<LocalSyncHttpResponse> _retryingOnce(
    Future<LocalSyncHttpResponse> Function(LocalSyncTransport transport) call,
  ) async {
    final response = await call(_cached);
    if (response.statusCode != localSyncUnauthorizedStatus) return response;
    return call(_refreshed);
  }
}
