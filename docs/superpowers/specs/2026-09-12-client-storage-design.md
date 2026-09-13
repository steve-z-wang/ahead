# Client storage redesign

2026-09-12. Design record for issue #9. The Rust client keeps its wire protocol and settlement semantics; its local persistence is rebuilt around ordinary per-model SQLite tables, following the Oasis reference client, and the client engine is rewritten to operate on rows inside SQLite transactions instead of on an in-memory copy of the whole state.

## Why

Today `crates/sqlite` stores everything as JSON documents in one table, `otter_documents(bucket, key, value)`. `Client` loads the whole table into a `ClientState` on open, clones the entire state for every operation, and writes back changed documents on commit. Read-only SQL opens a throwaway in-memory database, creates one table per model, copies every record in, runs the query and discards it.

The Oasis client is the design this project set out to reproduce: one real table per model whose rows are the merged optimistic view, a twin `_before` table holding server truth only while a row has a pending edit, infrastructure tables for the queue and cursors, reads against the real tables, and fine-grained transactions. `docs/architecture/code-organization.md` already describes that contract; the implementation never matched it.

## Goals

- The client database is a normal SQLite file a developer can open, inspect and index.
- Reads, including raw SQL, execute against the on-disk tables. Nothing is materialized per query.
- Writes touch only the rows involved. The working set is not bounded by memory.
- Wire protocol, server semantics and the existing settlement rules are unchanged, except for the push deduplication simplification recorded below.
- Bindings keep constructing a `SqliteStore` from a path; language packages are unaffected.

## Naming

Model tables carry the model name exactly as declared in the `.model` file: `Task`, `User`. Columns carry the field names. Framework tables carry the `otter_` prefix, the same convention the server already uses (`otter_client`, `otter_channel`, `otter_invalidation`). The compiler rejects a model whose name starts with `otter_`.

Table names describe what a row is, not one of its columns: a row in `otter_subscription` is a subscribed channel; a row in `otter_claim` is one channel providing one record.

## Tables

### Model tables

For each model `X` the compiler emits two tables with identical columns:

```sql
CREATE TABLE "X" (
  <one column per field, NOT NULL unless the field is nullable>,
  PRIMARY KEY (<identity fields from @@id>)
);
CREATE UNIQUE INDEX "X_<f1>_<f2>_unique" ON "X" (<fields>);   -- one per @@unique, main table only

CREATE TABLE "otter_before_X" (
  <same columns>,
  PRIMARY KEY (<same identity fields>)
);
```

Storage types: `Boolean`, `Int` → `INTEGER`; `Float` → `REAL`; everything else (`String`, `UUID`, `DateTime`, enums, scalar lists) → `TEXT`. Booleans are stored as 0/1; scalar lists as JSON text. No framework columns are added to model tables. No foreign keys are declared between model tables: the local store is a partial replica and must tolerate arrival order; cascade is apply-time logic over declared references.

`X` is the merged view. An optimistic edit is applied in place. `otter_before_X` holds a row's server truth only while the row is dirty, that is, while at least one pending operation touches it. The invariant is: a row exists in `otter_before_X` if and only if the row in `X` diverges from server truth. A queued create needs no before row; the queued create itself is the record that prior truth was absence.

### `otter_record`

One row per record the client holds authority for. Carries the content stamp defined in #8.

```sql
CREATE TABLE otter_record (
  model    TEXT NOT NULL,
  identity TEXT NOT NULL,          -- canonical JSON of the identity fields
  stamp    INTEGER NOT NULL,
  PRIMARY KEY (model, identity)
);
```

A row here with no matching row in `X` is a tombstone. It is dropped when no `otter_claim` row remains for the record; see Downlink.

### `otter_claim`

Which channels currently provide a record.

```sql
CREATE TABLE otter_claim (
  channel  TEXT NOT NULL,
  model    TEXT NOT NULL,
  identity TEXT NOT NULL,
  PRIMARY KEY (channel, model, identity)
);
CREATE INDEX otter_claim_record ON otter_claim (model, identity);
```

### `otter_subscription`

A row exists if and only if the client is subscribed to the channel.

```sql
CREATE TABLE otter_subscription (
  channel TEXT PRIMARY KEY,
  cursor  INTEGER NOT NULL          -- last applied cursor on this channel
);
```

Subscribing inserts a row at cursor 0. Unsubscribing deletes the row, deletes that channel's `otter_claim` rows, and deletes every record (main row, before row, `otter_record` row) that no other channel claims. Resubscribing pulls from 0. There is no `desired` flag and no subscription carried by mutations; `Mutation.subscribe` and `Mutation.unsubscribe` are removed from the client API.

### `otter_mutation` and its children

