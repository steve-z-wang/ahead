# Frontend interface

Expose reads, writes, subscriptions and status to SDKs.

Current code: [client/lib.rs](../../../../crates/client/src/lib.rs) (`Client`, `ClientTransaction`, `Mutation`, `Operation`, `Readiness`, `ApplyReport`); the per-transaction handle in [client/engine.rs](../../../../crates/client/src/engine.rs).

## 1. Introduction and Goals

- One Rust surface over which every language binding drives the engine: open, transact, read, queue, sync, observe. No state lives in memory between calls except the open store, the schema, the client id and the generation.

## 3. Context and Scope

- Callers: [SDKs / Bindings](../sdks/bindings.md) (`RuntimeHost`), the simulation crate, the sqlite tests.
- Dependencies: a `ClientStore` ([Storage](storage.md)), a validated `Schema` ([Compiler / Generate](../compiler/generate.md) `schema.json`), the engine modules ([Engine](engine/README.md)), the connection state machines ([Connection](connection/README.md)).

## 5. Building Block View

- Lifecycle: `Client::open(store, schema)` validates the schema, runs the framework DDL, then in one transaction reconciles model tables, creates or reads the `ahead_client` row (`client_id`, `next_ordinal`, `next_push`, `generation`) and settles any push whose checkpoints are already met.
- Writes: `transaction(|tx| …)` opens one store transaction, runs the closure, bumps the generation (`fence`) and commits; any error rolls back. `ClientTransaction` offers `read`, `query`, `query_spec`, `related`, `referencing`, `enqueue` (named mutation, in its own savepoint), `direct` (local write, in its own savepoint), `set_channel` and nested `savepoint`.
- Session API for hosts that hold a transaction open across calls: `begin_session`, `session(|tx| …)`, `session_savepoint`, `session_release`, `session_rollback_savepoint`, `commit_session` (refuses unclosed savepoints), `rollback_session`; while a session is open, `write` refuses (`client transaction active`).
- Reads outside a transaction use the committed reader: `read`, `query` (equality filter), `query_spec` (filter, order, limit), `related`, `referencing`, `read_sql` (read-only SQL against committed data); `session_sql` reads inside the session.
- Sync surface: `freeze`/`freeze_with_limit`, `acknowledge`, `apply_page`, `receive_downlink`, `downlink_request`, `SyncCycle`, `ConnectionDriver` ([Engine / Push](engine/push/README.md), [Engine / Pull](engine/pull.md), [Connection / Controller](connection/controller.md)).
- State and control: `pending_count`, `before_image_count`, `cursor`, `subscriptions`, `desired_channels`, `checkpoint_channels`, `claims_of`, `rejections`, `record_status` (per-record pending phases `queued`/`frozen`/`accepted` and matching rejections), `pending_tasks`, `set_readiness`, `drop_mutation` (unsent only), `dismiss_rejection`.
- Notifications: `watch(tables)` returns an `mpsc::Receiver<()>` signalled when a commit touched one of the named tables; `last_changed()` exposes the last commit's table set.
- Generation fence: every commit runs `UPDATE ahead_client SET generation = generation + 1 WHERE generation = ?`; a handle whose generation is stale fails with `stale client writer; reopen runtime` (guarantee R4). Opening does not bump the generation, so two fresh handles are both valid until one writes.

## 6. Runtime View

- A failed `COMMIT` is followed by `ROLLBACK` so the store never stays in an open transaction; the commit error is what the caller sees.
- `drop_mutation` refuses a mutation that has been frozen (`push` set), because its outcome is unknown or accepted; it otherwise behaves like a local rejection with code `dropped`.

## 10. Quality Requirements

- L1–L3, R4: [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) `open_creates_tables_persists_identity_and_survives_reopen`, `session_reads_own_writes_without_notifying_until_commit_and_blocks_other_writes`, `local_transaction_and_mutation_savepoint_have_independent_fate`, `stale_writer_cannot_overwrite_committed_database`, `watch_fires_only_for_declared_tables`.
- Binding contract over this surface: [bindings/common/tests/session.rs](../../../../bindings/common/tests/session.rs); [transaction.test.mjs](../../../../integration/bindings/client-js/transaction.test.mjs).

## 11. Risks and Technical Debt

- **Confirmed limitation: `watch` granularity is not surfaced.** The interface reports touched tables, but no SDK consumes them ([SDKs / Typed API](../sdks/typed-api.md), [#16](https://github.com/zanminwang/ahead/issues/16)).
- **Confirmed limitation: a sent mutation cannot be dropped.** `drop_mutation` refuses any mutation with a push number, so a batch the server keeps failing has no local escape hatch ([Engine / Push](engine/push/README.md)).
- **Unresolved question: the hook boundary.** No callback runs inside the page transaction; deriving local data atomically with authoritative changes is not possible today ([#17](https://github.com/zanminwang/ahead/issues/17)).
- Error reporting is a single `Invalid(String)` variant; the consequence is owned by [SDKs / Bindings](../sdks/bindings.md).
