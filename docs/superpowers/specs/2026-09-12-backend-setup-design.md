# Backend setup redesign

2026-09-12. Refactor of the TypeScript backend surface so that a complete backend is one model file, one `handlers` object, one `loaders` object and two lines of setup. No behavior change in the Rust runtime or on the wire.

## Goal

The backend is the API layer. A developer should write only what the framework cannot know: the business logic of each mutation, how to load each model, how to identify the caller, and which database to use. Everything the compiler can derive from the `.model` files is generated.

## What the developer writes

```text
model Task {
 id String
 title String
 done Boolean
 @@id(id)
}
mutation AddTask { task Task.create }
mutation EditTask { task Task.update<title,done> }
```

```ts
// handlers.ts
import { type Handlers, MutationRejected } from "./generated/backend.ts";

export const handlers: Handlers<Tx> = {
  async addTask(ctx, { task }) {
    await ctx.tx.task.create({ data: task });
    ctx.publish(task, "team:demo");
  },
  async editTask(ctx, { task }) {
    if (task.patch.title === "") throw new MutationRejected("task.empty");
    await ctx.tx.task.update({ where: task.identity, data: task.patch });
    ctx.publish(task, "team:demo");
  },
};
```

```ts
// loaders.ts
import type { Loaders } from "./generated/backend.ts";

export const loaders: Loaders<Tx> = {
  task: (ctx, ids) => Promise.all(ids.map((id) => ctx.tx.task.findUnique({ where: id }))),
};
```

```ts
// main.ts
import { PrismaClient } from "@prisma/client";
import { prisma } from "@ottersync/prisma";
import { createBackend } from "./generated/backend.ts";

const backend = createBackend({
  database: prisma(new PrismaClient()),
  authenticate: (request) => userIdFromToken(request.headers.authorization),
  handlers,
  loaders,
});
await backend.listen(4242);
```

## Generated `backend.ts`

The compiler emits `generated/backend.ts` next to the existing client output. It contains:

- `createBackend(options)`: the runtime `createBackend` with the compiled schema bound. The developer never sees the schema object.
- `interface Handlers<Tx>`: one method per mutation, named in lower camel case from the mutation name (`AddTask` becomes `addTask`). Signature `(ctx: WriteContext<Tx>, input: AddTaskInput) => Promise<void | { channel: string }>`.
- `interface Loaders<Tx>`: one method per model, named in lower camel case from the model name. Signature `(ctx: ReadContext<Tx>, ids: readonly TaskIdentity[]) => Promise<readonly (Task | null)[]>`. An optional `prepareForViewer` hook keeps its current shape under `loaderHooks` and stays out of the main documentation.
- Input types per mutation (`AddTaskInput`), record types (`Task`), identity types (`TaskIdentity`) and patch types (`TaskPatch`), shared with the client output where identical.
- Re-exports of `MutationRejected`, `WriteContext`, `ReadContext` from `@ottersync/server`.

Handlers and loaders are not grouped by model. A mutation may touch several models; a loader serves exactly one.

`backend.json` and `schema.json` are still emitted for tooling and non-TypeScript hosts. Application code does not read them. `generated.ts` keeps the client-facing exports and drops `backendConfig`.

## Slot argument shapes

| Operation | Argument |
| --- | --- |
| create | The complete row: identity fields and data fields merged. |
| update | `{ identity, patch }`. |
| delete | `{ identity }`. |

Optional slots may be null; list slots are arrays. Every slot argument object carries a non-enumerable model tag set by the host before the handler runs, so `publish` can accept it directly.

## Context

`WriteContext<Tx>` is `{ tx, userId, publish }`. `ReadContext<Tx>` is `{ tx, userId, channel }`. The previous names `transaction`, `actorUserId` and `viewerUserId` are removed without aliases; this is a source alpha.

`publish(target, ...channels)` accepts a slot argument, a `{ model, identity }` object, or an array of either, followed by one or more channel names. It records the publication in the current transaction session exactly as `ctx.publish(changes, channels)` does today. It returns void; awaiting it is allowed but not required because the session drains outstanding publications before commit.

## Receipt checkpoint

A handler may still return `{ channel }` to choose the checkpoint channel for its receipt. When it returns nothing, the host selects:

- the single channel this handler published to, if it published to exactly one;
- the caller's principal channel, if it published to none;
- an error `handler.ambiguous_checkpoint` naming the mutation, if it published to several. The developer resolves it by returning `{ channel }`.

The Rust server keeps its current contract: one selected channel per mutation, computed by the host.

## Setup options

```ts
createBackend({
  database,        // { transaction, persistence } from an adapter such as prisma(client)
  authenticate,    // (request: IncomingMessage) => Promise<string | null> | string | null
  handlers,
  loaders,
  authorize?,      // ({ tx, userId, channel }) => boolean; default allows every channel
  principalChannel?, // (userId) => string; default `user:${userId}`
  translateRejection?,
  native?,
})
```

`database` bundles the transaction runner and the persistence factory. `@ottersync/prisma` exports `prisma(client, options?)` returning both; `PrismaPersistence` and `prismaTransactions` remain exported for adapters built on them.

`authenticate` moves into `createBackend`. Every `/sync/*` request passes through it; a null result is 401.

`authorize` becomes optional. The loader is the content authorization boundary; the channel guard is an optimization and metadata protection, as recorded in `docs/next-things.md`. The default returns true.

## Serving

`backend.listen(port, host = "127.0.0.1")` creates a Node HTTP server, mounts `/sync/mutations`, `/sync/pull` and the `/sync/live` WebSocket upgrade, and resolves to `{ url, close() }`. `close()` stops live subscriptions and the server.

`createHttpHandler` and `attachLive` become internal. Mounting on an application-owned server is not supported by the public surface.

## Removed

- `config`, `transaction`, `persistence` as top-level options.
- `principalChannel` and `authorize` as required options.
- `createHttpHandler`, `attachLive` exports.
- `packages/nest`, `integration/nest`, their steps in `scripts/test.sh` and CI, and the Nest rows in documentation. Otter Sync serves its own endpoints; Nest is one of the layers it replaces.

## Kept unchanged

- Rust runtime, wire format, storage tables, receipts and settlement rules.
- `backend.publish(tx, changes, channels)` and `bindTransaction` for background jobs.
- The Dart and TypeScript client packages. Client-side simplification (`openClient` with a built-in transport) is a separate design.

## Example and tests

`examples/rust-round-trip/server.mts` is rewritten to the new shape. Interfaces and type annotations are erased by Node's type stripping, so the example still runs with `node server.mts` and no build step.

Tests to update or add:

- `crates/compiler`: golden test for the emitted `backend.ts`; the generated file must compile under `integration/generated-api` with a handlers object that omits one mutation failing to typecheck.
- `integration/persistence/server/runtime.test.mjs`: use `database: prisma(db)`, `handlers`, `loaders`; add cases for the checkpoint default (one channel, none, several) and for the tagged slot argument passed to `publish`.
- `integration/bindings/client-js` and `integration/e2e`: unchanged behavior through the rewritten example.
- Remove `integration/nest`.

`bash scripts/test.sh` must pass on macOS and Linux before merge.

## Out of scope

Channel declarations in `.model`, a `services` directory convention, decorators, dependency injection, client-side `openClient`, and mounting on an existing HTTP server.
