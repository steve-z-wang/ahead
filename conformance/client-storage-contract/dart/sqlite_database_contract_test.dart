import 'dart:io';

import 'package:local_sync_database/local_sync_database.dart';
import 'package:local_sync_database_sqlite/local_sync_database_sqlite.dart';

import 'database_contract.dart';

void main() {
  databaseContract(adapterName: 'SQLite', open: _open);
}

Future<Database> _open(Directory directory) => SqliteDatabaseDriver.file(
  path: '${directory.path}/fixture.sqlite',
  migrations: [
    SqliteDatabaseMigration(
      version: 1,
      statements: [
        DatabaseStatement(
          sql: '''
            CREATE TABLE fixture_items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE
            )
          ''',
        ),
        DatabaseStatement(
          sql: '''
            CREATE TABLE fixture_others (
              id INTEGER PRIMARY KEY AUTOINCREMENT
            )
          ''',
        ),
        DatabaseStatement(
          sql: 'CREATE TABLE fixture_parents (id INTEGER PRIMARY KEY)',
        ),
        DatabaseStatement(
          sql: '''
            CREATE TABLE fixture_children (
              id INTEGER PRIMARY KEY,
              parent_id INTEGER NOT NULL REFERENCES fixture_parents(id)
                ON DELETE CASCADE
            )
          ''',
        ),
      ],
    ),
  ],
).open();
