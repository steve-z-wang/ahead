import 'dart:async';
import 'dart:typed_data';

import 'package:local_sync/local_sync.dart';

final class FakeUplinkTransport implements LocalSyncTransport {
  FakeUplinkTransport(this.results);

  static const Object blockUntilCancelled = Object();

  final List<Object> results;
  final List<Uint8List> bodies = [];
  int cancelCalls = 0;

  @override
  Stream<DownlinkTransportEvent> get downlinkEvents => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<LocalSyncHttpResponse> sendUplink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) {
    bodies.add(body);
    final result = results.removeAt(0);
    if (identical(result, blockUntilCancelled)) {
      final blocked = Completer<LocalSyncHttpResponse>();
      bindLocalSyncCancellation(cancellation, () async {
        cancelCalls += 1;
        blocked.completeError(
          const LocalSyncCancelledTransportFailure('cancelled'),
        );
      });
      return blocked.future;
    }
    if (result is Uint8List) {
      return Future.value(LocalSyncHttpResponse(statusCode: 200, body: result));
    }
    if (result is LocalSyncHttpResponse) return Future.value(result);
    return Future.error(result);
  }

  @override
  Future<LocalSyncHttpResponse> fetchDownlink(
    Uint8List body, {
    LocalSyncCancellation? cancellation,
  }) => throw StateError('Uplink must not pull Downlink');

  @override
  Future<void> sendDownlinkFrame(Uint8List frame) =>
      throw StateError('Uplink must not write Downlink');

  @override
  Future<void> restartDownlinkConnection() =>
      throw StateError('Uplink must not restart Downlink');

  @override
  Future<void> close() async {}
}
