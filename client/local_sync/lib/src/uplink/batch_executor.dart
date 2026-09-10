import 'dart:async';
import 'dart:typed_data';

import '../local_sync_client_failure.dart';
import '../transport/http_status_classifier.dart';
import '../transport/local_sync_cancellation.dart';
import '../transport/local_sync_protocol_codec.dart';
import '../transport/local_sync_transport.dart';
import '../transport/local_sync_transport_failure.dart';
import 'local_sync_terminal_exception.dart';
import 'mutation_queue.dart';
import 'retry_policy.dart';
import 'uplink_protocol.dart';

typedef UplinkSleep = Future<void> Function(Duration duration);

final class BatchExecutor {
  BatchExecutor({
    required this.codec,
    required this.transport,
    required this.retryPolicy,
    UplinkSleep? sleep,
    LocalSyncClientFailureObserver? failureObserver,
  }) : _sleep = sleep ?? _defaultSleep,
       _failureObserver = failureObserver;

  final LocalSyncProtocolCodec codec;
  final LocalSyncTransport transport;
  final RetryPolicy retryPolicy;
  final UplinkSleep _sleep;
  final LocalSyncClientFailureObserver? _failureObserver;
  final LocalSyncCancellation _cancellation = LocalSyncCancellation();
  final Completer<void> _closing = Completer<void>();
  bool _closed = false;
  bool _unexpectedEpisodeReported = false;

  Future<BatchExecutionResult?> execute(UplinkBatch batch) async {
    final body = codec.encodeUplinkRequest(
      clientId: batch.clientId,
      batchSequence: batch.batchSequence,
      mutations: batch.mutations,
      records: batch.records,
    );
    final response = await _sendUntilResponse(body);
    if (response == null) return null;
    try {
      final decoded = codec.decodeUplinkResponse(
        response,
        requestMutationIds: {
          for (final record in batch.records.values)
            record.legacyWireOrdinal ?? record.ordinal,
        },
      );
      retryPolicy.reset();
      return BatchExecutionResult(
        batchSequence: batch.batchSequence,
        requiredCheckpoints: decoded.requiredCheckpoints,
        legacyPrincipalCheckpoint: decoded.legacyPrincipalCheckpoint,
        rejections: decoded.rejections,
      );
    } catch (error) {
      throw LocalSyncTerminalException('invalid Uplink response', error);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closing.complete();
    await _cancellation.cancel();
  }

  Future<Uint8List?> _sendUntilResponse(Uint8List body) async {
    while (!_closed) {
      try {
        final response = localSyncResponseBody(
          await transport.sendUplink(body, cancellation: _cancellation),
        );
        _unexpectedEpisodeReported = false;
        return response;
      } on LocalSyncRetryableTransportFailure {
        if (!await _waitForRetry(retryPolicy.nextDelay())) return null;
      } on LocalSyncCancelledTransportFailure {
        if (_closed) return null;
        if (!await _waitForRetry(retryPolicy.nextDelay())) return null;
      } on LocalSyncTerminalTransportFailure catch (error) {
        throw LocalSyncTerminalException('terminal Uplink failure', error);
      } catch (error, stackTrace) {
        if (!_unexpectedEpisodeReported) {
          _unexpectedEpisodeReported = true;
          notifyLocalSyncClientFailure(
            _failureObserver,
            LocalSyncClientFailure(
              error: error,
              stackTrace: stackTrace,
              boundary: LocalSyncClientFailureBoundary.uplink,
              fate: LocalSyncClientFailureFate.retrying,
            ),
          );
        }
        if (!await _waitForRetry(retryPolicy.nextDelay())) return null;
      }
    }
    return null;
  }

  Future<bool> _waitForRetry(Duration duration) async {
    await Future.any<void>([_sleep(duration), _closing.future]);
    return !_closed;
  }
}

Future<void> _defaultSleep(Duration duration) => Future<void>.delayed(duration);