```sql
CREATE TABLE otter_mutation (
  ordinal INTEGER PRIMARY KEY,
  name    TEXT NOT NULL,
  version INTEGER NOT NULL,
  push    INTEGER                   -- push sequence once frozen; NULL while queued
);

CREATE TABLE otter_mutation_operation (
  ordinal  INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  kind     TEXT NOT NULL CHECK (kind IN ('wire', 'companion', 'effect')),
  model    TEXT NOT NULL,
  identity TEXT NOT NULL,
  op       TEXT NOT NULL CHECK (op IN ('create', 'update', 'delete')),
  "values" TEXT,                    -- full row for create, patch for update, NULL for delete
  PRIMARY KEY (ordinal, position)
);
CREATE INDEX otter_mutation_operation_record
  ON otter_mutation_operation (model, identity, ordinal, position);

CREATE TABLE otter_mutation_dependency (
  ordinal    INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  depends_on INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('lifecycle', 'sequence')),
  PRIMARY KEY (ordinal, depends_on),
  CHECK (depends_on < ordinal)
);

CREATE TABLE otter_mutation_prerequisite (
  ordinal INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  key     TEXT NOT NULL,
  error   TEXT,                     -- NULL while the host is working; set when it failed
  PRIMARY KEY (ordinal, key)
);
```

Operation kinds map to today's `Mutation` arrays: `wire` is sent to the server, `companion` is local-only and folded into truth at settlement, `effect` is a cascade delete derived at enqueue from a `delete` and a declared `onTargetDelete` reference. Rebuilding a record reads every pending operation touching it through `otter_mutation_operation_record` and replays them in `(ordinal, position)` order over the before row.

A `lifecycle` dependency means the mutation is rejected together with the one it depends on. A `sequence` dependency means it must be pushed after it.

Prerequisites replace the `readiness` map. A row means the mutation is waiting on host work keyed by `key`. The host deletes rows by key when the work succeeds and sets `error` when it fails; a retry clears `error`. A mutation is sendable when it has no prerequisite rows and no unsent `sequence` dependency.

### `otter_push_checkpoint`

What a push must wait for before it settles.

```sql
CREATE TABLE otter_push_checkpoint (
  push    INTEGER NOT NULL,
  channel TEXT NOT NULL,
  cursor  INTEGER NOT NULL,
  PRIMARY KEY (push, channel)
);
```

There is no push table. Which mutations belong to push N is `otter_mutation.push = N`. A push with mutations but no checkpoint rows is in flight. A push with checkpoint rows has been acknowledged and is waiting for cursors. The frozen request is not stored; a retry re-encodes it from the operation rows.

### `otter_rejection`

```sql
CREATE TABLE otter_rejection (
  ordinal INTEGER PRIMARY KEY,
  name    TEXT NOT NULL,
  code    TEXT NOT NULL,
  detail  TEXT                      -- the mutation's wire operations as JSON, for display
);
```

Written when a receipt rejects a mutation, at the same time the mutation row is deleted. Removed when the application dismisses it.

### `otter_client`

```sql
CREATE TABLE otter_client (
  client_id    TEXT PRIMARY KEY,
  next_ordinal INTEGER NOT NULL,
  next_push    INTEGER NOT NULL,
  generation   INTEGER NOT NULL
);
```

Exactly one row. `generation` is the stale-writer fence: every write transaction increments it with `WHERE generation = ?` and fails if another instance committed first. There is no stored owner and no stored schema descriptor. One database file per signed-in user is an application rule and is documented as such.

## Schema reconciliation on open

The tables are the schema record. On open, inside one transaction, for each model the client reads `PRAGMA table_info` and reconciles:

| Finding | Action |
| --- | --- |
| Table missing | Create `X` and `otter_before_X` |
| Column in schema, not in table | `ALTER TABLE ADD COLUMN` on both tables. Nullable: add as is. Non-nullable: requires a default from the schema, otherwise fail |
| Column in table, not in schema | Leave it; it is never read |
| Identity columns differ | Fail to open |
| Storage type differs | Fail to open |

Rows in `otter_mutation_operation` are never rewritten by reconciliation. Enum value sets are not checked; they are `TEXT`.

## Engine

### Store contract

`ClientStore` becomes a transactional, row-level contract. `load`/`commit` of a whole `ClientState` is removed. The shape is:

- `transaction(|tx| …)` on the write connection, with nested `savepoint`.
- Per-model: `get`, `upsert`, `patch`, `delete`, `identities_matching` on `X`; `copy_aside`, `replace_truth`, `drop` on `otter_before_X` (copy-aside is one `INSERT INTO otter_before_X SELECT … FROM X WHERE …`).
- Infrastructure operations mirroring the tables above.
- `read_sql` on the read connection.
- `changed_tables()` collected per transaction for notification.

