# Backend interface

## 1. Introduction and Goals

The backend interface is where the framework meets application code. The Rust engine never touches the application's database directly; instead it asks a *host* to do things, and the host runs each request inside the transaction the application opened. Two of those requests reach application code: run this handler, load these records.

## 3. Context and Scope

The host operations the engine may issue:

| Operation | Answered by | Purpose |
| --- | --- | --- |
| `handle` | the application's handler | run one mutation's business logic |
| `load` | the application's loader | return the current state of records |
| `savepoint`, `rollback`, `release` | [Persistence](persistence.md) | isolate one mutation's effects |
| `claim`, `saveReceipt`, `head`, `scan`, `publish` | [Persistence](persistence.md) | framework tables |

Application-facing contracts ([Typed API / Server](../sdks/typed-api/server.md) shows their types):

- A **handler** receives the decoded input (one value per slot), the transaction, the user id and `notify`. It returns nothing or `{channel}`. Throwing `MutationRejected`, or an error `translateRejection` maps to a code, rejects that one mutation; any other error aborts the whole batch.
- A **loader** receives identities, the transaction, the user id and the channel that asked. It returns one row or `null` per identity, in order. `null` means "not visible or deleted" and is delivered as a delete; a missing entry or `undefined` is a defect.
- `authenticate(request)` returns the user id or null. Handlers and loaders own application authorization; the framework does not enforce channel-level policy ([#22](https://github.com/zanminwang/ahead/issues/22)).
- The application also owns unique and identity constraints on the server, child deletion (`onTargetDelete` is a client-side cascade), and one local database per signed-in user; the backend is TypeScript on Node only, and prerequisite arguments are `self` only. These accepted limits are stated for authors in [What your backend owns](../../../../website/docs/backend/api.md#what-your-backend-owns).

## 5. Building Block View

Startup validates the compiled config and requires a handler for every retained mutation version (keys `name` and `nameV<n>`) and a loader for every model; otherwise `createBackend` throws.

At runtime the host function shapes handler input from the engine's decoded arguments: a create slot becomes `{…identity, …data}`, an update becomes `{identity, patch}`, a delete becomes `{identity}`; list slots are arrays and optional slots may be `null`. Each value is tagged with its record reference so `notify` accepts it.

A per-transaction **session** tracks every host callback promise. It records the first failure, refuses to let the transaction commit while callbacks are unfinished or failed, and snapshots the set of published channels around each mutation's savepoint so a rejected mutation wakes nobody ([Notify](engine/notify.md)). `bindTransaction(tx)` exposes the same machinery to application code that publishes outside a push.

Code: the `Host` trait in [server/lib.rs](../../../../crates/server/src/lib.rs); `createBackend`, `host`, `Session` in [server/index.mts](../../../../packages/server/index.mts). The simulation implements the same operations in memory in [crates/sim/src/host.rs](../../../../crates/sim/src/host.rs).

## 6. Runtime View

**Choosing the checkpoint.** While a handler runs, its `notify` calls are buffered. After it returns they are published in order, and the handler's settlement channel is decided: the returned `{channel}` if it names a notified channel, otherwise the single notified channel. No notified channel, several without a choice, or a returned channel that was not notified is a framework error that aborts the batch; it is never turned into a rejection, even by `translateRejection` (guarantee A4).

**Rejection versus failure.** A rejection is a value: the engine rolls back that mutation's savepoint and continues with the next. Every other error propagates out of the host callback and fails the outer transaction, so the whole batch, its publications and the client row roll back together (guarantee P6). Loaders follow the same rule: a defective result aborts the pull rather than advancing the client's cursor past bad data.

## 10. Quality Requirements

- **The checkpoint is the notified channel; ambiguity or silence aborts the batch and bypasses `translateRejection`** (guarantee A4). Evidence: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `checkpoint is the single notified channel; several need an explicit choice; none is an error`, `checkpoint errors bypass translateRejection and abort the batch instead of settling as a rejection`.
- **A rejection rolls back only its mutation; any other error rolls back the batch** (guarantee P6). Evidence: `explicit rejection rolls back only mutation and its publication`, `unknown error rolls back entire batch including earlier effects and client claim`, `registered translator rejects one mutation; malformed translator code aborts transaction`.
- **Loader defects abort the pull; `null` is a delete, `undefined` is a defect.** Evidence: `loader defects abort pull instead of silently advancing its cursor`, `undefined loader entries remain defects and never become tombstones`.
- **Unawaited or failed callbacks prevent commit.** Evidence: `pending unawaited publication prevents outer transaction commit`, `external transaction binding retains swallowed publication failure until its completion gate`.
- **Arguments decode known fields and ignore unknown ones; disallowed patches and binding mismatches have stable codes.** Evidence: [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs).

Tests read, not executed.

## 11. Risks and Technical Debt

**Technical debt: the host operation set is an untyped string contract implemented three times** (the TypeScript host, the simulation host, the test host). Adding an operation or a field is a manual three-way change with no shared definition.

**Accepted limitation.** A loader must return exactly the schema's fields: identity fields may be present, an absent nullable field reads as `null`, an absent non-nullable field or any extra property fails normalization and aborts the pull with a 500. Evidence: `normalize_state` in `process_pull`; the loader-defect test above. Documented for authors under [Loaders](../../../../website/docs/backend/api.md#loaders).
