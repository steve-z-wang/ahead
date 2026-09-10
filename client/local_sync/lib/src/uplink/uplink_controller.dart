import 'dart:async';
import 'dart:typed_data';

import '../local_sync_client_failure.dart';
import '../transport/local_sync_lifecycle.dart';
import '../transport/local_sync_protocol_codec.dart';
import 'batch_executor.dart';
import 'local_sync_terminal_exception.dart';
import 'mutation_queue.dart';
import 'mutation_queue_snapshot.dart';
import 'mutation_scheduler.dart';
import 'prerequisite_runner.dart';
import 'uplink_protocol.dart';

final class UplinkController implements LocalSyncBackgroundWorker {
  UplinkController({
    required this.queue,
    required this.codec,
    required this.scheduler,
    required this.prerequisiteRunner,
    required this.executor,
    required this.settleAccepted,
    LocalSyncClientFailureObserver? failureObserver,
  }) : _failureObserver = failureObserver;

  final MutationQueue queue;
  final LocalSyncProtocolCodec codec;
  final MutationScheduler scheduler;
  final PrerequisiteRunner prerequisiteRunner;
  final BatchExecutor executor;
  final Future<void> Function() settleAccepted;
  final LocalSyncClientFailureObserver? _failureObserver;

  StreamSubscription<bool>? _subscription;
  Future<void>? _loop;
  bool _rewake = false;
  bool _closed = false;

  @override
  void start() {
    if (_subscription != null) {
      throw StateError('UplinkController already started');
    }
    unawaited(_ensureLoop());
    _subscription = queue.watchSendable().listen((sendable) {
      if (sendable && !_closed) unawaited(_ensureLoop());
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    await prerequisiteRunner.close();
    await executor.close();
    await _subscription?.cancel();
    await _loop;
  }

  Future<void> _ensureLoop() async {
    final running = _loop;
    if (running != null) {
      _rewake = true;
      return;
    }
    _rewake = false;
    final created = _runGuarded();
    _loop = created;
    try {
      await created;
    } catch (error, stackTrace) {
      _closed = true;
      notifyLocalSyncClientFailure(
        _failureObserver,
        LocalSyncClientFailure(
          error: error,
          stackTrace: stackTrace,
          boundary: LocalSyncClientFailureBoundary.uplink,
          fate: LocalSyncClientFailureFate.terminal,
        ),
      );
    } finally {
      if (identical(_loop, created)) {
        _loop = null;
        if (_rewake && !_closed) {
          _rewake = false;
          unawaited(_ensureLoop());
        }
      }
    }
  }

  Future<void> _runGuarded() async {
    try {
      await settleAccepted();
      await _run();
    } on UplinkDataException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        LocalSyncTerminalException('invalid durable Uplink data', error),
        stackTrace,
      );
    }
  }

  Future<void> _run() async {
    while (!_closed) {
      var batch = await queue.readInFlightBatch();
      if (batch == null) {
        final snapshot = await queue.snapshot();
        prerequisiteRunner.reconcile({
          for (final mutation in snapshot.mutations)
            if (mutation.phase == MutationPhase.queued)
              ...mutation.prerequisites,
        });
        final selected = scheduler.select(
          snapshot,
          encodedBytes: (ordinals) => _encode(snapshot, ordinals).length,
        );
        if (selected.isEmpty) return;
        try {
          batch = await queue.freeze(
            expectedSequence: snapshot.nextBatchSequence,
            mutationOrdinals: selected,
          );
        } on StateError {
          continue;
        }
      }
      final result = await executor.execute(batch);
      if (result == null) return;
      await queue.record(result);
      await settleAccepted();
    }
  }

  Uint8List _encode(QueueSnapshot snapshot, List<int> ordinals) {
    final selected = ordinals.toSet();
    final mutations = [
      for (final mutation in snapshot.mutations)
        if (selected.contains(mutation.mutation.ordinal))
          ...mutation.operations,
    ];
    final records = {
      for (final mutation in snapshot.mutations)
        if (selected.contains(mutation.mutation.ordinal))
          mutation.mutation.ordinal: mutation.mutation,
    };
    return codec.encodeUplinkRequest(
      clientId: snapshot.clientId,
      batchSequence: snapshot.nextBatchSequence,
      mutations: mutations,
      records: records,
    );
  }
}

const maximumUplinkBatchBytes = 256 * 1024;
