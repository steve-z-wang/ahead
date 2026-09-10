import 'dart:async';

import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/mutation_store.dart';
import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../storage/database_scope.dart';
import '../storage/local_value_codec.dart';
import 'readiness_ledger.dart';
import 'queued_mutation.dart';

/// Where one identity's queued work stands.
///
/// The vocabulary is the product's, not the protocol's: no ordinals, no batch
/// sequence numbers, no ledger keys. What a screen needs to say is "still
/// waiting on something" or "on its way", and that is all this carries.
enum PendingMutationPhase {
  /// In the queue, and the group it belongs to is not ready.
  waiting,

  /// In the queue and ready; it goes with one of the next batches.
  sendable,

  /// Frozen into the batch currently being sent.
  inFlight,
}

/// Where the complete outbound queue currently stands.
///
/// The most advanced phase present wins. This deliberately has no failure
/// case: a durable failure inbox is a separate contract, while this view is
/// only the live queue/readiness/batch projection.
enum UplinkSummaryPhase { idle, waiting, sendable, inFlight }

final class PendingMutationStatus {
  const PendingMutationStatus({
    required this.model,
    required this.identity,
    required this.phase,
  });

  final String model;
  final ModelId identity;
  final PendingMutationPhase phase;

  @override
  bool operator ==(Object other) =>
      other is PendingMutationStatus &&
      other.model == model &&
      other.identity == identity &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(model, identity, phase);
}

/// A read-only view of delivery, derived from the queue, the ledger and the
/// batch state.
///
/// It writes nothing and stores nothing. Every phase is recomputed from what
/// the other tables already say, so there is no status that can drift from the
/// thing it describes.
///
/// Being derived, it reports where things stand rather than every step taken:
/// two writes landing between one recomputation and the next are seen as one
/// move, so a phase can be skipped. Explicit discard is visible through the
/// rebuilt local state and the prerequisite inbox, not a transient status event.
final class UplinkStatusView {
  UplinkStatusView({
    required this.database,
    required this.registry,
    this.codec = const LocalValueCodec(),
  }) : _planner = QueuedMutationPlanner(
         registry: registry,
         ledger: ReadinessLedger(database),
       );

  final LocalDatabaseScope database;
  final ModelRegistry registry;
  final LocalValueCodec codec;
  final QueuedMutationPlanner _planner;

  static const _watched = {
    'pending_mutations',
    'pending_mutation_operations',
    'uplink_batches',
    'readiness_states',
  };

