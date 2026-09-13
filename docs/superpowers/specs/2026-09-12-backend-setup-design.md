# Backend setup redesign

2026-09-12. Refactor of the TypeScript backend surface so that a complete backend is one model file, one `handlers` object, one `loaders` object and two lines of setup. The Rust runtime keeps its semantics; the only Rust change is dropping the push fallback channel.

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
  async addTask({ input: { task }, tx, notify }) {
    await tx.task.create({ data: task });
    notify(task, "team:demo");
  },
  async editTask({ input: { task }, tx, notify }) {
    if (task.patch.title === "") throw new MutationRejected("task.empty");
    await tx.task.update({ where: task.identity, data: task.patch });
    notify(task, "team:demo");
  },
};
```

```ts
// loaders.ts
import type { Loaders } from "./generated/backend.ts";

export const loaders: Loaders<Tx> = {
  task: ({ ids, tx }) => Promise.all(ids.map((id) => tx.task.findUnique({ where: id }))),
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
- `interface Handlers<Tx>`: one method per mutation, named in lower camel case from the mutation name (`AddTask` becomes `addTask`). Signature `(call: HandlerCall<Tx, AddTaskInput>) => Promise<void | { channel: string }>`.
- `interface Loaders<Tx>`: one method per model, named in lower camel case from the model name. Signature `(call: LoaderCall<Tx, TaskIdentity>) => Promise<readonly (Task | null)[]>`. An optional `prepareForViewer` hook keeps its current shape under `loaderHooks` and stays out of the main documentation.
- Input types per mutation (`AddTaskInput`), record types (`Task`), identity types (`TaskIdentity`) and patch types (`TaskPatch`), shared with the client output where identical.
- Re-exports of `MutationRejected`, `HandlerCall`, `LoaderCall` from `@ottersync/server`.

Handlers and loaders are not grouped by model. A mutation may touch several models; a loader serves exactly one.

`backend.json` and `schema.json` are still emitted for tooling and non-TypeScript hosts. Application code does not read them. `generated.ts` keeps the client-facing exports and drops `backendConfig`.

## Slot argument shapes

| Operation | Argument |
| --- | --- |
| create | The complete row: identity fields and data fields merged. |
| update | `{ identity, patch }`. |
| delete | `{ identity }`. |

Optional slots may be null; list slots are arrays. Every slot argument object carries a non-enumerable model tag set by the host before the handler runs, so `notify` can accept it directly.

## Handler and loader calls

Each handler and loader receives one object and destructures what it needs, in the style of tRPC and Remix. The declared order is the subject first, then the tools in order of use: `input`, `tx`, `userId`, `notify`. `notify` replaces the previous `publish`, which suggested that record content was sent; only an invalidation is.

```ts
HandlerCall<Tx, Input> = { input: Input; tx: Tx; userId: string; notify: Notify }
LoaderCall<Tx, Identity> = { ids: readonly Identity[]; tx: Tx; userId: string }
```

`input` is not flattened into the call object because slot names could collide with framework fields. The previous `(ctx, input)` shape and the names `transaction`, `actorUserId`, `viewerUserId` and the loader's `channel` are removed without aliases; this is a source alpha. A loader's result may depend only on the record and the viewer, never on the channel that triggered the pull.

`notify(target, ...channels)` accepts a slot argument, a `{ model, identity }` object, or an array of either, followed by one or more channel names. It records an invalidation in the current transaction session exactly as the previous `ctx.publish(changes, channels)` did. The name says what it does: it tells subscribers of those channels that the record changed; the content comes from the loader. It returns void; awaiting it is allowed but not required because the session drains outstanding publications before commit.

## Channels

The framework has two concepts at its boundary: a **channel** is a named distribution scope that clients subscribe to and handlers notify, and **authenticate** tells the framework who is calling. How channels are named, who subscribes to which, and what each user may see are application decisions. The loader is the visibility boundary: it returns null for a row the viewer must not see. The framework has no notion of a per-user or "principal" channel and does not guard subscriptions.

## Receipt checkpoint

A handler may return `{ channel }` to choose the checkpoint channel for its receipt. When it returns nothing, the host selects the single channel it notified. If it notified several, the host raises `handler.ambiguous_checkpoint` naming the mutation; the developer resolves it by returning `{ channel }`. If it notified none and returned nothing, the host raises `handler.no_channel`: a mutation that notifies nobody has no place in this model.

The Rust server currently receives a fallback channel per push (the former principal channel) and uses it for mutations without a selected channel and for the legacy `requiredScope`/`requiredSyncId` receipt fields. The fallback parameter is removed. `requiredScope` becomes the first selected checkpoint channel, or an empty string when every mutation in the batch was rejected. The wire fixtures and the 64 client/server interleaving scenarios verify that the client's settlement is unaffected.

## Setup options

```ts
createBackend({
  database,        // { transaction, persistence } from an adapter such as prisma(client)
  authenticate,    // (request: IncomingMessage) => Promise<string | null> | string | null
  handlers,
  loaders,
  translateRejection?,
  native?,
})
```

`database` bundles the transaction runner and the persistence factory. `@ottersync/prisma` exports `prisma(client, options?)` returning both; `PrismaPersistence` and `prismaTransactions` remain exported for adapters built on them.

`authenticate` is required and moves into `createBackend`. Every `/sync/*` request and live upgrade passes through it; a null, undefined or empty result is 401, and a thrown error is 500. `@ottersync/server` exports `devAuth()`, which treats the bearer token as the user id; it is for local development and examples only and its documentation says so.

`authorize` and `principalChannel` are removed. The Rust pull path still asks the host whether a subscription is allowed; the host answers true.

## Serving

`backend.listen(port, host = "127.0.0.1")` creates a Node HTTP server, mounts `/sync/mutations`, `/sync/pull` and the `/sync/live` WebSocket upgrade, and resolves to `{ url, close() }`. `close()` stops live subscriptions and the server.

`createHttpHandler` and `attachLive` become internal. Mounting on an application-owned server is not supported by the public surface.

## Removed

- `config`, `transaction`, `persistence` as top-level options.
- `principalChannel` and `authorize` entirely.
- `createHttpHandler`, `attachLive` exports.
- `packages/nest`, `integration/nest`, their steps in `scripts/test.sh` and CI, and the Nest rows in documentation. Otter Sync serves its own endpoints; Nest is one of the layers it replaces.

## Kept unchanged

- Rust runtime semantics, storage tables and settlement rules. The only Rust change is dropping the push fallback channel described under Receipt checkpoint.
- `backend.notify(tx, target, ...channels)` (renamed from `backend.publish`) and `bindTransaction` for background jobs.
- The Dart and TypeScript client packages. Client-side simplification (`openClient` with a built-in transport) is a separate design.

## Example and tests

`examples/rust-round-trip/server.mts` is rewritten to the new shape. Interfaces and type annotations are erased by Node's type stripping, so the example still runs with `node server.mts` and no build step.

Tests to update or add:

- `crates/compiler`: golden test for the emitted `backend.ts`; the generated file must compile under `integration/generated-api` with a handlers object that omits one mutation failing to typecheck.
- `integration/persistence/server/runtime.test.mjs`: use `database: prisma(db)`, `handlers`, `loaders`; add cases for the checkpoint selection (one channel, none, several) and for the tagged slot argument passed to `notify`.
- `crates/server` and `integration/rust`: adjust the push signature and receipt legacy fields; all existing scenarios must still pass.
- `integration/bindings/client-js` and `integration/e2e`: unchanged behavior through the rewritten example.
- Remove `integration/nest`.

`bash scripts/test.sh` must pass on macOS and Linux before merge.

## Out of scope

Channel declarations in `.model`, a `services` directory convention, decorators, dependency injection, client-side `openClient`, and mounting on an existing HTTP server.
