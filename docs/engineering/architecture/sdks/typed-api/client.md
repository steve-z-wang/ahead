# Client

## 1. Introduction and Goals

An application should write `tx.mutate.editEntry(...)` and `client.models.entry.watch(...)` and never see JSON, ordinals or cursors. The client typed API is that layer: a generic runtime class per language that knows how to talk to Rust, and generated classes that give it the application's model names and types.

## 3. Context and Scope

What an application sees:

| Surface | Purpose |
| --- | --- |
| `GeneratedClient.open({path, server?, connection?})` | open the local database; with `server`, connect and keep syncing |
| `client.models.<model>.get / query / watch / <relation>` | reads on the last commit; `watch` re-emits when results change |
| `client.transaction(tx => …)` with `tx.models.<model>.create / update / delete` and `tx.mutate.<mutation>(args)` | direct writes and named mutations in one local transaction |
| `client.channels.subscribe / unsubscribe` | choose which server channels to follow |
| `status()`, `recordStatus()`, `pendingTasks()`, `setReadiness()`, `runPrerequisites()`, `drop()`, `dismissRejection()`, `readSql()` | inspection and control, on the generic client |

Every call becomes one command through the [bindings](../bindings.md). Generated code depends on the runtime package (`@ahead/client`, `package:ahead`); the generic runtime depends on nothing generated.

## 5. Building Block View

- **Ports.** Three small interfaces separate what can be done where: a read port (reads), a write port (reads plus `direct` and `mutate`), and in TypeScript a live port (reads plus `watch`). The client implements the live port; a transaction implements the write port. Generated model classes are written against the ports, which is why a `watch` inside a transaction is a compile error.
- **Client.** One promise chain per client serializes every command, so calls from the application, the connection and watchers never interleave inside Rust. `transaction` sends `begin`, runs the body against a transaction object, then `finish` and `commit`, or `rollback` on any error.
- **Transaction.** Commands are queued in submission order and marked as belonging to the transaction. `finish` fails if any command was never awaited, if any command failed even though the application caught the error, or if savepoints overlapped. `savepoint(body)` nests via async context (TypeScript) or zone values (Dart) so a failure inside it is confined to that scope.
- **Watch.** Re-runs the query after every commit notification and emits only when the JSON result differs; Dart exposes a broadcast stream.
- **Generated code.** Types, codecs (dates to `Date`/`DateTime`), mutation builders, model classes and the two facades `GeneratedClient` and `GeneratedTransaction` ([Compiler / Generate](../../compiler/generate.md)). Presence is expressed as an omitted key versus `null` in TypeScript and as `Present<T>?` in Dart; both encode to the same wire patch.

Code: [client-js/index.mts](../../../../../packages/client-js/index.mts), [client-js/transaction.mts](../../../../../packages/client-js/transaction.mts), [dart/client.dart](../../../../../packages/dart/lib/src/client.dart), [dart/port.dart](../../../../../packages/dart/lib/src/port.dart).

## 10. Quality Requirements

- **An unawaited or escaped call poisons the transaction, and a caught failure still rolls it back unless confined to a savepoint** (binding half of guarantee L3). Evidence: [transaction.test.mjs](../../../../../integration/bindings/client-js/transaction.test.mjs); [dart/test/client_test.dart](../../../../../packages/dart/test/client_test.dart) `Dart callbacks read their writes, rollback and reopen through native Rust`.
- **Generated code forwards calls unchanged and rejects misuse at compile time** (guarantee S2). Evidence: [integration/generated-api/test.ts](../../../../../integration/generated-api/test.ts) (positives and `@ts-expect-error` negatives); [generated_test.dart](../../../../../integration/generated-api/generated_test.dart) (positives only).
- **One end-to-end flow per language works against a real backend** (guarantee S4). Evidence: [round-trip.test.mjs](../../../../../integration/e2e/round-trip.test.mjs).

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation (planned change).** `watch` re-runs its query on every commit, whatever table changed; the binding already reports touched tables but neither client uses them, and there are no status streams. Scoped notifications are [#16](https://github.com/zanminwang/ahead/issues/16).

**Accepted limitation.** `Client.open` and the generated `open` still accept a `migration` option that the runtime ignores; its future is part of [#20](https://github.com/zanminwang/ahead/issues/20).

**To confirm.** No test runs one script through the Rust, TypeScript and Dart clients and compares state (guarantee S3); the two clients are separate implementations of the same session logic ([Live session](../../client/connection/controller/live-session.md)), so identical behavior rests on the shared Rust engine.
