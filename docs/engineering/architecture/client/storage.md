# Storage

Execute Engine-requested SQL and transactions; no sync policy.

Current code: the contract in [client/store.rs](../../../../crates/client/src/store.rs) (`ClientStore`, `SqlRows`); table layout and reconciliation in [client/ddl.rs](../../../../crates/client/src/ddl.rs); the SQLite implementation in [sqlite/lib.rs](../../../../crates/sqlite/src/lib.rs) (`SqliteStore`).

## 1. Introduction and Goals

- Give the engine a SQL executor with transactions and savepoints whose tables are the schema record, and make an existing database open safely against a newer compiled schema or refuse without damage.

## 3. Context and Scope

- Contract: `begin`/`commit`/`rollback`, `savepoint`/`release`/`rollback_to(name)`, `execute(sql, params) -> rows affected`, `execute_batch`, `query(sql, params)` (inside the writer's view), `query_committed(sql, params)` (last commit only).
- Callers: the engine only ([Engine](engine/README.md)); the engine owns every statement.
- Framework tables (`FRAMEWORK_TABLES`): `ahead_client`, `ahead_record`, `ahead_claim`, `ahead_subscription`, `ahead_mutation`, `ahead_mutation_operation`, `ahead_mutation_dependency`, `ahead_mutation_prerequisite`, `ahead_push_checkpoint`, `ahead_rejection`.

## 5. Building Block View

- `SqliteStore::open(path)`: a writer connection (`journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=1000`) and a reader connection (`query_only=ON`); `begin` is `BEGIN IMMEDIATE`; savepoint names are validated to `[A-Za-z0-9_]+`; `rollback_to` also releases.
- Value mapping: booleans as integers, arrays and objects as JSON text, numbers as integer or real; blobs and non-UTF-8 text are refused on the way out; `query`/`query_committed` refuse statements that are not read-only or return no columns.
- Model tables (`model_ddl`): `CREATE TABLE "<Model>"` with `PRIMARY KEY (identity…)` and `NOT NULL` for non-nullable columns, a twin `ahead_before_<Model>` with the same columns, and one `CREATE UNIQUE INDEX IF NOT EXISTS "<Model>_<fields>_unique"` per `@@unique`. Column types follow [Types](../schema/types.md).
- Reconciliation (`reconcile`, run inside the opening transaction): missing table → create; identity columns differ → refuse; column type differs → refuse; column missing → `ALTER TABLE ADD COLUMN` on both tables, with `DEFAULT <literal>` required for non-nullable columns; extra columns are left in place; unique indexes are re-issued with `IF NOT EXISTS`. A refused reconciliation rolls back and leaves the file untouched.
- Framework DDL runs with `CREATE … IF NOT EXISTS` before the transaction; `ON DELETE CASCADE` links operation, dependency and prerequisite rows to their mutation.

## 10. Quality Requirements

- Store contract: [sqlite/tests/store.rs](../../../../crates/sqlite/tests/store.rs) (reader isolation, nested savepoints, read-only enforcement, busy timeout expiring into an error).
- C3, L2, R3: [sqlite/tests/ddl.rs](../../../../crates/sqlite/tests/ddl.rs) `creates_model_before_and_framework_tables`, `adds_missing_columns_to_both_tables_and_keeps_unknown_ones`, `rejects_non_nullable_column_without_default_identity_change_and_type_change`; reopen tests in [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) and [sqlite/tests/stamp_scenarios.rs](../../../../crates/sqlite/tests/stamp_scenarios.rs).

## 11. Risks and Technical Debt

- **Confirmed gap: the migration contract stops at add-only.** Identity, type, removal, rename and enum-value changes are refused with no path other than a new database file (guarantee N3); a non-nullable addition needs a default the grammar cannot express ([Models](../schema/models.md)); a `@@unique` whose columns changed leaves the old index constraining rows; enum value sets are unchecked; queued unsent creates do not receive new columns' defaults. Evidence: [client/ddl.rs](../../../../crates/client/src/ddl.rs) `reconcile`. Open: [#20](https://github.com/zanminwang/ahead/issues/20), [#27](https://github.com/zanminwang/ahead/issues/27).
- **Confirmed limitation: reconciliation is untested with a non-empty queue.** C3's "queued operation bytes are never rewritten" is argued from the row layout, not asserted (guarantee C3 note).
- **Potential risk: a second writer fails after one second.** `BEGIN IMMEDIATE` waits `busy_timeout=1000` and then errors; two handles on one file (two processes, or a stale handle) see `sqlite: database is locked` rather than waiting. Evidence: [sqlite/lib.rs](../../../../crates/sqlite/src/lib.rs); [sqlite/tests/store.rs](../../../../crates/sqlite/tests/store.rs) `second_writer_waits_then_fails_on_conflicting_immediate_transaction`. The generation fence ([Frontend interface](frontend-interface.md)) covers correctness, not availability.
