# TypeScript backend SDK

This TypeScript SDK embeds the shared Rust server runtime in your Node application. Business Handlers and Loaders are implemented in TypeScript, against the `Handlers`/`Loaders` interfaces the compiler generates from your `.model` file.

`index.mts` runs on Node with TypeScript support (Node 22.18+), or can be compiled with TypeScript. Build the local native module with `node bindings/node/build.mjs`. Supply an injected `native` implementation when packaging the native artifact elsewhere.

Given `models/book.model` describing an `Entry` Model and an `Edit` Mutation, the compiler emits `generated/backend.ts`, which already binds the schema:

```ts
// handlers.ts
import type { Handlers } from './generated/backend.ts';
import { MutationRejected } from './generated/backend.ts';

export const handlers: Handlers<Tx> = {
  async edit({ input, tx, userId, notify }) {
    const { identity, patch } = input.entry;
    if (!await canEdit(tx, userId, identity)) throw new MutationRejected('entry.forbidden');
    await tx.entry.update({ where: identity, data: patch });
    notify({ channel: 'book:demo', records: [input.entry] });
  },
};

// loaders.ts
import type { Loaders } from './generated/backend.ts';

export const loaders: Loaders<Tx> = {
  async entry({ ids, tx, userId }) {
    return Promise.all(ids.map(identity => loadVisibleEntry(tx, userId, identity)));
  },
};

// main.ts
import { createBackend, devAuth } from './generated/backend.ts';
import { prisma } from '../../packages/persistence-prisma/index.mts';
import { handlers } from './handlers.ts';
import { loaders } from './loaders.ts';

const backend = createBackend<Tx>({ database: prisma(db), authenticate: devAuth(), handlers, loaders });
const server = await backend.listen({ port: 4242 });
console.log(server.url);
```

The generated `createBackend` needs no `config` option: the schema is already bound. The runtime's own `createBackend` (`packages/server/index.mts`) still takes `config` explicitly, for callers that build the schema themselves.

`db` is your Prisma client and `Tx` is `Prisma.TransactionClient`. The application supplies `canEdit` and `loadVisibleEntry` to enforce its write and read permissions. Authorization, unique constraints, child deletion and client identity are the application's responsibility; the runtime does not enforce them ([What your backend owns](api.md#what-your-backend-owns)).

## Call objects

A Handler receives a `HandlerCall<Tx, Input>`: `{ input, tx, userId, notify }`. A Loader receives a `LoaderCall<Tx, Identity>`: `{ ids, tx, userId, channel }`. `input` and `ids` come from `EditInput`-style generated types; `tx` is the application's own transaction object; `userId` is the authenticated owner; `channel` is the channel whose Pull requested the rows, so a loader can decide what this user sees in this channel and return null for rows they must not see.

## notify

`notify({ channel, records })` declares that `records` (an array of slot arguments or `{ model, identity }` refs, such as those returned by the generated `Entry({ id })` constructor) changed and should be invalidated on `channel`, a non-empty string. A successful Handler must notify at least one channel; it may make several calls before it returns.

Every `notify` allocates a new **stamp** for each record, a per-record counter that Pull delivers with the record's content. The client applies content strictly by stamp, so the order of `notify` calls decides which channel's content wins when channels return different views of the same record.

Notify every channel that provides a record whenever that record changes, including when a loader starts returning `null` for it on one channel. A channel that is not notified keeps delivering its old stamp, and the client will not pick up the change through it. The framework does not detect a missing notification.

The receipt's checkpoint is chosen from what was notified: if exactly one channel was notified, that channel is the checkpoint automatically. If several channels were notified, the Handler must `return { channel }` to pick one explicitly. The returned channel must be one the handler notified. If no channel was notified, the batch aborts with `handler.no_channel`; if several were notified and the Handler did not disambiguate, it aborts with `handler.ambiguous_checkpoint`.

## Authentication

`authenticate` is `(request) => userId | null | undefined`, called per HTTP/WebSocket request; returning `null` or `undefined` rejects the request. `devAuth()` is a development-only implementation that trusts the `Authorization: Bearer <userId>` header verbatim — never use it in production.

## Errors

`onError?: (error) => void` on `BackendOptions` is called for server-side failures that clients only see as `{ code: "server" }` over HTTP: `authenticate` throws, persistence faults, checkpoint errors, and live drain failures. A failure raised by the native engine arrives as an `EngineError` with a stable `code` and a readable `message`; branch on the code, never on the message. See [Errors](api.md#errors) for the codes that map to HTTP statuses.

## Background jobs

Outside a Handler, use `backend.notify(tx, { channel, records })` for a one-shot notification bound to an existing transaction, or `backend.bindTransaction(tx).notify({ channel, records })` when the transaction owner needs to await commit and only then wake live subscribers:

```ts
const notifyCommitted = await db.$transaction(async tx => {
  const session = backend.bindTransaction(tx);
  try {
    await session.notify({ channel: 'book:demo', records: changes });
    await session.assertCommittable();
    return session.afterCommit();
  } finally {
    session.close();
  }
}, { isolationLevel: 'RepeatableRead' });
notifyCommitted();
```

## Transaction ownership

The outer transaction belongs to the application. Persistence, Handler, and Loader callbacks all receive that same transaction. The runner must provide a coherent snapshot (Repeatable Read or stronger), roll back on rejected promises, and retry serialization conflicts. `prismaTransactions` supplies this contract.

## Mutation results

A successful Handler returns `{channel: string}` to select its receipt checkpoint or returns `undefined` to use the single notified channel. Notification is explicit and can target several channels, but the receipt still settles against exactly one. An explicit `MutationRejected` or registered `translateRejection` code rolls back that mutation's savepoint, including business effects and notification; every other exception aborts the batch. Translation must produce a stable machine code. A known unsupported mutation version aborts the batch before any handler executes. The `handlers` key for a mutation is its lowerFirst name (e.g. `editTask`), and its value registers every retained version under `v1`, `v2`, .... A mutation that retains only v1 also accepts the plain function shown above; see [handlers](api.md#handlers).

## Loaders and Pull

Wire vocabulary remains `scope`, `syncId`, `requiredScope`, `requiredSyncId`, and `requiredCheckpoints`. Loaders return one state object or null for every identity, in precisely the supplied order. A missing or unauthorized row is null. Loader defects fail the request; they never skip rows or move the cursor past an error. Pull scans at most 50 compacted invalidations and materializes their current state.

Run `integration/persistence/server/run.sh` for the disposable PostgreSQL/Prisma integration suite. Its database is created, used, and destroyed by the runner.

`backend.listen({ port, host? })` starts a Node HTTP+WebSocket server that serves `/sync/mutations`, `/sync/pull`, and `/sync/live` on one port, and returns `{ url, close() }`. It resolves once the listener is bound.

For every option, callback, return value and failure mode, see the [backend interface reference](api.md). For process placement, the reverse-proxy configuration and trust boundaries, see [Deploy the backend](deployment.md).
