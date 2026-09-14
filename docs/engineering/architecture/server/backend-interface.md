# Backend interface

Invoke application handlers and loaders.

Current code: the `Host` trait and `Config` in [server/lib.rs](../../../../crates/server/src/lib.rs); handler and loader dispatch, `Session` tracking and `bindTransaction` in [server/index.mts](../../../../packages/server/index.mts) (`createBackend`, `host`); typed shapes from [Compiler / Generate](../compiler/generate.md) (`backend.ts`).

## 1. Introduction and Goals

- Run the application's business logic inside its own database transaction while the Rust engine decides what to run, in what order, and what the receipt says.

## 3. Context and Scope

- Rust side: `Host::call(request) -> Future<Result<Value, String>>` with operations `claim`, `saveReceipt`, `head`, `scan`, `publish` (persistence, see [Persistence](persistence.md)), `savepoint`/`rollback`/`release` (per mutation ordinal), `handle` and `load` (application).
- Application side (`createBackend` options): `config` (`backend.json`), `database: {transaction, persistence}`, `authenticate(request)`, `handlers`, `loaders`, optional `loaderHooks[model].prepareForViewer`, `translateRejection(error)`, `onError(error)`, `native` override.
- Handler contract: `handler({input, tx, userId, notify}) -> void | {channel}`; throw `MutationRejected(code)` (or an error `translateRejection` maps to a code) to reject one mutation; any other throw aborts the batch.
- Loader contract: `loader({ids, tx, userId, channel}) -> (row | null)[]` aligned with `ids`; `null` means "not visible / deleted"; `undefined` or a misaligned array is a defect.

## 5. Building Block View

- Startup validation: `Config::decode` (mutation descriptors, slots, patch capabilities, bindings, loaders) via `validateConfig`; a handler for every retained mutation version (`name` or `nameV<n>`) and a loader for every model must be registered, otherwise `createBackend` throws.
- Input shaping (`handle`): per slot, `create` arguments become `{…identity, …data}`, `update` becomes `{identity, patch}`, `delete` becomes `{identity}`; `list` slots become arrays, `optional` may be `null`; each shaped value is tagged with a hidden `RecordRef` so `notify({records:[input.slot]})` works.
- Checkpoint resolution: `notify` calls are buffered while the handler runs, then published in order; the handler's checkpoint channel is the returned `{channel}` (must have been notified) or the single notified channel; none or several without a choice is a `CheckpointError` that aborts the batch (guarantee A4).
- Rejection versus failure: `MutationRejected` and translated errors return `{rejection: code}` to Rust, which rolls back that mutation's savepoint; `CheckpointError` and every other error propagate and abort the outer transaction (guarantee P6).
- `Session` per transaction: tracks every host callback promise, records the first failure, and `assertCommittable` refuses to commit with unawaited or failed work; `touched` channels are snapshotted and restored around per-mutation savepoints so a rejected mutation does not wake live subscribers.
- External transactions: `backend.bindTransaction(tx)` returns `{notify, assertCommittable, afterCommit, close}` so application code outside a push can publish in its own transaction; `backend.notify(tx, …)` is the unbound shortcut.
- Authentication: `authenticate(request)` returns the user id (trimmed, non-empty) or null; `devAuth()` uses the bearer token verbatim and is documented as development-only. Channel-level authorization is deliberately absent (guarantee N5, [#22](https://github.com/zanminwang/ahead/issues/22)).

## 10. Quality Requirements

- A4, P6, C4 and loader contracts: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `backend validates config and complete registrations at startup`, `checkpoint is the single notified channel; several need an explicit choice; none is an error`, `checkpoint errors bypass translateRejection…`, `explicit rejection rolls back only mutation and its publication`, `unknown error rolls back entire batch…`, `loader defects abort pull…`, `undefined loader entries remain defects…`, `slot arguments are tagged so notify accepts them directly`, `pending unawaited publication prevents outer transaction commit`.
- Argument decoding: [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs).
- Simulation host: [crates/sim/src/host.rs](../../../../crates/sim/src/host.rs) implements the same operations in memory (A4 in [crates/sim/tests/authority.rs](../../../../crates/sim/tests/authority.rs)).

## 11. Risks and Technical Debt

- **Confirmed debt: the host operation set is an untyped string contract implemented three times.** [server/index.mts](../../../../packages/server/index.mts), the simulation `MemHost` and the test `Fixed` host each switch on `op` strings; there is no shared definition, so adding an operation or field is a manual three-way change. Evidence: `host()` in index.mts; [crates/sim/src/host.rs](../../../../crates/sim/src/host.rs); [server/tests/stamp.rs](../../../../crates/server/tests/stamp.rs).
- **Confirmed limitation: loaders must return exactly the schema's fields.** `normalize_state` refuses unknown keys, so a loader returning a database row with extra columns aborts the pull with a 500 rather than a 400. Evidence: [server/lib.rs](../../../../crates/server/src/lib.rs) `process_pull`; [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `loader defects abort pull…`. This is tested behavior; the consequence for handler authors (project rows explicitly) is not documented for users.
- **Unresolved question: a handler's `userId` is the only principal.** `principal()` checks non-emptiness; per-record or per-channel visibility is the loader's job and there is no guidance on where a loader should scope by `channel` versus `userId`.
- **Confirmed limitation: TypeScript-only backend runtime** ([SDKs / Typed API](../sdks/typed-api.md)).
