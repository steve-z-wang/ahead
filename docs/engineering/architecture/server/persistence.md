# Persistence

## 1. Introduction and Goals

Persistence stores the framework's four tables in the application's own database, through the application's own transaction. That is what makes a push atomic: business writes, publications and the receipt are one commit.

## 3. Context and Scope

The application supplies a `Database<T>`: a `transaction(body)` runner that must give a coherent snapshot and roll back on failure, and a `persistence(tx)` factory returning an object with one method, `call(request)`. The requests it must answer:

| Request | Meaning |
| --- | --- |
| `claim {owner, clientId}` | create the client row if new, lock it, return owner, sequence and stored receipt |
| `saveReceipt {owner, clientId, sequence, receipt}` | record the batch outcome |
| `head {channel}` | current cursor of a channel (0 if unknown) |
| `scan {channel, after, limit}` | invalidation rows after a cursor, in order |
| `publish {channel, model, identity, identityKey}` | allocate the record's next stamp and the channel's next cursor, upsert the invalidation row, return both |
| `savepoint`, `rollback`, `release {ordinal}` | per-mutation savepoints |

Tables: `ahead_client`, `ahead_channel`, `ahead_record`, `ahead_invalidation` ([migration.sql](../../../../packages/persistence-prisma/migration.sql)).

## 5. Building Block View

The shipped adapter targets PostgreSQL through a Prisma interactive transaction. Its important properties: `claim` uses `SELECT … FOR UPDATE`, so retries of one client serialize on the row; `publish` allocates the stamp and cursor with atomic upserts that return the new values; the transaction runner uses repeatable read and retries serialization failures a bounded number of times. Counters are `bigint` with safe-range checks and are narrowed to safe integers on the way out.

Code: [persistence-prisma/index.mts](../../../../packages/persistence-prisma/index.mts); the contract in [server/index.mts](../../../../packages/server/index.mts).

## 10. Quality Requirements

- **Concurrent retries of one client execute once; head, scan and loader see one snapshot.** Evidence: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `concurrent same-client retry executes once under PostgreSQL lock`, `repeatable-read runner keeps head, scan, and loader coherent across concurrent publication`.
- **Stamps and cursors are allocated as specified and scans return them.** Evidence: `publish allocates one stamp per notify and stores it on the invalidation row`, `scan returns the stamp of each row`.
- **Per-mutation savepoints behave as savepoints against a real database.** Evidence: [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs) `business rejection rolls back its savepoint while preceding mutation commits`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Technical debt.** The `request_hash` column is never written or read ([Server Push](engine/push.md)).

**Accepted limitations.** PostgreSQL via Prisma is the only adapter; the SQL is PostgreSQL-specific. The framework tables are installed from a raw SQL file with no migration tooling. Rows are never pruned: client rows live forever and invalidation rows grow with records × channels (guarantee N1). The isolation requirement on an application-supplied runner is stated in prose only.
