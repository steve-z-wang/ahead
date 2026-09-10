import 'dart:io';

import 'package:local_sync_database/local_sync_database.dart';
import 'package:sqlite_async/native.dart' as sqlite_native;
import 'package:sqlite_async/sqlite_async.dart' as sqlite;

import 'sqlite_database.dart';

final class SqliteDatabaseMigration {
  SqliteDatabaseMigration({
    required this.version,
    required Iterable<DatabaseStatement> statements,
    this.replayDownlink = false,
  }) : statements = List<DatabaseStatement>.unmodifiable(statements) {
    if (version < 1) {
      throw ArgumentError.value(version, 'version', 'must be positive');
    }
  }

  final int version;
  final List<DatabaseStatement> statements;

  /// Rewinds the durable Downlink cursor to zero in this migration's own
  /// transaction (CAP-482), so the next pull replays server truth into the
  /// shape this migration just created. It deletes nothing: cached rows,
  /// device-only rows and the whole Uplink queue survive.
  final bool replayDownlink;
}

final class SqliteDatabaseDriver implements DatabaseDriver {
  SqliteDatabaseDriver.file({
    required String path,
    Iterable<SqliteDatabaseMigration> migrations = const [],
  }) : _path = path,
       migrations = List<SqliteDatabaseMigration>.unmodifiable(migrations);

  final String _path;
  final List<SqliteDatabaseMigration> migrations;

  @override
  Future<Database> open() async {
    await File(_path).parent.create(recursive: true);
    final connection = sqlite.SqliteDatabase.withFactory(
      _LocalSyncSqliteOpenFactory(path: _path),
    );
    final database = SqliteLocalSyncDatabase(connection);
    try {
      await connection.initialize();
      if (migrations.isNotEmpty) {
        var schemaChanged = false;
        final migrationPlan = sqlite.SqliteMigrations();
        for (final migration in migrations) {
          migrationPlan.add(
            sqlite.SqliteMigration(migration.version, (context) async {
              for (final statement in migration.statements) {
                await context.execute(statement.sql, statement.variables);
              }
              if (migration.replayDownlink) {
                final cursorTables = await context.getAll(
                  "SELECT name FROM sqlite_master WHERE type = 'table' "
                  "AND name IN ('downlink_state', 'downlink_scope_state')",
                );
                if (cursorTables.isEmpty) {
                  throw StateError(
                    'replayDownlink requires a Downlink cursor table',
                  );
                }
                for (final table in cursorTables) {
                  final name = table['name']! as String;
                  await context.execute(
                    'UPDATE $name SET last_applied_sync_id = 0',
                    const [],
                  );
                }
              }
              schemaChanged = true;
            }),
          );
        }
        await migrationPlan.migrate(connection);
        if (schemaChanged) await connection.refreshSchema();
      }
      return database;
    } catch (_) {
      await database.close();
      rethrow;
    }
  }
}

final class _LocalSyncSqliteOpenFactory
    extends sqlite_native.NativeSqliteOpenFactory {
  _LocalSyncSqliteOpenFactory({required super.path});

  @override
  List<String> pragmaStatements(sqlite.SqliteOpenOptions options) => [
    ...super.pragmaStatements(options),
    // No generated Model table declares a foreign key any more (CAP-407): the
    // replica tolerates arrival order. This stays on because the framework's
    // OWN infrastructure is not a replica — `uplink_mutations.batch_sequence`
    // references `uplink_batches`, and that one is real.
    'PRAGMA foreign_keys = ON',
    // The read pool is where the read-only SQL seam runs (CAP-393 spec §8).
    // Making those connections refuse writes at the SQLite level means the
    // seam cannot write even if some future caller finds a way to hand it a
    // statement that tries.
    if (!options.primaryConnection) 'PRAGMA query_only = ON',
  ];
}
