# Bindings

## 1. Introduction and Goals

The bindings carry calls across the language boundary. One JSON command contract serves both Node and Dart, so a new language needs a carrier for strings, not a port of any logic. In the other direction, the Node addon lets the Rust server call back into the application's transaction.

## 3. Context and Scope

**Client direction.** Request `{op, handle?, transaction?, …}` → response `{value, changed, changedTables, generation}`; failures are error messages. The [typed API](typed-api/client.md) is the only caller.

**Server direction** (Node only). `validateConfig`, `processPush`, `processPull`, `publish`, `negotiateLive`, `pullLive`, each taking the config JSON, the owner, the request, and a host callback `(requestJson) => Promise<responseJson>` that runs inside the application's database transaction ([Backend interface](../server/backend-interface.md)).

## 5. Building Block View

- **The shared command host** (`RuntimeHost`) maps a numeric handle to an open client plus its connection state machines and dispatches every command to the [frontend interface](../client/frontend-interface.md). Command families: session (`begin`, `commit`, `rollback`, savepoints), reads, writes (`enqueue`, `direct`, `channel`), connection (`connection` per lane), sync (`startSync`, `next`, `complete`, `freeze`, `ack`, `downlinkRequest`, `downlinkPage`, `pull`) and state (`readiness`, `drop`, `dismiss`, `recordStatus`, `tasks`, `status`).
- **The session rule.** A command flagged `transaction: true` requires an open session; while a session is open, reads and writes route into it and every other command is refused. This is what lets a host keep one transaction open across many native calls without the engine ever seeing two at once.
- **Node carrier.** An async N-API function that locks one process-wide host and runs the command; server functions wrap a thread-safe JavaScript callback as the Rust host.
- **Dart carrier.** A C function taking and returning a JSON string, with panics caught; the Dart package runs it on a worker isolate per client and loads the library from `libraryPath` (or the process on iOS).

Code: [bindings/common/src/lib.rs](../../../../bindings/common/src/lib.rs); [bindings/node/src](../../../../bindings/node/src); [bindings/dart/src/lib.rs](../../../../bindings/dart/src/lib.rs); the isolate in [dart/client.dart](../../../../packages/dart/lib/src/client.dart).

## 6. Runtime View

`changed` compares the client generation before and after a command; the SDKs turn it into their change event. Errors arrive as the engine's messages (`client_closed`, `transaction_closed`, `stale client writer; reopen runtime`, …); the server SDK maps a few of them to HTTP statuses ([Server / Connection / Transport](../server/connection/transport.md)).

## 10. Quality Requirements

- **Session isolation and closed handles behave the same for every language.** Evidence: [bindings/common/tests/session.rs](../../../../bindings/common/tests/session.rs).
- **An asynchronous host callback runs inside the application's transaction, and a Rust error after a host write rolls both back** (server half of guarantee P6). Evidence: [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs).
- **A failed open does not leak the Dart worker isolate.** Evidence: [generated_test.dart](../../../../integration/generated-api/generated_test.dart) `failed generated open closes its native worker isolate`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Technical debt: errors are strings.** No error code crosses the boundary; the HTTP layer matches on message text such as `gap`, `overlap` and `request.invalid:`. Renaming a message in Rust silently changes HTTP behavior. Evidence: `createHttpHandler` in [server/index.mts](../../../../packages/server/index.mts). No issue tracks a typed error contract.

**Potential risk: one process-wide lock.** Every Node client call takes the same mutex on a Tokio worker thread and holds it for the SQLite work, so clients in one process serialize; Dart isolates share the same global host. Not measured ([#12](https://github.com/zanminwang/ahead/issues/12)). The server functions also re-parse and re-validate the config JSON on every call.

**Technical debt: spike code ships in the addon.** `runProbe` and `transaction-session.mjs` exist only for the transaction-bridge test; the server SDK does not use them.

**Accepted limitation.** `open` accepts and ignores `owner` and `migration` ([#20](https://github.com/zanminwang/ahead/issues/20)).
