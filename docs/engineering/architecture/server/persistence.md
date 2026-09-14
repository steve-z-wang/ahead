# Persistence

Persist sync metadata within the application's transaction; no business logic.

Current code: the `Persistence` and `Database<T>` interfaces in [server/index.mts](../../../../packages/server/index.mts); the PostgreSQL adapter in [persistence-prisma/index.mts](../../../../packages/persistence-prisma/index.mts) (`PrismaPersistence`, `prismaTransactions`, `prisma`); tables in [persistence-prisma/migration.sql](../../../../packages/persistence-prisma/migration.sql).

## 1. Introduction and Goals

- Store the framework's four tables next to the application's data so a push, its publications and its receipt commit atomically with the business writes, using the transaction the application already has.

## 3. Context and Scope

- `Database<T>`: `transaction(body)` must provide a coherent snapshot and roll back on rejection; `persistence(tx)` returns a `Persistence` bound to that transaction.
- `Persistence.call(request)` operations: `claim {owner, clientId}`, `saveReceipt {owner, clientId, sequence, receipt}`, `head {channel}`, `scan {channel, after, limit}`, `publish {channel, model, identity, identityKey}`, `savepoint`/`rollback`/`release {ordinal}`.
- Tables: `ahead_client (client_id, owner_id, sequence, request_hash, receipt)`, `ahead_channel (channel, head)`, `ahead_record (model, identity_key, stamp)`, `ahead_invalidation (channel, model, identity_key, identity jsonb, cursor, stamp)` with `PRIMARY KEY (channel, model, identity_key)` and `UNIQUE (channel, cursor)`; all counters are `bigint` with safe-range checks.
- Callers: the `host()` function forwards every non-application operation to `storage.call` ([Backend interface](backend-interface.md)).

## 5. Building Block View

- `claim`: `INSERT … ON CONFLICT DO NOTHING` then `SELECT … FOR UPDATE`, so concurrent pushes from one client serialize on the row (guarantee P1 under PostgreSQL).
- `saveReceipt`: `UPDATE … WHERE client_id AND owner_id`; zero rows is `Receipt owner mismatch`.
- `publish`: upsert `ahead_record` (`stamp + 1`, `RETURNING`), upsert `ahead_channel` (`head + 1`, `RETURNING`), upsert the invalidation row to the new cursor and stamp.
- `scan`: `WHERE channel = $1 AND cursor > $2 ORDER BY cursor LIMIT $3`.
- Savepoints: `SAVEPOINT ahead_mutation_<ordinal>` and friends; ordinals are validated as safe positive integers.
- `prismaTransactions(client, {retries, timeout})`: `$transaction` at `RepeatableRead` with a 20 s default timeout, retrying serialization failures (`P2034`, `40001`, `40P01`) up to 3 times; `prisma(client)` bundles it with the persistence factory.
- BigInt values from PostgreSQL are narrowed to safe integers by `safe()` and by the SDK's `callbackJson`.

## 10. Quality Requirements

- [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `Prisma persistence supports reusable bind without owning a transaction`, `push commits business + compacted publication + exact durable receipt together`, `concurrent same-client retry executes once under PostgreSQL lock`, `publish allocates one stamp per notify…`, `scan returns the stamp of each row`, `repeatable-read runner keeps head, scan, and loader coherent…`, `prisma() bundles the transaction runner and the persistence factory`; savepoint semantics against a real database: [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs).

## 11. Risks and Technical Debt

- **Confirmed debt: `request_hash` is dead schema.** The column exists and is never read or written ([Server Push](engine/push.md)).
- **Confirmed limitation: PostgreSQL via Prisma is the only adapter.** The SQL uses `$n` placeholders, `ON CONFLICT … RETURNING` and `::jsonb`; the `Persistence` interface is generic but nothing else implements it outside the in-memory simulation host. Evidence: [persistence-prisma/index.mts](../../../../packages/persistence-prisma/index.mts). No issue tracks another adapter.
- **Confirmed limitation: schema installation is a raw SQL file.** Tests and the example apply `migration.sql` statement by statement; there is no versioned migration or compatibility check for the framework tables. Evidence: [examples/rust-round-trip/server.mts](../../../../examples/rust-round-trip/server.mts) `initialize`.
- **Confirmed limitation: unbounded retention** (guarantee N1). `ahead_client` rows live forever per client id; `ahead_record` and `ahead_invalidation` grow with records × channels and are never pruned.
- **Unresolved question: isolation requirements are prose.** `Database.transaction` is documented as "must provide a coherent snapshot"; the coherence test runs at `RepeatableRead`, and nothing verifies an application-supplied runner at a weaker level.
