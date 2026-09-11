# Dart client

Generated model types sit above the generic `Client`; schema validation, local state, SQL reads, optimistic replay, channel cursors, mutation scheduling and settlement execute in Rust. Native calls run in a worker isolate.

Build the native library first with `bash scripts/build.sh` from the root. `Client.open(path: ..., schema: schema, owner: userId, libraryPath: ...)` keeps explicit native library selection for development. iOS uses process-linked native symbols when no path is supplied; see the platform smoke harness for the link/build steps.

The core operations are `transaction`, `mutate`, `read`, `querySpec`, `related`, `referencing`, `readSql`, `watch`, `subscribe`, `sync`, and `close`. The compiler emits typed queries, filters, sort fields, relationship accessors, immutable identities and nullable patches. `Present(null)` clears a field; omitting a patch field leaves it unchanged.

Await every transaction operation. `tx.savepoint` supports properly nested callbacks; concurrent or unfinished callbacks abort the transaction instead of escaping the native session. Watch streams emit an initial result and distinct committed results. SQL sees the current optimistic snapshot and refuses write statements.

A transport takes `(kind, frozenJsonBody)` and returns response JSON; it performs I/O only. `sync` catches up once. `connect` maintains background work and retries using Rust scheduling. The returned `RuntimeConnection` exposes `pause`, `resume`, `wake` and `close`. Pausing/closing abandons pending network responses, preserving frozen requests for later retry. Throw `AuthenticationExpired` from your transport to invoke the optional `refreshAuth` callback. No auth implementation is imposed.

`runPrerequisites` accepts a map of host I/O callbacks. Tasks run one at a time and must tolerate restart retries. Failed tasks remain optimistic until `setReadiness(key, 'pending')` retries them or an unsent mutation is dropped. `recordStatus` supplies queued/frozen/accepted phases and durable rejection context; `dismissRejection` clears an acknowledged local inbox entry.

Explicit schema changes can supply `migration: {'defaults': {'Entry': {'addedField': null}}, 'replayPull': true}`. The migration runs atomically only when the descriptor changes, preserving client identity, queued operations and frozen request bytes. It does not import the old framework's SQL database or perform arbitrary identity/type transformations.

The host test gate uses real SQLite and native Rust. Simulator/platform evidence is recorded separately; browser/WebAssembly is not implemented by this FFI package.
