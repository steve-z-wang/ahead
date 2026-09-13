# Prisma transaction persistence

`prisma(client)` returns the `database` option for `createBackend`: a `PrismaClient` in, a `{ transaction, persistence }` pair out, ready to pass straight through. `PrismaPersistence` and `prismaTransactions` remain exported separately for callers assembling a custom `Database` adapter.

Apply `migration.sql` to PostgreSQL during application deployment. Pass an existing Prisma interactive transaction to `new PrismaPersistence(tx)`. The adapter neither creates a Prisma client nor starts a transaction.

The client row lock serializes batches from the same client and binds the client to its authenticated owner. Channel head increment and compacted invalidation upsert share the caller's transaction. Savepoints are generated from validated numeric mutation ordinals. SQL values use PostgreSQL parameters; only the validated savepoint identifier is interpolated.

Counters are bounded to JavaScript's safe integer range by Rust, the adapter, and database constraints. Receipt text is stored verbatim and returned on an exact semantic retry. Table names use the `otter_` prefix and are currently fixed. See [Server README](../server/README.md) for application wiring.
