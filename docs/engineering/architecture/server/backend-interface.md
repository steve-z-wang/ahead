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

## 5. Building Block View

Startup validates the compiled config and requires a handler for every retained mutation version (keys `name` and `nameV<n>`) and a loader for every model; otherwise `createBackend` throws.

At runtime the host function shapes handler input from the engine's decoded arguments: a create slot becomes `{…identity, …data}`, an update becomes `{identity, patch}`, a delete becomes `{identity}`; list slots are arrays and optional slots may be `null`. Each value is tagged with its record reference so `notify` accepts it.

A per-transaction **session** tracks every host callback promise. It records the first failure, refuses to let the transaction commit while callbacks are unfinished or failed, and snapshots the set of published channels around each mutation's savepoint so a rejected mutation wakes nobody ([Notify](engine/notify.md)). `bindTransaction(tx)` exposes the same machinery to application code that publishes outside a push.

Code: the `Host` trait in [server/lib.rs](../../../../crates/server/src/lib.rs); `createBackend`, `host`, `Session` in [server/index.mts](../../../../packages/server/index.mts). The simulation implements the same operations in memory in [crates/sim/src/host.rs](../../../../crates/sim/src/host.rs).

## 6. Runtime View

**Choosing the checkpoint.** While a handler runs, its `notify` calls are buffered. After it returns they are published in order, and the handler's settlement channel is decided: the returned `{channel}` if it names a notified channel, otherwise the single notified channel. No notified channel, several without a choice, or a returned channel that was not notified is a framework error that aborts the batch; it is never turned into a rejection, even by `translateRejection` (guarantee A4).

**Rejection versus failure.** A rejection is a value: the engine rolls back that mutation's savepoint and continues with the next. Every other error propagates out of the host callback and fails the outer transaction, so the whole batch, its publications and the client row roll back together (guarantee P6). Loaders follow the same rule: a defective result aborts the pull rather than advancing the client's cursor past bad data.

## 9. Architecture Decisions

### One typed host-operation contract, owned by Rust ([#45](https://github.com/zanminwang/ahead/issues/45))

**Decision.** The Rust server crate becomes the single definition of every host operation: a `HostRequest` enum and one response type per operation, serialized to the JSON the boundary already carries. The TypeScript host, the simulation host and the test hosts implement that definition; none of them interprets free-form `{op, …}` objects any more. No wire protocol changes, business logic stays in handlers and loaders, and transaction ownership stays with the application.

**Contract (Rust, `crates/server/src/host.rs`).**

| Request (`op`) | Fields | Response type |
| --- | --- | --- |
| `claim` | `owner`, `clientId` | `Claimed { clientId, owner, sequence, receipt: Option<String> }` |
| `saveReceipt` | `owner`, `clientId`, `sequence`, `receipt` | unit |
| `head` | `channel` | `u64` |
| `scan` | `channel`, `after`, `limit` | `Vec<Invalidation { channel, cursor, model, identity, identityKey, stamp }>` |
| `publish` | `channel`, `model`, `identity`, `identityKey` | `Published { cursor, stamp }` |
| `savepoint` / `rollback` / `release` | `ordinal` | unit |
| `handle` | `name`, `version`, `arguments`, `owner`, `ordinal` | `Handled::Settled { channel }` or `Handled::Rejected { rejection }` |
| `load` | `model`, `identities`, `owner`, `channel` | `Vec<Option<Value>>` (one entry per identity) |

`HostRequest` derives `Serialize`/`Deserialize` with `#[serde(tag = "op", rename_all = "camelCase")]` and `deny_unknown_fields`; each response is a struct or enum with `deny_unknown_fields`. The engine constructs requests as enum values and decodes responses into these types, so a malformed response fails at the boundary with `host.invalid` and the field name, instead of somewhere later with `unwrap`.

**How each side consumes it.**

