import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/mutation_store.dart';
import '../schema/model_registry.dart';
import '../schema/relation_index.dart';
import '../storage/cascade_expansion.dart';
import '../storage/database_scope.dart';
import '../storage/row_rebuild_dispatch.dart';
import '../uplink/readiness_ledger.dart';
import '../uplink/queued_mutation.dart';
import '../uplink/mutation_queue.dart';
import 'downlink_exception.dart';
import 'downlink_changes.dart';
import 'downlink_change_applier.dart';
import 'downlink_protocol.dart';
import 'model_change_decoder.dart';
import 'scope_row_ledger.dart';
import 'scope_store.dart';

const _maxSafeInteger = 9007199254740991;

final class DownlinkApplyResult {
  DownlinkApplyResult(List<DownlinkChangeException> failures)
    : failures = List.unmodifiable(failures);

  final List<DownlinkChangeException> failures;
}

abstract interface class DownlinkPageHandler {
  Future<DownlinkApplyResult> apply(
    DownlinkPage page, {
    required int afterSyncId,
  });
}

abstract interface class DownlinkStateReader {
  Future<String> readClientId();
  Future<int> readLastAppliedSyncId(String scope);
}

final class DownlinkPageProcessor
    implements DownlinkPageHandler, DownlinkStateReader {
  DownlinkPageProcessor({
    required this.database,
    required this.registry,
    required this.decoder,
    this.onApplied,
  }) : _applier = DownlinkChangeApplier(
         registry: registry,
         claims: ScopeRowLedger(database),
       ),
       _expansion = CascadeExpansion(RelationIndex.of(registry)),
       _ledger = ReadinessLedger(database),
       _scopes = ScopeStore(database);

  final LocalDatabaseScope database;
  final ModelRegistry registry;
  final ModelChangeDecoder decoder;
  final CanonicalDownlinkHook? onApplied;
  final DownlinkChangeApplier _applier;
  final CascadeExpansion _expansion;
  final ReadinessLedger _ledger;
  final ScopeStore _scopes;

  @override
  Future<String> readClientId() async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql: 'SELECT client_id FROM uplink_client_state WHERE singleton = 1',
      ),
    )).singleOrNull;
    if (row == null) throw StateError('missing Uplink client state');
    return row['client_id']! as String;
  }

  @override
  Future<int> readLastAppliedSyncId(String scope) async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT last_applied_sync_id FROM downlink_scope_state '
            'WHERE scope = ?',
        variables: [scope],
      ),
    )).singleOrNull;
    if (row == null) throw StateError('missing Downlink state');
    return row['last_applied_sync_id']! as int;
  }

  @override
  Future<DownlinkApplyResult> apply(
    DownlinkPage page, {
    required int afterSyncId,
  }) async {
    _cursor(afterSyncId, 'afterSyncId');
    _cursor(page.fromSyncId, 'fromSyncId');
    _cursor(page.throughSyncId, 'throughSyncId');
    if (page.fromSyncId != afterSyncId) {
      throw const DownlinkPageException(
        'page fromSyncId must match afterSyncId',
      );
    }
    if (page.throughSyncId < afterSyncId) {
      throw const DownlinkPageException(
        'throughSyncId must not precede afterSyncId',
      );
    }

    var expectedCursor = afterSyncId;
    final failures = <DownlinkChangeException>[];
    for (final addressed in page.changes) {
      late final DecodedModelChange change;
      try {
        change = decoder.decode(addressed);
      } catch (error, stackTrace) {
        await _commitSkip(page.scope, expectedCursor, addressed.syncId);
        failures.add(_exception(addressed, error, stackTrace));
        expectedCursor = addressed.syncId;
        continue;
      }
      try {
        await database.transaction((_) async {
          await _requireCursor(page.scope, expectedCursor);
          late final List<CanonicalDownlinkChange> changes;
          try {
            changes = await _applier.apply(page.scope, change);
          } catch (error, stackTrace) {
            throw _CanonicalChangeFailure(error, stackTrace);
          }
          await onApplied?.call(changes);
          await _settleAndAdvance(page.scope, change.syncId);
        });
      } on _CanonicalChangeFailure catch (failure) {
        await _commitSkip(page.scope, expectedCursor, addressed.syncId);
        failures.add(_exception(addressed, failure.cause, failure.stackTrace));
      }
      expectedCursor = addressed.syncId;
    }

    if (expectedCursor < page.throughSyncId || page.changes.isEmpty) {
      await database.transaction((_) async {
        await _requireCursor(page.scope, expectedCursor);
        if (expectedCursor < page.throughSyncId) {
          await _settleAndAdvance(page.scope, page.throughSyncId);
        }
      });
    }
    return DownlinkApplyResult(failures);
  }

  Future<void> _commitSkip(String scope, int expectedCursor, int syncId) =>
      database.transaction((_) async {
        await _requireCursor(scope, expectedCursor);
        await _settleAndAdvance(scope, syncId);
      });

  Future<void> _requireCursor(String scope, int expected) async {
    final stored = await readLastAppliedSyncId(scope);
    if (stored != expected) {
      throw DownlinkPageException(
        'stale Downlink cursor: expected $expected, found $stored',
      );
    }
  }

  /// Receipt arrival can follow the canonical page, including after a crash.
  /// Settle from durable cursors without requiring another Downlink page.
  Future<void> settleAccepted() => database.transaction((_) async {
    await _settleBatches(await _readBatchesReadyAfterAdvance(null, null));
  });

  Future<void> _settleBatches(List<UplinkBatchRow> batches) async {
    for (final batch in batches) {
      final mutations = await _readBatchMutations(batch.sequence);
      if (mutations.isNotEmpty) {
        // Companion rows first, while their settled operations are still in
        // the queue: acceptance is what advances a companion row's truth — no
        // downlink change will ever name it — and the advance needs to read
        // exactly the operations the DELETE below removes.
        //
        // A row this batch also settles a WIRE operation for is not one of
        // them: the server accepted that operation and will speak the row's
        // new state itself, so advancing from local optimism here would record
        // a guess as truth (CAP-488).
        final settledOrdinals = {
          for (final row in mutations) row.mutationOrdinal,
        };
        final wireRows = {
          for (final row in mutations)
            if (row.isUplink) '${row.model} ${row.identityJson}',
        };
        final companionRows = [
          for (final row in mutations)
            if (!wireRows.contains('${row.model} ${row.identityJson}')) row,
        ];
        await visitQueuedRows(
          registry,
          companionRows,
          (entry, id) => entry.advanceTruth(id, settledOrdinals),
        );
        final parentOrdinals = {
          for (final row in mutations) row.mutationOrdinal,
        };
        await _scopes.settleAccepted(parentOrdinals);
        final deleted = await database.current.execute(
          DatabaseStatement(
            sql:
                'DELETE FROM pending_mutations WHERE ordinal IN '
                '(${List.filled(parentOrdinals.length, '?').join(', ')})',
            variables: parentOrdinals,
          ),
        );
        if (deleted.affectedRows != parentOrdinals.length) {
          throw StateError('missing Uplink mutation');
        }
        // The keys these mutations were waiting on may have nothing left
        // referencing them. Fully synced work has no readiness obligations,
        // so a ledger row surviving with no referent would be a lie
        // about outstanding work — but a key another queued act still
        // carries stays, reference-aware (CAP-521).
        await _ledger.pruneUnreferenced(
          prerequisiteInvocationsOf(registry, mutations),
          await queuedPrerequisiteInvocations(database, registry),
        );
        // An accepted delete was one action over many rows, and only the row
        // the user named was ever in the queue. The rest are already absent
        // from main and truth is absent now too, so the twin must stop holding
        // them — otherwise a fully synchronized client would still be full of
        // before-images (CAP-396 spec §8).
        //
        // These go first, because a row can be both: one that fell with the
        // delete AND one whose own edit this batch settles. Dropping the truth
        // it was holding is exactly what stops that edit from rebuilding the
        // row the delete took.
        await visitFallenRows(
          registry,
          _expansion,
          mutations,
          (entry, id) => entry.settleByCascade(id),
        );
        // These edits are the server's own now. Settling drops the truth held
        // for any row whose queue this emptied, so a fully settled client
        // holds no before-images at all — and it never touches a row that
        // held none, whose main row is already the server's.
        //
        // A companion-only row was already settled by [advanceTruth] above,
        // which owns the sparsity rule for it (a fully-settled row's twin is
        // dropped there, an advanced one keeps its advanced truth). Rebuilding
        // it here would restore the pre-act value, undoing the edit the
        // acceptance just made final.
        await visitQueuedRows(
          registry,
          mutations.where(
            (row) => wireRows.contains('${row.model} ${row.identityJson}'),
          ),
          (entry, id) => entry.settle(id),
        );
      }
      final deletedBatch = await database.current.execute(
        DatabaseStatement(
          sql: 'DELETE FROM uplink_batches WHERE sequence = ?',
          variables: [batch.sequence],
        ),
      );
      if (deletedBatch.affectedRows != 1) {
        throw StateError('missing Uplink batch');
      }
    }
  }

  Future<void> _settleAndAdvance(String scope, int syncId) async {
    final batches = await _readBatchesReadyAfterAdvance(scope, syncId);
    await _settleBatches(batches);
    final cursor = await database.current.execute(
      DatabaseStatement(
        sql:
            'UPDATE downlink_scope_state SET last_applied_sync_id = ? '
            'WHERE scope = ?',
        variables: [syncId, scope],
      ),
    );
    if (cursor.affectedRows != 1) throw StateError('missing Downlink state');
  }

  Future<List<UplinkBatchRow>> _readBatchesReadyAfterAdvance(
    String? scope,
    int? syncId,
  ) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql: '''
            SELECT batch.sequence,
              CASE
                WHEN EXISTS (
                  SELECT 1 FROM uplink_batch_checkpoints AS present
                  WHERE present.batch_sequence = batch.sequence
                )
                 AND NOT EXISTS (
                  SELECT 1
                  FROM uplink_batch_checkpoints AS checkpoint
                  LEFT JOIN downlink_scope_state AS state
                    ON state.scope = checkpoint.scope
                  WHERE checkpoint.batch_sequence = batch.sequence
                    AND checkpoint.required_sync_id >
                      CASE
                        WHEN checkpoint.scope = ? THEN ?
                        ELSE COALESCE(state.last_applied_sync_id, -1)
                      END
                ) THEN 1
                ELSE 0
              END AS ready
            FROM uplink_batches AS batch
            WHERE batch.required_sync_id IS NOT NULL
            ORDER BY batch.sequence
          ''',
        variables: [scope, syncId],
      ),
    );
    final prefix = <UplinkBatchRow>[];
    for (final row in result.rows) {
      if (row['ready'] != 1) break;
      prefix.add(UplinkBatchRow(sequence: row['sequence']! as int));
    }
    return List.unmodifiable(prefix);
  }

  Future<List<StoredMutationOperation>> _readBatchMutations(
    int sequence,
  ) async {
    final result = await database.current.query(
      DatabaseQuery(
        sql: '''
          SELECT parent.name AS mutation_name, parent.version AS mutation_version,
                 operation.mutation_ordinal, operation.position,
                 operation.slot_name,
                 operation.model, operation.identity_json,
                 operation.operation, operation.values_json,
                 operation.is_uplink
          FROM pending_mutation_operations AS operation
          JOIN pending_mutations AS parent
            ON parent.ordinal = operation.mutation_ordinal
          WHERE parent.batch_sequence = ?
          ORDER BY operation.mutation_ordinal, operation.position
        ''',
        variables: [sequence],
      ),
    );
    return List<StoredMutationOperation>.unmodifiable(
      result.rows.map(storedMutationOperationFromDatabase),
    );
  }
}

final class _CanonicalChangeFailure implements Exception {
  const _CanonicalChangeFailure(this.cause, this.stackTrace);

  final Object cause;
  final StackTrace stackTrace;
}

DownlinkChangeException _exception(
  AddressedModelChange change,
  Object cause,
  StackTrace stackTrace,
) => DownlinkChangeException(
  syncId: change.syncId,
  model: _readableString(change.raw['model']),
  operation: _readableString(change.raw['operation']),
  cause: cause,
  stackTrace: stackTrace,
);

String? _readableString(Object? value) => value is String ? value : null;

void _cursor(int value, String name) {
  if (value < 0 || value > _maxSafeInteger) {
    throw DownlinkPageException('$name must be a non-negative safe integer');
  }
}
