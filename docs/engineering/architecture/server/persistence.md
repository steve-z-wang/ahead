# Persistence

## 1. Introduction and Goals

Persistence stores the framework's four tables in the application's own database, through the application's own transaction. That is what makes a push atomic: business writes, stamps, publications and the receipt are one commit.

## 3. Context and Scope

The application supplies a `Database<T>`: a `transaction(body)` runner that must give a coherent snapshot and roll back on failure, and a `persistence(tx)` factory returning an object with one method, `call(request)`. The requests it must answer:

| Request | Meaning |
| --- | --- |
| `claim {owner, clientId}` | create the client row if new, lock it, return owner, sequence and stored receipt |
| `saveReceipt {owner, clientId, sequence, receipt}` | record the batch outcome |
| `head {channel}` | current cursor of a channel (0 if unknown) |
| `scan {channel, after, limit}` | invalidation rows after a cursor, in order, each joined with the record's current stamp from `ahead_record`; a row whose record has no stamp is a storage defect |
| `advanceStamp {model, identityKey}` | allocate the record's next stamp (1 for a record without one) and return it |
| `ensureStamp {model, identityKey}` | return the record's current stamp, initializing it at 1 only when it has none |
| `publish {channel, model, identity, identityKey, stamp}` | allocate the channel's next cursor and upsert the invalidation row at the given stamp, which must be the record's current one; return both |
| `savepoint`, `rollback`, `release {ordinal}` | per-mutation savepoints |

Tables: `ahead_client`, `ahead_channel`, `ahead_record`, `ahead_invalidation` ([migration.sql](../../../../packages/persistence-prisma/migration.sql)).

## 5. Building Block View

The shipped adapter targets PostgreSQL through a Prisma interactive transaction. Its important properties: `claim` uses `SELECT … FOR UPDATE`, so retries of one client serialize on the row; `advanceStamp` and `ensureStamp` allocate stamps with atomic upserts that return the new value, so concurrent first publications agree on 1 and an established stamp is never overwritten; `publish` allocates the cursor the same way and refuses a stamp that is not the record's current one; `scan` is a `LEFT JOIN` from the invalidation row to the stamp row, so a page carries the stamp of the content the loader reads, not the stamp the record had when it was last published; the transaction runner uses repeatable read and retries serialization failures a bounded number of times. Counters are `bigint` with safe-range checks and are narrowed to safe integers on the way out.

Code: [persistence-prisma/index.mts](../../../../packages/persistence-prisma/index.mts); the contract in [server/index.mts](../../../../packages/server/index.mts).

## 10. Quality Requirements

- **Concurrent retries of one client execute once; head, scan and loader see one snapshot.** Evidence: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `concurrent same-client retry executes once under PostgreSQL lock`, `repeatable-read runner keeps head, scan, and loader coherent across concurrent publication`.
- **A stamp advances without a channel; one push publishing to two channels carries one stamp to both and advances each head once; an external notify advances the stamp on every call while a push publishing an unchanged record does not; concurrent first publications initialize one stamp of 1; a rolled-back transaction removes a first initialization with its publication; `publish` refuses a missing or stale stamp; `scan` pairs the cursor with the current stamp** (guarantee D3). Evidence: `advanceStamp increments without a channel: no invalidation, no channel head`, `one push publishing to two channels carries the same stamp to both and advances each head once`, `an external notify advances the stamp on every call; a push publishing an unchanged record does not`, `concurrent first publications initialise one stamp of 1 and never overwrite an established one`, `a rolled-back transaction removes a first initialisation together with its publication`, `publish refuses a record without metadata or with a stamp that is not its current one`, `scan pairs the invalidation cursor with the current record stamp; a missing record row is a storage defect`, `concurrent notifies of one record receive distinct stamps`.
- **Fresh framework tables define no `request_hash`; a table installed from an earlier `migration.sql` that still carries the column serves claim, replay and gap checks unchanged, before and after the column is dropped.** Evidence: `fresh framework tables omit request_hash; a table that still carries the column keeps replaying receipts`.
- **Per-mutation savepoints behave as savepoints against a real database.** Evidence: [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs) `business rejection rolls back its savepoint while preceding mutation commits`.

Executed 2026-09-15: `bash integration/persistence/server/run.sh` (61 passed) with the stamp separation; the savepoint bridge test read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation (legacy column).** `ahead_client` once defined a `request_hash text` column that nothing wrote or read; receipt replay is keyed by client and sequence ([Server Push §9](engine/push.md#9-architecture-decisions)). Databases installed before its removal keep the column: `CREATE TABLE IF NOT EXISTS` never alters an existing table, and the adapter names its columns, so the extra one is ignored. Removing it is optional and safe, `ALTER TABLE ahead_client DROP COLUMN request_hash`, and touches no receipts or business data.

**Accepted limitations.** PostgreSQL via Prisma is the only adapter; the SQL is PostgreSQL-specific. The framework tables are installed from a raw SQL file with no migration tooling. Rows are never pruned: client rows live forever and invalidation rows grow with records × channels. The isolation requirement on an application-supplied runner is stated in prose only.