- *Rust engine.* `process_push`, `process_pull`, `publish` and `live` build `HostRequest` values; a small `Host` extension (`call_typed<R: DeserializeOwned>(&self, request: HostRequest) -> Result<R>`) does the serialize/deserialize once. `Host::call` keeps its `Value → HostResult<Value>` shape so existing implementers compile during the migration.
- *TypeScript host.* `packages/server/host-contract.mts` declares the request and response types (one `type HostRequest = …` union and the response interfaces) and `packages/server/index.mts` narrows on `request.op` with an exhaustive `switch`; `persistence-prisma` implements the persistence half against the same types. The file is hand-written, because the two languages have no shared code generator today.
- *Conformance fixture.* A Rust test serializes one example of every request and one valid response per operation into `fixtures/protocol/host-operations.json`. Rust checks that every request decodes back to the enum and every response into its type; a Node test feeds each request through the TypeScript host with a fake persistence and checks the produced response decodes in Rust (through the same fixture, in the persistence suite). A field added on one side without the other fails one of the two.
- *Simulation and test hosts.* `MemHost` and the `Fixed` test host match on `HostRequest` (deserialized from the `Value` they receive) and return the response types serialized, so an unknown or malformed operation is a compile error in Rust rather than an `unwrap` in a match arm.

**Consequences.** Adding an operation or a field means editing `host.rs`, the fixture and `host-contract.mts`; the Rust compiler and the two conformance tests enforce the rest. Responses that used to be tolerated loosely (a `handle` returning `{}` with no channel) become explicit `host.invalid` errors with the same abort semantics as today's "invalid handler settlement". The boundary keeps JSON strings, so no binding change is needed.

**Migration steps.** Each step is independently shippable and keeps every existing test green.

1. Add `host.rs` with the types, `call_typed`, and the round-trip fixture test; switch the engine's call sites to build `HostRequest` and decode responses. No host implementation changes yet.
2. Switch `MemHost` and the server test hosts to match on the decoded enum.
3. Add `host-contract.mts`, narrow the TypeScript host and the Prisma persistence on it, and add the Node conformance test over the fixture.
4. Update this document's §3 table and the code map to point at `host.rs` and `host-contract.mts`; remove the §11 debt entry.

**Validation plan.** `cargo test -p ahead-server -p ahead-sim --locked` for steps 1–2 (round trip, refusals of malformed responses per operation, unchanged sim scenarios); `bash integration/persistence/server/run.sh` for step 3 (the whole existing suite plus the conformance test); `npm run typecheck`.

## 10. Quality Requirements

- **The checkpoint is the notified channel; ambiguity or silence aborts the batch and bypasses `translateRejection`** (guarantee A4). Evidence: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `checkpoint is the single notified channel; several need an explicit choice; none is an error`, `checkpoint errors bypass translateRejection and abort the batch instead of settling as a rejection`.
- **A rejection rolls back only its mutation; any other error rolls back the batch** (guarantee P6). Evidence: `explicit rejection rolls back only mutation and its publication`, `unknown error rolls back entire batch including earlier effects and client claim`, `registered translator rejects one mutation; malformed translator code aborts transaction`.
- **Loader defects abort the pull; `null` is a delete, `undefined` is a defect.** Evidence: `loader defects abort pull instead of silently advancing its cursor`, `undefined loader entries remain defects and never become tombstones`.
- **Unawaited or failed callbacks prevent commit.** Evidence: `pending unawaited publication prevents outer transaction commit`, `external transaction binding retains swallowed publication failure until its completion gate`.
- **Arguments decode known fields and ignore unknown ones; disallowed patches and binding mismatches have stable codes.** Evidence: [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs).

Tests read, not executed.

## 11. Risks and Technical Debt

**Technical debt: the host operation set is an untyped string contract implemented three times** (the TypeScript host, the simulation host, the test host). Adding an operation or a field is a manual three-way change with no shared definition. The decision and migration in section 9 resolve this once implemented ([#45](https://github.com/zanminwang/ahead/issues/45)).

**Accepted limitation, worth documenting for authors.** A loader must return exactly the schema's fields; a row with extra columns fails normalization and aborts the pull with a 500. Evidence: `normalize_state` in `process_pull`; the loader-defect test above.
