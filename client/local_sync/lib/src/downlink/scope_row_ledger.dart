import 'package:local_sync_database/local_sync_database.dart';

import '../schema/model_id.dart';
import '../schema/model_registry.dart';
import '../storage/database_scope.dart';
import '../storage/local_value_codec.dart';

/// The durable set of Downlink scopes that currently hold each Model row.
final class ScopeRowLedger {
  const ScopeRowLedger(this.database, {this.codec = const LocalValueCodec()});

  final LocalDatabaseScope database;
  final LocalValueCodec codec;

  Future<void> claim(String scope, ModelRegistryEntry entry, ModelId id) async {
    final inserted = await database.current.execute(
      DatabaseStatement(
        sql: '''
          INSERT OR IGNORE INTO downlink_scope_rows
            (scope, model, identity_json)
          VALUES (?, ?, ?)
        ''',
        variables: [scope, entry.schema.name, _identity(entry, id)],
      ),
    );
    if (inserted.affectedRows > 1) {
      throw StateError('invalid Downlink scope claim insert');
    }
  }

  Future<void> release(
    String scope,
    ModelRegistryEntry entry,
    ModelId id,
  ) async {
    final deleted = await database.current.execute(
      DatabaseStatement(
        sql: '''
          DELETE FROM downlink_scope_rows
          WHERE scope = ? AND model = ? AND identity_json = ?
        ''',
        variables: [scope, entry.schema.name, _identity(entry, id)],
      ),
    );
    if (deleted.affectedRows > 1) {
      throw StateError('invalid Downlink scope claim delete');
    }
  }

  Future<bool> hasClaims(ModelRegistryEntry entry, ModelId id) async {
    final row = (await database.current.query(
      DatabaseQuery(
        sql: '''
          SELECT 1
          FROM downlink_scope_rows
          WHERE model = ? AND identity_json = ?
          LIMIT 1
        ''',
        variables: [entry.schema.name, _identity(entry, id)],
      ),
    )).singleOrNull;
    return row != null;
  }

  Future<void> releaseAll(ModelRegistryEntry entry, ModelId id) async {
    await database.current.execute(
      DatabaseStatement(
        sql: '''
          DELETE FROM downlink_scope_rows
          WHERE model = ? AND identity_json = ?
        ''',
        variables: [entry.schema.name, _identity(entry, id)],
      ),
    );
  }

  String _identity(ModelRegistryEntry entry, ModelId id) =>
      codec.encodeIdentity(entry.schema, id);
}
