import 'package:local_sync_database/local_sync_database.dart';
import 'package:local_sync_database_sqlite/local_sync_database_sqlite.dart';

import '../generated/local_sync.dart';

/// The fixture's whole schema at version 1. The framework proves the
/// protocol, not a product ladder (CAP-387) — a fresh conformance database
/// is always built directly at the current schema.
DatabaseDriver localSyncDatabaseDriver({required String path}) =>
    SqliteDatabaseDriver.file(
      path: path,
      migrations: [
        SqliteDatabaseMigration(
          version: 1,
          statements: localSyncCurrentSchemaStatements,
        ),
      ],
    );