  /// Follows the complete outbound queue for the lifetime of the subscription.
  ///
  /// Unlike the identity view, an empty queue is a value rather than a reason
  /// to close: the same subscriber observes later queue cycles too.
  Stream<UplinkSummaryPhase> watchSummary() {
    final controller = StreamController<UplinkSummaryPhase>();
    StreamSubscription<void>? changes;
    UplinkSummaryPhase? last;
    var generation = 0;
    var closed = false;

    Future<void> emit() async {
      final request = ++generation;
      try {
        final phase = await _summaryPhase();
        if (closed || request != generation || phase == last) return;
        last = phase;
        controller.add(phase);
      } catch (error, stackTrace) {
        if (!closed && request == generation) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller.onListen = () {
      changes = database.database
          .watchTables(_watched)
          .listen((_) => unawaited(emit()), onError: controller.addError);
      unawaited(emit());
    };
    controller.onCancel = () async {
      closed = true;
      generation++;
      await changes?.cancel();
    };
    return controller.stream;
  }

  /// Follows one identity until it settles.
  ///
  /// Sent, rejected and explicitly discarded rows leave without a terminal
  /// event: their outcome is already visible in the rebuilt local state.
  Stream<PendingMutationStatus> watch(String model, ModelId id) {
    final entry = registry[model];
    if (entry == null) throw StateError('unknown Model "$model"');
    final identityJson = codec.encodeIdentity(entry.schema, id);

    final controller = StreamController<PendingMutationStatus>();
    StreamSubscription<void>? changes;
    PendingMutationPhase? last;
    var closed = false;

    Future<void> emit() async {
      if (closed) return;
      final (phase, _) = await _phaseOf(model, identityJson);
      if (phase == null) {
        if (last != null) {
          closed = true;
          await changes?.cancel();
          await controller.close();
        }
        return;
      }
      if (phase == last) return;
      last = phase;
      controller.add(
        PendingMutationStatus(model: model, identity: id, phase: phase),
      );
    }

    controller.onListen = () {
      changes = database.database.watchTables(_watched).listen((_) {
        unawaited(emit());
      });
      unawaited(emit());
    };
    controller.onCancel = () async {
      closed = true;
      await changes?.cancel();
    };
    return controller.stream;
  }

  Future<UplinkSummaryPhase> _summaryPhase() => database.readTransaction(
    () async {
      final frozen = (await database.current.query(
        DatabaseQuery(
          sql:
              'SELECT 1 AS present FROM pending_mutations '
              'WHERE batch_sequence IS NOT NULL LIMIT 1',
        ),
      )).singleOrNull;
      if (frozen != null) return UplinkSummaryPhase.inFlight;

      final queue = await _mutations('parent.batch_sequence IS NULL', const []);
      if (queue.isEmpty) return UplinkSummaryPhase.idle;
      final planned = await _planner.plan(queue);
      if (planned.any((mutation) => mutation.state == ReadinessState.ready)) {
        return UplinkSummaryPhase.sendable;
      }
      return UplinkSummaryPhase.waiting;
    },
  );

  /// The identity's phase, and whether the group it sits in is doomed.
  Future<(PendingMutationPhase?, bool)> _phaseOf(
    String model,
    String identityJson,
  ) => database.readTransaction(() async {
    final own = await _mutations('model = ? AND identity_json = ?', [
      model,
      identityJson,
    ]);
    if (own.isEmpty) return (null, false);
    if (await _hasFrozen(model, identityJson)) {
      return (PendingMutationPhase.inFlight, false);
    }
    final queue = await _mutations('parent.batch_sequence IS NULL', []);
    final mutations = await _planner.plan(queue);
    for (final mutation in mutations) {
      final isMine = mutation.operations.any(
        (row) => row.model == model && row.identityJson == identityJson,
      );
      if (!isMine) continue;
      // A named act dies whole: which writes share fate is schema, so one
      // failed key dooms every operation the act is spelled with, not just
      // the one carrying it.
      return (
        mutation.state == ReadinessState.ready
            ? PendingMutationPhase.sendable
            : PendingMutationPhase.waiting,
        mutation.state == ReadinessState.failed,
      );
    }
    return (PendingMutationPhase.waiting, false);
  });

  Future<bool> _hasFrozen(String model, String identityJson) async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql: '''
          SELECT 1 AS present
          FROM pending_mutation_operations AS operation
          JOIN pending_mutations AS parent
            ON parent.ordinal = operation.mutation_ordinal
          WHERE operation.model = ? AND operation.identity_json = ?
            AND parent.batch_sequence IS NOT NULL
          LIMIT 1
        ''',
        variables: [model, identityJson],
      ),
    )).singleOrNull;
    return row != null;
  }

  Future<List<StoredMutationOperation>> _mutations(
    String predicate,
    List<Object?> variables,
  ) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql:
            '''
          SELECT parent.name AS mutation_name,
                 parent.version AS mutation_version,
                 operation.mutation_ordinal, operation.position,
                 operation.slot_name,
                 operation.model, operation.identity_json,
                 operation.operation, operation.values_json,
                 operation.is_uplink
          FROM pending_mutation_operations AS operation
          JOIN pending_mutations AS parent
            ON parent.ordinal = operation.mutation_ordinal
          WHERE $predicate
          ORDER BY operation.mutation_ordinal, operation.position
        ''',
        variables: variables,
      ),
    );
    return List<StoredMutationOperation>.unmodifiable(
      result.rows.map(storedMutationOperationFromDatabase),
    );
  }
}
