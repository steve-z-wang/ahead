# Database adapters

Ahead does not require a particular backend database. Your adapter supplies transactions and stores Ahead's receipts, invalidations and counters alongside your business writes. The included implementation uses Prisma and PostgreSQL. Local client storage is SQLite regardless of your backend choice.

## Database and Persistence

```ts
interface Persistence {
  call(request: Record<string, any>): Promise<unknown>;
}

interface Database<Tx> {
  transaction<R>(body: (tx: Tx) => Promise<R>): Promise<R>;
  persistence(tx: Tx): Persistence;
}
```

`transaction` passes your transaction object to the callback, commits before resolving, and rolls back if the callback rejects. `persistence(tx)` must bind Ahead's storage operations to **that same transaction**, rather than opening a separate connection/transaction. Handlers and loaders receive the same `tx`.

The transaction must provide a coherent snapshot (Repeatable Read or stronger for the PostgreSQL implementation), serialize concurrent operations on the same client identity, and support per-mutation savepoints. Retry serialization conflicts as whole transactions. Because the callback can run again, irreversible external side effects should be arranged by your application's transaction/outbox mechanism.

## Prisma and PostgreSQL

```ts
import { prisma } from '../../packages/persistence-prisma/index.mts';

const database = prisma(db, { retries: 3, timeout: 20_000 });
// Pass database to generated createBackend({ database, ... }).
```

`db` is your Prisma client. The import above uses the example's directory depth. Apply [migration.sql](https://github.com/zanminwang/ahead/blob/main/packages/persistence-prisma/migration.sql) to your backend database using your deployment migration process before accepting sync traffic. The adapter does not create your business tables or initialize a database for you. The [getting-started runner](../getting-started.md) handles a disposable database for the example.

| Export | Input / return |
| --- | --- |
| `prisma(client, options?)` | Return `Database<Tx>` bundling the runner and persistence factory |
| `prismaTransactions(client, options?)` | Return the transaction runner alone |
| `new PrismaPersistence(tx?)` | Create a persistence adapter; `call` fails until it is bound |
| `persistence.bind(tx)` | Return a new adapter bound to this transaction |
| `persistence.call(request)` | Execute an operation below and return its result |
| `PrismaTransaction` | Capability with `$queryRawUnsafe` and `$executeRawUnsafe`, each accepting SQL plus separate values |

`timeout` is in milliseconds and defaults to 20,000. `retries` defaults to 3 retries after the first attempt. The runner uses `RepeatableRead` and retries Prisma `P2034`, or `P2010` with PostgreSQL `40001` / `40P01`. Other failures propagate immediately. Use nonnegative retry counts and an appropriate database timeout.

Ahead stores synchronization metadata in tables prefixed `ahead_`.

## Implement another adapter

The generic `Persistence.call` boundary uses the following operations. Use the [included implementation](https://github.com/zanminwang/ahead/blob/main/packages/persistence-prisma/index.mts) and [server persistence tests](https://github.com/zanminwang/ahead/blob/main/integration/persistence/server) together with this table when implementing one.

| `op` | Request fields | Required result / behavior |
| --- | --- | --- |
| `claim` | `clientId`, `owner` | Atomically create or lock the client row; return `{ clientId, owner, sequence, receipt }` |
| `saveReceipt` | `clientId`, `owner`, `sequence`, `receipt` | Persist the committed sequence and receipt for that owner; return null |
| `head` | `channel` | Current channel cursor, or zero for an empty channel |
| `scan` | `channel`, `after`, `limit` | Invalidations strictly after the cursor, ordered by cursor and limited to `limit`, each with the record's current stamp; a row whose record has no stamp is a storage failure |
| `advanceStamp` | `model`, `identityKey` | Allocate the record's next stamp (1 when it has none); return the new stamp |
| `ensureStamp` | `model`, `identityKey` | Return the record's current stamp, initializing it at 1 only when it has none; never increment an existing one |
| `publish` | `channel`, `model`, `identityKey`, `identity`, `stamp` | Allocate the channel's next cursor and store the invalidation at `stamp`, which must be the record's current stamp; return `{ cursor, stamp }` |
| `savepoint` | `ordinal` | Create the mutation savepoint; return null |
| `rollback` | `ordinal` | Roll back to the mutation savepoint; return null |
| `release` | `ordinal` | Release the mutation savepoint; return null |

Return exactly the fields listed: a result carrying anything beyond them is refused at the boundary, not ignored.

`scan` rows contain `{ channel, cursor, model, identityKey, identity, stamp }`, where `stamp` is read from the record's stamp row, not from the invalidation, because a change advances the stamp whether or not it is published. `identityKey` is provided by the runtime; preserve its canonical representation. `identity` is the decoded identity object. `receipt` is the stored serialized receipt, initially null with sequence zero. Unknown operations and storage failures must reject, not return a plausible empty result.

Persist a receipt atomically with business writes, stamps and publications. A retried `(clientId, sequence)` must observe the previously committed receipt rather than executing the handler again. Ownership must be enforced when saving it.

Channel cursors are monotonic within one channel. Stamps are monotonic for one `(model, identityKey)` **across channels**, not separate counters per channel, and advance only through `advanceStamp` (once per change) or a first `ensureStamp`; `publish` must refuse a stamp that is not the record's current one. Concurrent `advanceStamp` calls for one record must not allocate the same stamp, and concurrent `ensureStamp` calls must agree on 1. The Prisma implementation allocates stamps and cursors with atomic upserts and compacts invalidations by channel/model/identity.

All wire counters must fit the nonnegative JavaScript safe-integer range. Database 64-bit values must be range-checked before converting to JSON numbers. Schema and adapter migrations are your deployment responsibility; changing the application schema does not automatically migrate your backend tables.

Before using a custom adapter, verify transaction rollback, per-mutation rejection, duplicate request replay, owner mismatch, concurrent publication, cross-channel stamps and loader snapshot consistency. These are correctness requirements, not just performance choices.
