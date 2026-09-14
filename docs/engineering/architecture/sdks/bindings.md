# Bindings

Bridge calls, arguments, results, errors and events between the language and Rust.

Current code: shared command host in [bindings/common/src/lib.rs](../../../../bindings/common/src/lib.rs) (`RuntimeHost`); Node addon in [bindings/node/src](../../../../bindings/node/src) (`client.rs`, `server.rs`, `lib.rs`); Dart C ABI in [bindings/dart/src/lib.rs](../../../../bindings/dart/src/lib.rs); Dart worker isolate in [dart/client.dart](../../../../packages/dart/lib/src/client.dart) (`_nativeWorker`).

## 1. Introduction and Goals

- Cross the language boundary with one JSON command contract so the same Rust host serves Node and Dart, and so no sync policy leaks into the language packages.

## 3. Context and Scope

- Client direction: request `{op, handle?, transaction?, …}` → response `{value, changed, changedTables, generation}`; errors are message strings.
- Server direction (Node only): `validateConfig`, `processPush`, `processPull`, `publish`, `negotiateLive`, `pullLive`, each taking the config JSON, the owner, the request and a host callback `(requestJson) => Promise<responseJson>` that runs inside the application's transaction ([Server / Backend interface](../server/backend-interface.md)).
- Consumers: [Typed API](typed-api.md) runtime clients and the server SDK.

## 5. Building Block View

- `RuntimeHost`: a map from numeric handle to `{Client<SqliteStore>, SyncCycle, push ConnectionDriver, live ConnectionDriver}`; `open` creates the client and returns `{handle, clientId}`; `close` drops it.
- Command families: session (`begin`, `commit`, `rollback`, `savepoint`, `release`, `rollbackSavepoint`); reads (`read`, `query`, `querySpec`, `sql`, `related`, `referencing`); writes (`enqueue`, `direct`, `channel`); connection (`connection` with `lane` `push`|`live` and `event`); sync (`startSync`, `next`, `complete`, `freeze`, `ack`, `downlinkRequest`, `downlinkPage`, `pull`); state (`readiness`, `drop`, `dismiss`, `recordStatus`, `tasks`, `status`).
- Session rule: a command with `transaction: true` requires an active session (`transaction_closed`); while a session is active every non-read, non-write command is refused with `client transaction active`. Reads and writes route to the session when one is open, otherwise to a one-shot transaction or the committed reader.
- Node: `client_call` is an async N-API function that locks one process-global `Mutex<RuntimeHost>` and runs the command synchronously; server functions wrap a `ThreadsafeFunction` as the Rust `Host`. `runProbe` and [transaction-session.mjs](../../../../bindings/node/transaction-session.mjs) are the original transaction-bridge spike.
- Dart: `ahead_call(const char*) -> char*` and `ahead_free` on a `cdylib`/`staticlib`; panics are caught and returned as `{"ok":false,"error":"runtime panic"}`; the package runs every call on a dedicated worker isolate per client, loading the library from `libraryPath` (or the process on iOS).

## 6. Runtime View

- `changed` is derived from the client generation before and after the command; the language clients turn it into a single change event ([Typed API](typed-api.md)).
- Errors from Rust arrive as `Error::Invalid` messages (`client_closed`, `transaction_closed`, `stale client writer; reopen runtime`, …); the server SDK maps a handful of messages to HTTP statuses ([Server / Connection / Transport](../server/connection/transport.md)).

## 10. Quality Requirements

- Command contract: [bindings/common/tests/session.rs](../../../../bindings/common/tests/session.rs) (isolation, closed handles, transport action reuse, independent lanes, incoming page dispositions).
- Node transaction bridge: [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs) (async host callbacks inside a Prisma transaction, rollback, timeouts, synchronous throws).
- Dart boundary: [dart/test/client_test.dart](../../../../packages/dart/test/client_test.dart) `default native loader is reserved for iOS process symbols`; failed open closes the isolate: [generated_test.dart](../../../../integration/generated-api/generated_test.dart).

## 11. Risks and Technical Debt

- **Confirmed debt: errors are strings.** No code enum crosses the boundary; callers match on message text (`/^(gap|overlap)$/`, `startsWith("request.invalid:")`, `client_closed`). Renaming a message in Rust silently changes HTTP behavior. Evidence: [server/index.mts](../../../../packages/server/index.mts) `createHttpHandler`; [client-js/index.mts](../../../../packages/client-js/index.mts). No issue tracks a typed error contract.
- **Potential risk: one process-wide lock for all clients.** Every Node client call takes the same `std::sync::Mutex` on a Tokio worker thread and holds it for the duration of the SQLite work, so clients in one process serialize and can block the runtime's worker pool under load. Dart isolates share the same global `HOST`. Evidence: [bindings/node/src/client.rs](../../../../bindings/node/src/client.rs), [bindings/dart/src/lib.rs](../../../../bindings/dart/src/lib.rs). Not measured; performance work is [#12](https://github.com/zanminwang/ahead/issues/12).
- **Potential risk: the server config is re-parsed and re-validated per call.** Each `processPush`/`processPull`/`publish` call decodes the full config JSON and runs `Config::decode`. Evidence: [bindings/node/src/server.rs](../../../../bindings/node/src/server.rs) `config(&config_json)`. Cost grows with schema size; not measured ([#12](https://github.com/zanminwang/ahead/issues/12)).
- **Confirmed debt: spike code ships in the addon.** `runProbe`, `TransactionProbe` and `committedResult` exist only for [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs); the production server SDK does not use them. Evidence: [bindings/node/src/lib.rs](../../../../bindings/node/src/lib.rs), [transaction-session.mjs](../../../../bindings/node/transaction-session.mjs).
- **Confirmed debt: `open` accepts and ignores `owner` and `migration`.** Comment in `RuntimeHost::call`. Related: [#20](https://github.com/zanminwang/ahead/issues/20).
- **Confirmed limitation: apply reports do not cross the boundary on the live path.** `downlinkPage` returns only `{disposition, continues}`; skipped changes and equal-stamp conflicts counted by the engine are dropped. Owned by [Client Pull](../client/engine/pull.md).
