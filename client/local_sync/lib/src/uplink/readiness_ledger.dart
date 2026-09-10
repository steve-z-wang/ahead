import 'package:local_sync_database/local_sync_database.dart';

import '../storage/database_scope.dart';
import '../storage/local_value_codec.dart';
import 'prerequisite.dart';

/// What the ledger says about one concrete prerequisite invocation.
///
/// [pending] is never stored — it is the absence of a row. The Engine derives
/// pending work from its durable Mutation queue and writes only terminal
/// handler results here.
enum ReadinessState { pending, ready, failed }

/// Engine-private sparse terminal-result ledger.
///
/// Invocation identities include the prerequisite name and typed arguments,
/// so two prerequisite kinds using the same scalar value never collide.
final class ReadinessLedger {
  const ReadinessLedger(this.database);

  final LocalDatabaseScope database;

  Future<void> markReady(PrerequisiteInvocation invocation) =>
      _mark(invocation.identity, ReadinessState.ready);

  Future<void> markFailed(PrerequisiteInvocation invocation) =>
      _mark(invocation.identity, ReadinessState.failed);

  Future<ReadinessState> read(PrerequisiteInvocation invocation) =>
      _readIdentity(invocation.identity);

  Future<void> prune(Iterable<PrerequisiteInvocation> invocations) =>
      _pruneIdentities(invocations.map((invocation) => invocation.identity));

  Future<void> pruneUnreferenced(
    Iterable<PrerequisiteInvocation> candidates,
    Iterable<PrerequisiteInvocation> remaining,
  ) => _pruneUnreferencedIdentities(
    candidates.map((invocation) => invocation.identity),
    remaining.map((invocation) => invocation.identity),
  );

  /// Clears only failed terminal results, preserving ready and absent inputs.
  Future<void> retryFailed(Iterable<PrerequisiteInvocation> invocations) async {
    final keys = invocations.map((invocation) => invocation.identity).toSet();
    if (keys.isEmpty) return;
    await database.current.execute(
      DatabaseStatement(
        sql:
            "DELETE FROM readiness_states WHERE state = 'failed' "
            "AND key IN (${List.filled(keys.length, '?').join(', ')})",
        variables: keys.toList(),
      ),
    );
  }

  Future<ReadinessState> _readIdentity(String identity) async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql: 'SELECT state FROM readiness_states WHERE key = ?',
        variables: [identity],
      ),
    )).singleOrNull;
    if (row == null) return ReadinessState.pending;
    final state = row['state']! as String;
    return ReadinessState.values.firstWhere(
      (candidate) =>
          candidate.name == state && candidate != ReadinessState.pending,
      orElse: () =>
          throw LocalDataException('unknown readiness state "$state"'),
    );
  }

  /// Forgets the candidate identities that no surviving queued operation
  /// references (CAP-521).
  ///
  /// Readiness belongs to a KEY, not a mutation: two acts may wait on the
  /// same key, and removing one of them must not take the mark the other is
  /// still gated on. Every pruning call site derives [remainingKeys] from
  /// the operations that survive its own delete, inside the same database
  /// transaction, and prunes only the difference.
  Future<void> _pruneUnreferencedIdentities(
    Iterable<String> candidateKeys,
    Iterable<String> remainingKeys,
  ) async {
    final remaining = remainingKeys.toSet();
    await _pruneIdentities(
      candidateKeys.where((key) => !remaining.contains(key)),
    );
  }

  /// Forgets keys nothing references any more.
  ///
  /// Same sparsity discipline as the before-images: fully synced means every
  /// auxiliary table is empty, so a row left behind here would be a lie about
  /// work still outstanding.
  Future<void> _pruneIdentities(Iterable<String> keys) async {
    final unique = keys.toSet().toList();
    if (unique.isEmpty) return;
    await database.current.execute(
      DatabaseStatement(
        sql:
            'DELETE FROM readiness_states '
            'WHERE key IN (${List.filled(unique.length, '?').join(', ')})',
        variables: unique,
      ),
    );
  }

  Future<void> _mark(String key, ReadinessState state) async {
    await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT INTO readiness_states (key, state) VALUES (?, ?)
          ON CONFLICT (key) DO UPDATE SET state = excluded.state
        ''',
        variables: [key, state.name],
      ),
    );
  }
}
