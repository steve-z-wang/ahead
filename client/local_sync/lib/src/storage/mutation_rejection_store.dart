import 'dart:convert';

import 'package:local_sync_database/local_sync_database.dart';

import '../mutation/mutation_store.dart';
import 'database_scope.dart';

/// Captures explicit server refusals before their queue records disappear.
/// The caller owns the response/rollback transaction.
final class MutationRejectionStore {
  const MutationRejectionStore(this.database);

  final LocalDatabaseScope database;

  Future<void> retain({
    required String clientId,
    required StoredMutation mutation,
    required String code,
    required List<StoredMutationOperation> operations,
  }) async {
    if (database.current is! DatabaseTransaction) {
      throw StateError(
        'retaining a rejection requires the rollback transaction',
      );
    }
    final scopes = await database.current.query(
      DatabaseQuery(
        sql:
            'SELECT position, scope, desired FROM pending_mutation_scopes '
            'WHERE mutation_ordinal = ? ORDER BY position',
        variables: [mutation.ordinal],
      ),
    );
    await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT INTO mutation_rejections
            (id, mutation_ordinal, name, version, code, operations_json, scopes_json)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        variables: [
          '$clientId:${mutation.ordinal}',
          mutation.ordinal,
          mutation.name,
          mutation.version,
          code,
          jsonEncode([
            for (final operation in operations)
              {
                'position': operation.position,
                'slot': operation.slotName,
                'model': operation.model,
                'identity': jsonDecode(operation.identityJson),
                'operation': operation.operation,
                'values': jsonDecode(operation.valuesJson),
                'wire': operation.isUplink,
              },
          ]),
          jsonEncode([
            for (final row in scopes.rows)
              {
                'position': row['position'],
                'scope': row['scope'],
                'desired': row['desired'] == 1,
              },
          ]),
        ],
      ),
    );
  }
}
