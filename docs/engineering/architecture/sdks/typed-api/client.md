# Typed API

Expose strongly typed APIs to applications.

Current code: generic runtime clients in [client-js/index.mts](../../../../packages/client-js/index.mts), [client-js/transaction.mts](../../../../packages/client-js/transaction.mts), [dart/client.dart](../../../../packages/dart/lib/src/client.dart), [dart/port.dart](../../../../packages/dart/lib/src/port.dart); server SDK in [server/index.mts](../../../../packages/server/index.mts); model-specific surface is compiler output ([Compiler / Generate](../compiler/generate.md)).

## 1. Introduction and Goals

- Give application code typed models, mutations, queries, watches and handlers while every rule (normalization, queueing, settlement) stays in Rust.

## 3. Context and Scope

- Application-facing client surface: `GeneratedClient.open({path, server?, connection?})`, `client.models.<model>.get/query/watch/<relation>`, `client.transaction(tx => tx.models.<model>.create/update/delete | tx.mutate.<mutation>(args))`, `client.channels.subscribe/unsubscribe`, `status()`, `close()`, plus the generic `Client` methods (`readSql`, `recordStatus`, `pendingTasks`, `setReadiness`, `runPrerequisites`, `drop`, `dismissRejection`, `freeze`, `acknowledge`, `applyPull`).
- Application-facing server surface: `createBackend({database, authenticate, handlers, loaders, loaderHooks?, translateRejection?, onError?})` → `{listen, push, pull, notify, bindTransaction, …}`; `MutationRejected`; `devAuth` ([Server / Backend interface](../server/backend-interface.md)).
- Dependencies: every client call becomes one JSON command to [Bindings](bindings.md); generated code depends on the runtime packages `@ahead/client`, `@ahead/server` and `package:ahead`.

## 5. Building Block View

- Ports: TypeScript `ReadPort`, `WritePort extends ReadPort`, `LivePort extends ReadPort` (generated); Dart `ReadPort`, `WritePort` in the runtime package. `Client` implements the live/read port; `Transaction` implements the write port.
- `Client` (both languages): one `#exclusive` promise chain serializes every command per client; `transaction(body)` sends `begin`, runs the body against a `Transaction`, then `finish` and `commit`, or `rollback` on any error.
- `Transaction`: queues commands in submission order, marks `transaction: true`, tracks unawaited work and first failure; `finish` throws `unawaited transaction operation`, the first failure, or a structural error; `savepoint(body)` nests via `AsyncLocalStorage` (TypeScript) or zone values (Dart) and refuses overlapping or unawaited scopes. A caught failure still poisons the transaction unless confined to a savepoint (guarantee L3 note).
- `watch(model, where, listener)`: re-runs `query` after every commit notification and emits only when the JSON differs; Dart exposes a broadcast `Stream`.
- `mutate(mutation)` outside a transaction opens one; `subscribe`/`unsubscribe` write the subscription row and wake the connection ([Client / Connection / Controller](../client/connection/controller.md)).
- Server typing: generated `Handlers<Tx>` map each retained mutation version to a key; loaders return rows aligned with `ids`; `notify({channel, records})` accepts slot arguments directly because the runtime tags them with a hidden `RecordRef`.

## 8. Crosscutting Concepts

- Presence versus null: TypeScript patches omit a key for "unchanged" and use `null` to clear; Dart uses `Present<T>?` for the same distinction; both encode to the same wire patch ([Protocol / Common](../protocol/common.md)).
- Dates cross as RFC 3339 strings and are decoded to `Date`/`DateTime` by generated codecs ([Types](../schema/types.md)).

## 10. Quality Requirements

- Transaction semantics: [transaction.test.mjs](../../../../integration/bindings/client-js/transaction.test.mjs); Dart equivalent in [dart/test/client_test.dart](../../../../packages/dart/test/client_test.dart) `Dart callbacks read their writes, rollback and reopen through native Rust`.
- Generated surface against native Rust: [integration/generated-api/test.ts](../../../../integration/generated-api/test.ts), [generated_test.dart](../../../../integration/generated-api/generated_test.dart).
- End to end per language (S4): [round-trip.test.mjs](../../../../integration/e2e/round-trip.test.mjs).

## 11. Risks and Technical Debt

- **Confirmed limitation: `watch` re-queries on every commit.** The binding reports `changedTables`, but both clients ignore it and emit a single `change` event, so a watcher on model A re-runs when only model B changed; there are no status streams. Evidence: [client-js/index.mts](../../../../packages/client-js/index.mts) `#send`, [dart/client.dart](../../../../packages/dart/lib/src/client.dart) `_send`. Open: [#16](https://github.com/zanminwang/ahead/issues/16).
- **Confirmed debt: the `migration` open option is a silent no-op.** Accepted by `Client.open` in both languages and by the generated clients, discarded by the binding. Evidence: [bindings/common/src/lib.rs](../../../../bindings/common/src/lib.rs) `open`. Open: [#20](https://github.com/zanminwang/ahead/issues/20).
- **Unresolved question: cross-language equivalence (S3).** `fixtures/scenarios` holds scripts but no runner; the two clients are separate implementations of the same orchestration (see [Client / Connection / Controller](../client/connection/controller.md)), so identical state is asserted only by the shared Rust engine, not by a test.
- **Confirmed limitation: the TypeScript client is Node-only.** It loads a native addon and uses the `ws` package with an `Authorization` header, neither of which exists in browsers. Evidence: [client-js/index.mts](../../../../packages/client-js/index.mts) `createRequire(...)("../../bindings/node/ahead-node.node")`, [client-js/package.json](../../../../packages/client-js/package.json). No issue records a browser target either way.
- **Confirmed limitation: server SDK is TypeScript only.** There is no Dart or other backend runtime; `Handlers`/`Loaders` are emitted for TypeScript only. Evidence: [compiler/emit.rs](../../../../crates/compiler/src/emit.rs) has `backend_typescript` and no Dart counterpart.
- Package publication (npm scope, pub.dev) is pending: [#37](https://github.com/zanminwang/ahead/issues/37).
