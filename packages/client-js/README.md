# TypeScript client

[English](README.md) | [简体中文](README.zh-CN.md)

`Client.open({path,schema,owner})` opens the shared Rust runtime with actual SQLite persistence. Build `bindings/node` before importing this source package. Generated model APIs wrap the generic client; schema is runtime data and adding a model does not recompile Rust.

```ts
const client = await Client.open({path: 'local.sqlite', schema, owner: userId});
const models = new GeneratedClient(client);
await client.subscribe('book:example');
await models.edit({entry: {identity: {id: 'entry-1'}, values: {text: 'offline'}}});
await client.sync(transport);
```

The transport receives `push` or `pull` plus the frozen JSON body and returns response JSON. Throw on HTTP/network errors. The sample backend maps these to `/sync/mutations` and `/sync/pull`. `sync` performs one catch-up cycle. Local transactions remain available while network I/O is pending.

`connect(transport, {onError, refreshAuth})` runs in the background with Rust-controlled retry timing. The returned connection supports `pause`, `resume`, `wake`, and `close`. A transport may accept an optional `AbortSignal`; close also abandons a response from a transport that ignores cancellation. Mark an authentication error with `status: 401` to invoke the optional refresh callback. No authentication or credentials are built into the runtime.

`transaction(async tx => ...)` provides read-your-writes and nested `tx.savepoint(async () => ...)`. Await every operation. Calls are serialized; failed or unfinished callbacks cannot escape commit/rollback. Watchers emit initial results and committed changes, with duplicate rows suppressed. `querySpec`, `related`, `referencing`, and `readSql` all execute in Rust. SQL reads an isolated optimistic snapshot and cannot write persistence tables.

`pendingTasks` describes prerequisite I/O required by queued mutations. `runPrerequisites({Upload: async args => ...})` executes them one at a time. Callbacks must tolerate retries after process termination. Failed tasks stay optimistic; use `setReadiness(key, 'pending')` to retry or `drop(ordinal)` to cancel a mutation that has not been sent. Rust decides readiness and retains the failure state.

For an explicit schema upgrade use `migration: {defaults: {Entry: {newField: null}}, replayPull: true}` when opening with a changed descriptor. This migration changes cached row shapes and optionally rewinds channel cursors atomically, preserving frozen requests and the offline queue. It is applied once per changed schema; repeated opens do not reset progress. Identity/type conversions requiring custom data transformation and importing the original framework's database are not implemented.

Use `close()` to release the native handle and connection. This first source package has been exercised on native macOS; browser/WebAssembly and distribution binaries are separate targets.
