import 'package:local_sync_database/local_sync_database.dart';

final localSyncInfrastructureStatements = <DatabaseStatement>[
  DatabaseStatement(
    sql: '''
      CREATE TABLE mutation_rejections (
        id TEXT PRIMARY KEY NOT NULL,
        mutation_ordinal INTEGER NOT NULL UNIQUE,
        name TEXT NOT NULL,
        version INTEGER CHECK (version IS NULL OR (version >= 1 AND version <= 9007199254740991)),
        code TEXT NOT NULL,
        operations_json TEXT NOT NULL,
        scopes_json TEXT NOT NULL
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE uplink_client_state (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        client_id TEXT NOT NULL,
        last_assigned_batch_sequence INTEGER NOT NULL
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE uplink_batches (
        sequence INTEGER PRIMARY KEY,
        required_scope TEXT,
        required_sync_id INTEGER,
        legacy_required_sync_id INTEGER,
        CHECK (
          (required_scope IS NULL
           AND required_sync_id IS NULL AND legacy_required_sync_id IS NULL)
          OR
          (required_scope IS NOT NULL
           AND required_sync_id IS NOT NULL AND legacy_required_sync_id IS NULL)
          OR
          (required_scope IS NULL
           AND required_sync_id IS NULL AND legacy_required_sync_id IS NOT NULL)
        )
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE uplink_batch_checkpoints (
        batch_sequence INTEGER NOT NULL
          REFERENCES uplink_batches(sequence) ON DELETE CASCADE,
        scope TEXT NOT NULL,
        required_sync_id INTEGER NOT NULL,
        PRIMARY KEY (batch_sequence, scope)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX uplink_batch_checkpoints_settlement
      ON uplink_batch_checkpoints(
        scope, required_sync_id, batch_sequence
      )
    ''',
  ),
  // One named act, one record (CAP-439). The record is the unit of local
  // atomicity, readiness, batch membership, server savepoint, rejection and
  // settlement; the operations beneath it are the letters it is spelled with.
  DatabaseStatement(
    sql: '''
      CREATE TABLE pending_mutations (
        ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        version INTEGER CHECK (version IS NULL OR (version >= 1 AND version <= 9007199254740991)),
        batch_sequence INTEGER REFERENCES uplink_batches(sequence),
        legacy_wire_ordinal INTEGER,
        legacy_fifo INTEGER NOT NULL DEFAULT 0
          CHECK (legacy_fifo IN (0, 1))
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE pending_mutation_operations (
        mutation_ordinal INTEGER NOT NULL
          REFERENCES pending_mutations(ordinal) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        slot_name TEXT,
        model TEXT NOT NULL,
        identity_json TEXT NOT NULL,
        operation TEXT NOT NULL
          CHECK (operation IN ('create', 'update', 'delete')),
        values_json TEXT NOT NULL,
        is_uplink INTEGER NOT NULL CHECK (is_uplink IN (0, 1)),
        PRIMARY KEY (mutation_ordinal, position)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE pending_mutation_scopes (
        mutation_ordinal INTEGER NOT NULL
          REFERENCES pending_mutations(ordinal) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        scope TEXT NOT NULL,
        desired INTEGER NOT NULL CHECK (desired IN (0, 1)),
        PRIMARY KEY (mutation_ordinal, position)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX pending_mutation_scopes_by_scope
      ON pending_mutation_scopes(scope, mutation_ordinal, position)
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE pending_mutation_sequences (
        mutation_ordinal INTEGER NOT NULL
          REFERENCES pending_mutations(ordinal) ON DELETE CASCADE,
        predecessor_ordinal INTEGER NOT NULL
          REFERENCES pending_mutations(ordinal) ON DELETE CASCADE,
        PRIMARY KEY (mutation_ordinal, predecessor_ordinal),
        CHECK (predecessor_ordinal < mutation_ordinal)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX pending_mutation_sequences_reverse
      ON pending_mutation_sequences(
        predecessor_ordinal, mutation_ordinal
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE pending_mutation_prerequisites (
        mutation_ordinal INTEGER NOT NULL
          REFERENCES pending_mutations(ordinal) ON DELETE CASCADE,
        prerequisite_ordinal INTEGER NOT NULL
          REFERENCES pending_mutations(ordinal) ON DELETE CASCADE,
        PRIMARY KEY (mutation_ordinal, prerequisite_ordinal),
        CHECK (prerequisite_ordinal < mutation_ordinal)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX pending_mutation_prerequisites_reverse
      ON pending_mutation_prerequisites(
        prerequisite_ordinal, mutation_ordinal
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX pending_mutations_batch
      ON pending_mutations(batch_sequence, ordinal)
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX pending_mutation_operations_identity
      ON pending_mutation_operations(
        model, identity_json, mutation_ordinal, position
      )
    ''',
  ),
  // The readiness ledger (CAP-385 spec §3). Absence is pending, so there is no
  // third state to store and no row for work nobody has concluded anything
  // about; the table is empty whenever every queued mutation has settled.
  DatabaseStatement(
    sql: '''
      CREATE TABLE readiness_states (
        key TEXT PRIMARY KEY,
        state TEXT NOT NULL CHECK (state IN ('ready', 'failed'))
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE downlink_scope_state (
        scope TEXT NOT NULL,
        last_applied_sync_id INTEGER NOT NULL,
        desired INTEGER NOT NULL DEFAULT 0 CHECK (desired IN (0, 1)),
        PRIMARY KEY (scope)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE TABLE downlink_scope_rows (
        scope TEXT NOT NULL,
        model TEXT NOT NULL,
        identity_json TEXT NOT NULL,
        PRIMARY KEY (scope, model, identity_json)
      )
    ''',
  ),
  DatabaseStatement(
    sql: '''
      CREATE INDEX downlink_scope_rows_identity
      ON downlink_scope_rows(model, identity_json)
    ''',
  ),
];
