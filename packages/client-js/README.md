# TypeScript client

The compiler emits `client.ts` next to your models. `GeneratedClient.open({path})` opens the shared Rust runtime on a SQLite file at that path with the generated schema; where the file lives, and whether there is one per signed-in user, is the application's decision. Build `bindings/node` before importing this source package. Adding a model does not recompile Rust.

```ts
import { GeneratedClient, httpTransport } from './generated/client.ts';
const client = await GeneratedClient.open({path: 'local.sqlite'});
await client.subscribe('book:example');
await client.connect(httpTransport({url: 'http://127.0.0.1:4242', token}));
await client.edit({entry: {identity: {id: 'entry-1'}, values: {text: 'offline'}}});
```

`Client.open({path, schema})` is the untyped runtime underneath; `GeneratedClient` forwards `subscribe`, `connect`, `sync`, `transaction`, `watch`, `status` and `close` to it and exposes the rest as `.client`.

## Sync and background connections

A transport receives `push` or `pull` plus the frozen JSON body and returns response JSON. `httpTransport({url, token})` talks to a backend started with `listen`, mapping these to `/sync/mutations` and `/sync/pull`; `token` may be a function for rotating credentials. A custom transport should throw on HTTP/network errors. `sync` performs one catch-up cycle. Local transactions remain available while network I/O is pending.

`connect(transport, {onError, refreshAuth})` runs in the background with Rust-controlled retry timing. The returned connection supports `pause`, `resume`, `wake`, and `close`. A transport may accept an optional `AbortSignal`; close also abandons a response from a transport that ignores cancellation. Mark an authentication error with `status: 401` to invoke the optional refresh callback. No authentication or credentials are built into the runtime.

## Transactions and queries

`transaction(async tx => ...)` provides read-your-writes and nested `tx.savepoint(async () => ...)`. Await every operation. Calls are serialized; failed or unfinished callbacks cannot escape commit/rollback. Watchers emit initial results and committed changes, with duplicate rows suppressed. `querySpec`, `related`, `referencing`, and `readSql` all execute in Rust. SQL reads an isolated optimistic snapshot and cannot write persistence tables.

## Prerequisite tasks

`pendingTasks` describes prerequisite I/O required by queued mutations. `runPrerequisites({Upload: async args => ...})` executes them one at a time. Callbacks must tolerate retries after process termination. Failed tasks stay optimistic; use `setReadiness(key, 'pending')` to retry or `drop(ordinal)` to cancel a mutation that has not been sent. Rust decides readiness and retains the failure state.

## Schema migration

For an explicit schema upgrade use `migration: {defaults: {Entry: {newField: null}}, replayPull: true}` when opening with a changed descriptor. This migration changes cached row shapes and optionally rewinds channel cursors atomically, preserving frozen requests and the offline queue. It is applied once per changed schema; repeated opens do not reset progress. Identity/type conversions requiring custom data transformation and importing the original framework's database are not implemented.

## Lifecycle and platform support

Use `close()` to release the native handle and connection. This first source package has been exercised on native macOS; browser/WebAssembly and distribution binaries are separate targets.
