import 'package:local_sync_database/local_sync_database.dart';

import '../storage/database_scope.dart';
import 'scopes.dart';

/// Durable desired Downlink state: one base assignment with ordered pending
/// Mutation overlays.
final class ScopeStore {
  const ScopeStore(this.database);

  final LocalDatabaseScope database;

  Future<void> assignDirect(String scope, bool desired) async {
    final normalized = _scope(scope);
    if (!desired) {
      await database.current.execute(
        DatabaseStatement(
          sql: 'UPDATE downlink_scope_state SET desired = 0 WHERE scope = ?',
          variables: [normalized],
        ),
      );
      return;
    }
    final result = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT INTO downlink_scope_state
            (scope, last_applied_sync_id, desired)
          VALUES (?, 0, 1)
          ON CONFLICT(scope) DO UPDATE SET desired = 1
        ''',
        variables: [normalized],
      ),
    );
    _atMostOne(result, 'could not set Downlink scope desire');
  }

  Future<void> assignPending(
    String scope,
    bool desired, {
    required int mutationOrdinal,
  }) async {
    final normalized = _scope(scope);
    if (!desired && !await _hasState(normalized)) return;
    if (desired) {
      final base = await database.current.execute(
        DatabaseStatement(
          sql: '''
            INSERT OR IGNORE INTO downlink_scope_state
              (scope, last_applied_sync_id, desired)
            VALUES (?, 0, 0)
          ''',
          variables: [normalized],
        ),
      );
      _atMostOne(base, 'could not initialize Downlink scope state');
    }

    final position = (await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT COALESCE(MAX(position), -1) + 1 AS position '
            'FROM pending_mutation_scopes WHERE mutation_ordinal = ?',
        variables: [mutationOrdinal],
      ),
    )).singleOrNull?['position'];
    if (position is! int) {
      throw StateError('could not allocate pending scope position');
    }
    final appended = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT INTO pending_mutation_scopes
            (mutation_ordinal, position, scope, desired)
          VALUES (?, ?, ?, ?)
        ''',
        variables: [mutationOrdinal, position, normalized, desired ? 1 : 0],
      ),
    );
    if (appended.affectedRows != 1) {
      throw StateError('could not append pending scope assignment');
    }
    await _sequenceAfterEarlierScope(normalized, mutationOrdinal);
  }

  /// Advances accepted companion assignments into the base. The caller
  /// removes the accepted Mutation records only after this returns.
  Future<void> settleAccepted(Iterable<int> mutationOrdinals) async {
    final ordinals = mutationOrdinals.toSet().toList()..sort();
    if (ordinals.isEmpty) return;
    final rows = await database.current.query(
      DatabaseQuery(
        sql:
            '''
          SELECT mutation_ordinal, position, scope, desired
          FROM pending_mutation_scopes
          WHERE mutation_ordinal IN (${_placeholders(ordinals.length)})
          ORDER BY mutation_ordinal, position
        ''',
        variables: ordinals,
      ),
    );
    for (final row in rows.rows) {
      final result = await database.current.execute(
        DatabaseStatement(
          sql: 'UPDATE downlink_scope_state SET desired = ? WHERE scope = ?',
          variables: [row['desired'], row['scope']],
        ),
      );
      if (result.affectedRows != 1) {
        throw StateError('missing base for accepted scope assignment');
      }
    }
  }

  Future<List<String>> effectiveDesiredScopes() async {
    final result = await database.current.query(_effectiveDesiredQuery);
    return List.unmodifiable([
      for (final row in result.rows) row['scope']! as String,
    ]);
  }

  /// A commit hint for the reconciler. The first emission plus durable reads
  /// are the correctness boundary, so coalesced or missed hints are harmless.
  Stream<void> watchCommittedChanges() =>
      database.database.watch(_effectiveDesiredQuery).map((_) {});

  Future<bool> _hasState(String scope) async => (await database.current.query(
    DatabaseQuery(
      sql: 'SELECT 1 FROM downlink_scope_state WHERE scope = ?',
      variables: [scope],
    ),
  )).rows.isNotEmpty;

  Future<void> _sequenceAfterEarlierScope(
    String scope,
    int mutationOrdinal,
  ) async {
    final predecessor = (await database.current.query(
      DatabaseQuery(
        sql: '''
          SELECT MAX(mutation_ordinal) AS ordinal
          FROM pending_mutation_scopes
          WHERE scope = ? AND mutation_ordinal < ?
        ''',
        variables: [scope, mutationOrdinal],
      ),
    )).singleOrNull?['ordinal'];
    if (predecessor is! int) return;
    final result = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT OR IGNORE INTO pending_mutation_sequences
            (mutation_ordinal, predecessor_ordinal)
          VALUES (?, ?)
        ''',
        variables: [mutationOrdinal, predecessor],
      ),
    );
    _atMostOne(result, 'could not sequence pending scope assignment');
  }
}

final _effectiveDesiredQuery = DatabaseQuery(
  sql: '''
    SELECT state.scope
    FROM downlink_scope_state AS state
    WHERE COALESCE(
      (
        SELECT pending.desired
        FROM pending_mutation_scopes AS pending
        WHERE pending.scope = state.scope
        ORDER BY pending.mutation_ordinal DESC, pending.position DESC
        LIMIT 1
      ),
      state.desired
    ) = 1
    ORDER BY state.scope
  ''',
);

String _scope(String value) => normalizeScopes([value]).single;

String _placeholders(int count) => List.filled(count, '?').join(', ');

void _atMostOne(DatabaseExecutionResult result, String message) {
  if (result.affectedRows < 0 || result.affectedRows > 1) {
    throw StateError(message);
  }
}