`ClientState` disappears. `Client` holds the store, the schema and the watcher list.

### Transaction boundaries

| Operation | Boundary |
| --- | --- |
| Enqueue a mutation | One savepoint inside the caller's transaction |
| Apply one downlink change | One transaction, cursor re-read and checked inside it |
| Freeze a push | One transaction |
| Record a receipt | One transaction |
| Settle | Inside whichever transaction advanced a cursor or recorded a receipt |
| Open | One transaction for reconciliation and recovery settlement |

### Optimistic write

`create`: insert into `X`, append a `wire` operation. `update`: copy aside if not yet dirty, patch `X`, append. `delete`: derive `effect` deletes for descendants, copy aside each affected row if not yet dirty, delete from `X`, append. Companion operations follow the same path with kind `companion`.

### Rebuild

For a record: read truth from `otter_before_X` (absent means none), read surviving operations touching it, replay in order. A replay failure falls back to truth. Result absent → delete from `X`; present → upsert into `X`. If no operation survives, drop the before row.

### Downlink

For each change on channel C, record K, stamp S, with local stamp L from `otter_record` (absent = 0), applying the rules recorded on #8:

- Validate page order and the channel cursor.
- S < L: content discarded. Upsert inserts the claim; delete removes it. If K is a tombstone and this is a delete, the claim removal may leave no claims, in which case the `otter_record` row is dropped.
- S = L with equal content: no-op apart from claim bookkeeping. With different content: keep local, advance the cursor, emit a diagnostic.
- S > L upsert: `replace_truth` into `otter_before_X` if dirty, otherwise upsert `X`; write `otter_record.stamp = S`; insert the claim; rebuild if dirty.
- S > L delete: delete from `X` and from `otter_before_X`; write `otter_record.stamp = S`; remove C's claim only. Cascade descendants as today. If no claims remain, drop the `otter_record` row. Otherwise the remaining claims are the channels whose copy of this delete has not arrived yet.
- Advance `otter_subscription.cursor`, settle, commit.

### Push and settlement

Freeze: select sendable mutations in ordinal order up to the batch limit, assign `push = next_push`, increment `next_push`, encode the request from the rows. A retry re-encodes from the same rows; encoding uses canonical JSON.

Receipt: for each rejection, delete the mutation (and lifecycle dependents), write `otter_rejection`, rebuild affected rows. For each required checkpoint, insert `otter_push_checkpoint`. A receipt with no checkpoints settles the push immediately.

Settle: repeatedly take the smallest `push` that has checkpoint rows; if every checkpoint's `cursor` is ≤ the channel's `otter_subscription.cursor`, fold its companion operations into truth, delete its checkpoint rows and mutation rows, rebuild affected records, and continue; otherwise stop. Only the accepted prefix settles.

### Server change: push deduplication by sequence only

The server stops hashing the push body. `otter_client.request_hash` is dropped; `process_push` returns the stored receipt whenever `batch_sequence` equals the last processed sequence, and keeps the `gap` and `overlap` checks. `request_conflict` is removed. Consequence, documented: a client identity must never be used from two databases at once.

## Connections

`SqliteStore` holds two connections to the same file in WAL mode: one writer, one reader with `PRAGMA query_only = ON` and `PRAGMA foreign_keys = ON`. Framework writes use the writer. `read_sql` and watch re-evaluation use the reader and therefore see committed state only. A read pool is a later addition if concurrent reads are needed.

## Change notification

Each write transaction records the set of tables it changed. On commit the client notifies every watcher whose declared table set intersects it. The Rust API is `watch(tables: BTreeSet<String>) -> Receiver<()>`; the generation-based `subscribe()` is removed. Bindings expose `watch` with an explicit table list. Typed per-model watchers in generated clients fill the table list from the schema; raw SQL watchers take it from the caller. A watcher runs once on registration, re-runs when notified, and suppresses a result equal to the previous one.

## Out of scope

- The generated typed client (`client.task.watch(...)`, `openClient`). Depends on this design; separate issue.
- Per-mutation pushes and receipts.
- A read connection pool.
- Migration of existing `otter_documents` databases. The source alpha declares no compatibility.

## Tests

- `crates/sqlite`: contract tests for the store: savepoint rollback, before-row invariant, stale-writer fence, reconciliation cases in the table above, `query_only` on the reader.
- `crates/client`: rebuild, downlink stamp rules, tombstone drop, unsubscribe cleanup, settlement prefix, receipt with no checkpoints.
- `integration/rust`: the 64 interleaving scenarios pass unchanged.
- `crates/server`: dedup by sequence only; `request_conflict` removed.
- `bash scripts/test.sh` green on macOS and Linux.
