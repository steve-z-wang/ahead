# otter-sync Rust Rebuild Implementation Plan

> Historical design record (2026-09-10): status statements and proposed APIs below reflect the original planning stage. See [implementation evidence](../../implementation-progress.md) for the current delivered scope and verified limitations.

> **For agentic workers:** Use `superpowers:executing-plans` to execute the accepted milestone task-by-task. Do not start runtime implementation from this proposal until the architecture decisions are reviewed. No sub-agent work is required. Checkboxes track future implementation, not work completed while writing this plan.

> Current implementation scope: preserve the reference implementation's logic. New record revisions, cross-channel arbitration, and other behavioral changes belong in [Next things](../../next-things.md), outside the milestones below. Naming follows [Concepts and naming](../../architecture/concepts-and-naming.md).

**Goal:** Deliver otter-sync from scratch with a shared Rust protocol and state machine, while preserving natural Dart/TypeScript business interfaces and user control of transactions.

**Architecture:** The Rust client/server runtimes share schema, wire format, and operation semantics. The host executes business handlers/loaders, persistence within transactions, and network I/O through typed ports. The first complete round trip uses Dart native, Rust SQLite, a Node binding, and Prisma/PostgreSQL.

**Tech Stack:** Rust workspace; SQLite; PostgreSQL; Node/TypeScript; Dart. NAPI-RS, flutter_rust_bridge, and rusqlite are spike candidates; record actual versions in the lockfile/toolchain after build verification. Correctness must not depend on unadapter.

## Global Constraints

- The project name is `otter-sync`; keep GitHub private; do not automatically publish packages.
- The user owns the backend transaction; the framework uses only persistence bound to that transaction.
- Publish must specify channels explicitly; introduce neither ambient channels nor a mandatory one-to-one channel/model mapping.
- Shared algorithms belong in Rust; SDKs must not implement ACK settlement, record conflict handling, or replay independently.
- The user authorized end-to-end execution of this plan on 2026-09-10; see [implementation progress](../../implementation-progress.md) for implementation and verification status.
- The old reference source remains on main and in historical commits; the user authorized deleting the old implementation on the new branch. Do not change Oasis, empty actual client queues, or modify production databases.
- All new tests use temporary SQLite databases and isolated Postgres created during this effort; they must not read the production DATABASE_URL.
- Resolve major open protocol questions through scenarios first; refine each subsequent milestone into executable tasks separately, without inventing complete code to conceal unresolved designs.

---

## 1. Reading Order and Working Directory

1. Read the [architecture proposal](../specs/2026-09-10-rust-core-design.md) first.
2. Use the [logic coverage table](../specs/2026-09-10-existing-logic-audit.md) to check for omissions.
3. Follow this plan's gate order; do not begin by porting the compiler from scratch.

Current implementation worktree: `/Users/stevewang/Github/local first state/.worktrees/rust-rebuild`, branch `codex/rust-rebuild`. The user authorized implementation from scratch and removal of old code on this branch; the old implementation is preserved on main/in reference commits. Directory boundaries follow [Code organization](../../architecture/code-organization.md).

The following paths are relative to that worktree's root and will be created incrementally during implementation.

```text
Cargo.toml                         workspace, created with the first Rust test
rust-toolchain.toml                pin the toolchain after the spike passes
crates/core/src/               schema, value, identity, operation, protocol
crates/client/src/             projection, queue, channel, settlement, query
crates/server/src/             mutation, publish, load, host ports
crates/sqlite/src/             local DB actor/session/storage
bindings/node/src/               Node binding
bindings/dart/src/               Dart binding
crates/compiler/src/           later compiler migration
packages/server/src/              TypeScript facade / host dispatcher
packages/persistence-prisma/src/   transactional Postgres adapter
packages/nest/src/                decorators / provider discovery
packages/dart/                    Dart facade
packages/client-js/               later JS/browser facade
examples/rust-round-trip/          standalone complete example
fixtures/protocol/              shared wire/schema vectors
fixtures/scenarios/                human-readable interleavings and expected states
integration/                      real DB / bridge / E2E
```

Do not scaffold all packages at once merely because their directories are listed. Create each crate/package with its first verifiable deliverable. The Rust runtime reads only generic schema metadata; it neither generates nor links business model types. The code organization document defines an acceptance test for adding a model without recompiling Rust.

## 2. Overall Phases and Exit Criteria

| Phase | Deliverable | Evidence required before the next phase |
|---|---|---|
| M0 Decisions and bridge feasibility | Align key semantics; two minimal spikes for Node transactions and Dart SQLite | Same-transaction rollback, duplicate requests, timeouts, and disposal are observable and verifiable |
| M1 Minimal complete round trip | UpdateEntry, one channel, real business tables, durable queue, ACK/pull | Offline edits, restart, out-of-order ACKs, rejection, and lost responses all pass |
| M2 Existing multi-channel behavior | Independent cursors, claims, dynamic subscriptions, Move, multiple checkpoints | Matches reference behavior; existing ordering limitations are explicitly documented; no revisions introduced |
| M3 Existing advanced client behavior | Cascade, companion, dependencies, readiness, query/watch, batch | Tests cover every runtime row in the coverage table; all intentional differences are explicit |
| M4 Compiler and SDK developer experience | Rust compiler, Dart/TS types, Nest decorators, migration contracts | Generated code contains no algorithms; historical mutations can replay; type misuse fails compilation |
| M5 Platforms and public release preparation | Dart mobile, Node deployment, JS/Web verification, documentation, standalone examples | Installation works on a clean machine; recovery/storage boundaries are explicit; license decision is complete |

Do not convert these phases into unverified precise schedules. M0 bridge and transaction results determine whether the implementation approach needs adjustment later.

## 3. M0: Prove the Riskiest Boundaries First

### Task 0.1 — Turn Key Design Decisions into Reviewable Scenarios

**Files:** `fixtures/scenarios/transaction-boundary.md`, `fixtures/scenarios/settlement-order.md`, `fixtures/scenarios/channel-overlap.md`.

**Input:** Sections 7/9/10 of the design and the reference implementation. **Output:** Fixed scenarios for existing behavior, on which later tests will be based.

- [ ] Write expected database states for the following event sequences before implementing code.
- [ ] Fix expectations for batch transactions, per-mutation savepoints, batch receipts, and sequence/hash deduplication.
- [ ] Preserve existing wire fields, integer ranges, and deletion representation; defer recordRevision, decimal strings, and epoch.
- [ ] Commit the confirmed documents separately as the implementation baseline.

Scenario A: Within one batch, M1 succeeds and the M2 handler encounters an unknown error; all business writes, receipts, and publications for the entire batch roll back. If M2 is an explicit business rejection, roll back only M2's savepoint; the batch may commit M1's writes and M2's rejection result. Retries follow existing batch receipt rules.

Scenario B: base.text=A, M1→B, M2→C; M1's ACK requires channel:11, but channel:10 arrives before 11; visible text remains C throughout. Settle according to existing batch checkpoints and accepted-prefix rules; M2 remains pending until its conditions are met.

Scenario C: The same record is supplied by channels A/B simultaneously. Fix the outcomes of claim creation, null releasing the current claim, release of the last claim, and authority cascade according to the reference implementation; document the limitation that delayed responses may overwrite newer content. Record revision arbitration and the new deletion protocol belong in Next things.

### Task 0.2 — Connect the Node Bridge to a Real Prisma Transaction

**Create:** `bindings/node/src/transaction_probe.rs`, `packages/persistence-prisma/src/transaction-session.ts`, `integration/node/transaction-bridge.test.ts`, `integration/node/schema.prisma`.

**Interface shape (spike only, not the official SDK):**

```ts
type TxProbe = {
  writeFrameworkRow(): Promise<void>;
  readFrameworkCount(): Promise<number>;
};
// Rust calls the host callback and awaits all Promises; this returns before the user commits.
declare function runRustProbe(host: TxProbe): Promise<{ observed: number }>;
```

Acceptance test body:

```ts
await expect(prisma.$transaction(async tx => {
  await tx.businessProbe.create({ data: { id: 'rollback-case' } });
  const result = await runRustProbe({
    writeFrameworkRow: async () => {
      await tx.frameworkProbe.create({ data: { id: 'rollback-case' } });
    },
    readFrameworkCount: () => tx.frameworkProbe.count(),
  });
  expect(result.observed).toBe(1);
  throw new Error('force rollback');
})).rejects.toThrow('force rollback');
expect(await prisma.businessProbe.count()).toBe(0);
expect(await prisma.frameworkProbe.count()).toBe(0);
```

- [ ] Set up isolated Postgres, two probe tables, and a Node test harness; first verify that this assertion detects an implementation that incorrectly uses the global client.
- [ ] Implement the Rust→JS async callback→Rust return chain; do not use a separate Rust database pool.
- [ ] Add callback rejection, Rust errors, ORM timeouts, runtime disposal, and multiple concurrent transactions; different handles must not write into each other's transactions.
- [ ] Calling a retained host handle after its transaction ends must return `transaction_closed`, without any database operation.
- [ ] Test that the HTTP layer never produces an accepted ACK when the outer commit fails.
- [ ] Record callback count, serialized bytes, and bridge duration per mutation; do not claim Rust is faster based on microbenchmarks.
- [ ] Pin working binding/runtime versions and commit.

**Run target:** `node --test integration/node/transaction-bridge.test.mjs` (provide test-source build steps together with the harness). Do not install the full product dependency set; isolate bridge failures first instead of bypassing them with independent transactions.

### Task 0.3 — Dart ↔ Rust SQLite Transaction Session

**Create:** `crates/sqlite/src/session.rs`, `bindings/dart/src/api.rs`, `integration/dart/transaction_bridge_test.dart`.

**Interface contract:** Open runtime; begin session; query/apply within the session; commit/rollback; watch committed changes; close. Each session must have a unique handle and terminal state.

- [ ] Test that writes are readable within the session but invisible to watchers outside it before commit; rollback restores the database.
- [ ] Test that an outer direct write plus a failed inner mutation savepoint rolls back only that mutation; the outer transaction can still commit.
- [ ] The Rust worker owns SQLite; Dart Futures do not block the UI isolate.
- [ ] Receive one consistent result after commit; rollback emits no intermediate results; close terminates watchers.
- [ ] Reopening the process reads committed rows; uncommitted sessions leave no partial mutations.
- [ ] Record integer/null/bytes/Unicode/error behavior across the binding and fix the first set of ABI vectors.

**Run target:** `dart test integration/dart/transaction_bridge_test.dart`; the harness's pubspec defines the actual package/test paths. Use temporary file databases, rather than testing only an in-memory reducer.

**M0 decision:** If either bridge cannot reliably preserve lifecycle and transaction semantics, pause expansion. The binding mechanism may change (for example, suspend/resume), but the atomicity promise must not weaken. Continue only after documenting the architecture adjustment.

## 4. M1: The First Useful Complete Round Trip

First example: two viewers share one Book channel; one Entry business table; an UpdateEntry named mutation; a Dart native client with local SQLite. Defer media, Move, compiler rewriting, and browsers.

### Task 1.1 — Shared Value/Identity/Protocol Kernel

**Create:** `crates/core/src/{value,identity,operation,protocol,error}.rs`, `crates/core/tests/wire_vectors.rs`, `fixtures/protocol/`.

**Output:** Generic record identity, batch envelope/receipt, channel checkpoint, pull page/change, and typed errors. Use the reference protocol's concrete fields without redefining their meanings; internal Rust type names are not wire field names.

Extract real JSON fixtures from the reference implementation for success, rejection, duplicate requests, and invalid input. Do not invent protocol-v2 examples; map new API names to old wire fields at the boundary.

- [ ] Fix counter ranges, canonical hash, unknown field/version handling, UUID, datetime, and patch absent/null behavior.
- [ ] Write golden vectors and rejection vectors first: negative cursors, overflow, duplicate keys, invalid floats, and channel mismatch.
- [ ] Implement codec/normalization; unit tests and Node/Dart ABI tests read the same vectors.
- [ ] Commit the kernel and vectors; do not duplicate parsing rules in SDKs.

**Verification:** `cargo test -p otter-core`; also run value tests for both M0 bindings.

### Task 1.2 — Local Apply/Replay and a Durable Queue

**Create:** `crates/client/src/{projection,queue,mutation}.rs`, `crates/sqlite/src/{schema,client_store}.rs`, `crates/client/tests/optimistic_replay.rs`.

**Input:** Core operations and the M0 ClientStore session. **Output:** Apply visible state + base + durable pending intent within one SQLite transaction.

- [ ] Test base A→enqueue B→visible B; after reopening, B remains visible and the queue still contains M1.
- [ ] Test that M1 changes text while the remote side changes another field; replay overwrites only fields changed by M1.
- [ ] Test create/update/delete, absent/null, and multiple mutations on the same row; failure leaves neither queue-only nor main-only state.
- [ ] Implement the sparse base and reducer; do not depend on external callbacks to replay business code.
- [ ] Assign different fates to direct local writes and mutation writes to prevent accidental transmission of local operations.
- [ ] Commit the SQLite schema and tests; verify database contents instead of merely asserting that internal functions were called.

**Verification:** `cargo test -p otter-client --test optimistic_replay`, `cargo test -p otter-sqlite`.

### Task 1.3 — Server Persistence and Explicit Publish

**Create:** `crates/server/src/{ports,publish}.rs`, `packages/persistence-prisma/src/{index,publication,receipt,snapshot}.ts`, `integration/postgres/publish.test.ts`.

**Input:** A transaction-bound host session. **Output:** Per-channel publication positions persisted in the same transaction.

- [ ] Create namespaced framework tables and migrations: clients/receipts, channel heads, and compacted invalidations; do not create record revision tables in this effort.
- [ ] Test that concurrent publications to the same channel receive distinct monotonic positions; rollback leaves no invalidation/head increments.
- [ ] Test that different channels have no framework-wide global lock; publications of one record to multiple channels are recorded independently against each channel's head and invalidation.
- [ ] Test explicit failure on counter exhaustion; duplicate identities/channels do not cause repeated writes after normalization.
- [ ] Implement snapshot reads; simulate concurrent updates and verify that head/invalidation/state satisfy the reference read contract; document insufficient isolation guarantees for separate review.
- [ ] Port existing commit wake / catch-up behavior; test hints and service restart; document external-transaction notification gaps first, without adding new polling semantics by default.
- [ ] Commit the adapter and real Postgres tests.

**Verification:** The package provides `npm run test:integration -- publish`; the harness creates/destroys a dedicated database. Create this script in the task; do not assume it exists in the old server package.

### Task 1.4 — Business Handlers and Durable Receipts

**Create:** `crates/server/src/{mutation,receipt}.rs`, `packages/server/src/{mutation-context,dispatch}.ts`, `integration/postgres/mutation-receipt.test.ts`.

**Input:** Batch envelope, typed dispatcher, and bound persistence. **Output:** A batch receipt containing mutation acceptance/rejection results, sendable only after the outer commit succeeds.

- [ ] Test that two concurrent requests with the same batch sequence/hash execute the business callback only once; the same key with a different hash conflicts.
- [ ] Test that failure in any business write/publication/receipt step rolls everything back; catching a publication error must not let the user obtain a valid completion and commit an accepted receipt.
- [ ] Test that explicit rejection rolls back the current mutation through a savepoint and is included in the batch receipt; unknown exceptions roll back the entire batch.
- [ ] Test that no ACK can be sent before the outer transaction finishes; if commit succeeds but the response is lost, retry returns the existing receipt.
- [ ] Test that business rejection and unknown exceptions across two mutations match the original behavior in Task 0.1.
- [ ] The wrapper returns a branded completion; an unbound transaction, incomplete callback, or closed transaction must fail.
- [ ] Commit runtime/SDK/tests; keep business handlers in TS.

**Verification:** `cargo test -p otter-server` and mutation-receipt integration against a real database.

### Task 1.5 — Loader, Pull, and Settlement

**Create:** `crates/server/src/loader.rs`, `crates/client/src/{pull,settlement}.rs`, `packages/server/src/loader.ts`, `crates/client/tests/settlement_orders.rs`.

**Input:** Snapshot port, loader dispatcher, and receipt/cursor. **Output:** Authoritative pages and client apply/settle behavior using the existing per-change rules.

- [ ] Loaders read in batches by model, preserving the existing identity alignment, full state/null, and prepareForViewer contracts.
- [ ] Port existing settlement channel selection and required checkpoints; design stricter witness coverage separately.
- [ ] Test both ACK→page and page→ACK orders; restarting at every durable boundary yields the same result.
- [ ] Test existing decoder/canonical apply failure classifications and per-change skip/cursor advancement; explicitly document risks and expected outcomes instead of changing to whole-page rollback.
- [ ] Test M1/M2 ordering on the same row, server normalization, server deletion, and rebuild after rejection.
- [ ] Test repeated/empty/gapped pages, cursor-ahead, and late stale responses.
- [ ] Clean up sparse before-images/queues after success, with correct base state for remaining mutations.

**Verification:** `cargo test -p otter-client --test settlement_orders`, with assertions reading back from SQLite.

### Task 1.6 — SDKs and a Real Example

**Create:** `examples/rust-round-trip/{README.md,compose.yaml}`, `examples/rust-round-trip/server/`, `examples/rust-round-trip/client/`, `integration/e2e/round-trip.test.ts`.

- [ ] Provide the application's own Prisma transaction, a plain-function handler, and a loader; do not depend on Nest yet.
- [ ] The Dart facade provides typed read/watch/mutate; transactions and operations go through the Rust bridge.
- [ ] Mount HTTP/WS on the same example Node server; Rust handles protocol bytes.
- [ ] Automated scenario: initial pull→offline edit→close and reopen→go online→lose one ACK→retry→wait for pull→final queue/base cleanup.
- [ ] Second scenario: the server rewrites text; third scenario: the server rejects; actual UI/local query output must reflect the correct result.
- [ ] Provide scripts that start only this example's resources and remove only containers/volumes they created; no production account is needed.
- [ ] Document exact installation, generation, build, run steps, and expected output in README; execute the full flow once from a clean directory.

**M1 acceptance matrix:**

| Failure point | Required observation |
|---|---|
| Crash before local commit | No partial queue/visible write |
| Offline after local commit | Optimism and the same mutation ID survive reopening |
| Server receipt write fails | Business writes and publication both roll back |
| ACK lost after server commit | Retry does not repeat business execution |
| ACK arrives first | Wire optimism remains until the checkpoint |
| Pull arrives first | Settlement can use the durable cursor as soon as ACK arrives |
| Decode/apply failure | Verify per-change skip/cursor behavior by reference failure classification; do not claim improved safety |
| Explicit rejection | Mutation operations roll back completely; the rejection record is readable |
| Close/log in again | Old session callbacks do not write to the new database |

M1 is only a verifiable alpha core; it does not establish replacement of all old capabilities.

## 5. M2: Preserve Existing Multi-Channel Behavior

**Files:** `crates/client/src/{membership,channel,settlement}.rs`, `crates/server/src/{publish,loader}.rs`, `integration/e2e/channel-overlap.test.ts`.

- [ ] Each channel has independent head/cursor values; numbers from different channels are incomparable.
- [ ] Port channel row claims, upsert, null release, and existing authority cascade; introduce no new deletion actions.
- [ ] Test dynamic desired channels, subscription/unsubscription, reconnection, and local transaction rollback.
- [ ] Test batch checkpoints across multiple channels, out-of-order ACK/pages, and accepted-prefix settlement.
- [ ] Extract Move and overlap scenarios from the old implementation, including actual limitations of late old responses; do not use proposed revision behavior as assertions for this effort.
- [ ] Preserve existing authorization, prepareForViewer, and identity alignment semantics.
- [ ] Stronger content version guarantees, the remove/delete distinction, permission recovery, and GC belong in Next things.

**Exit criteria:** Scenarios are behaviorally equivalent to the reference implementation and limitations are explicit; do not claim new ordering protection merely from sharing a Rust runtime.

## 6. M3: Complete Client Behavior and Performance

**Files:** `crates/client/src/{dependencies,readiness,cascade,companion,query,lifecycle}.rs` and corresponding `tests/`; `packages/dart/`, `integration/e2e/`.

Deliver each item in this order, first porting independent expectation tests, then implementing:

1. Shared fate for multi-operation mutations / local direct writes / companions; accepted companions advance the local base correctly.
2. Cascade graph main+before scans, recovery from rejection, and interleavings of ancestor mutations with child edits.
3. Lifecycle dependencies and business sequence; independent tasks overtaking others; differences in propagation of prerequisite rejection.
4. Prerequisite ready/failed/retry, cancellation, user retry/drop, and reference cleanup; the host executes upload tasks.
5. Durable rejection inbox, acknowledge, and derived per-record status.
6. Durable desired channels, rollback of optimistic subscribe/unsubscribe, and existing read rules required for pending settlement.
7. Typed queries, relation/inverse, sorting/null/limit, watch initial value/deduplication/commit-only/close; write protection for read-only SQL.
8. Batch envelope, byte/count limits, frozen retries, background lifecycle, auth refresh, backoff/jitter, and bounded queues.

**Verification:** Assign responsibility row by row against the coverage table; randomized-interleaving property tests + an independent oracle. Avoid per-field bridge callbacks for each mutation/page; record database round trips, p50/p95, and replay costs with queues of 10/1000 entries. Optimizations must not change durable boundaries or query visibility.

## 7. M4: Compiler, API, and Nest

**Files:** `crates/compiler/src/{syntax,semantic,history,emit}/`, `packages/nest/src/{decorators,discovery,module}.ts`, `fixtures/schema-evolution/`.

- [ ] First normalize existing compiler output into Rust runtime descriptors and remove dependencies on generated algorithms.
- [ ] Incrementally port the parser, semantic analysis, relation graph, slot binding, and version history; old/new compilers produce semantically equivalent results for the same valid definitions.
- [ ] Port existing schema compatibility fences; test model/field deletion, new fields, and old-client reads; broader identity/type/nullability fences belong in Next things.
- [ ] Generate Dart/TS operation builders and backend typed input, preserving absent/null and version snapshots.
- [ ] Business-oriented input facades explicitly map underlying slots; arbitrary host callbacks must not become implicit dependencies of Rust replay.
- [ ] Add Nest `@Handles` / `@Loads` + provider discovery; interfaces check static types, and decorators record runtime metadata.
- [ ] Test startup failures: duplicate handlers, missing model/version registration, and incorrect descriptors; plain-function registration still supports every capability.
- [ ] Mount the HTTP adapter on the user's server; standalone listen is not a mandatory second service.

**Exit criteria:** A business developer can integrate a model, handler, loader, and publish by reading only the example; all generated-algorithm fence and ABI tests pass. The new compiler does not depend on Oasis.

## 8. M5: Platforms, Migration, and Public Release Preparation

- [ ] Dart: build/load/restart smoke tests for macOS development, iOS simulator/device, and Android emulator/device; an exact platform support table.
- [ ] Node: actual native artifact installation, production builds, and container startup on macOS and Linux; base the platform matrix on verification, not compilation success alone.
- [ ] JS/Web: independent spikes for WASM and browser SQLite/OPFS or host storage; multi-tab single-writer, workers, quota, shutdown, and recovery. Mark unsupported until verified.
- [ ] Non-TypeScript backends: provide a standalone Rust host example before considering SQLx/SeaORM; do not promise automatic conversion from ORM A's transaction to ORM B's transaction.
- [ ] Old storage/wire migration: choose draining or a dedicated migrator, protecting unsent/frozen/accepted/companion/local-only state; do not delete old databases by default.
- [ ] Protocol version compatibility table, breaking changes, failure recovery guide, and capacity/retention documentation.
- [ ] Separate CI into core, binding, adapter, E2E, and package smoke tests; retain only conformance tests with independent value, without duplicating the entire algorithm test suite.
- [ ] The author selects a license; audit distributed files; make source public first, and advance registry publication within a separately explicit scope.

## 9. Test Mapping

| Old conformance suite | New test responsibility |
|---|---|
| model-generation | Rust compiler golden/type compilation/history; typed SDK smoke tests |
| server-client-protocol | Shared Rust codec vectors + ABI value fidelity + cross-version fixtures |
| client-storage-contract | Rust ClientStore/SQLite transaction/watch/savepoint tests |
| server-persistence-contract | Real Postgres adapter atomicity/locking/snapshot tests |
| end-to-end-sync | Selected real SDK→network→Rust→businessDB→localDB journeys |

Historical wire vectors remain because the protocol's external commitments still exist. Shared code cannot detect the same mistake on both sides, so property oracles and final database state assertions remain independent of the production reducer.

## 10. Plan Self-Check and Concrete Choices Before Implementation

- This plan covers compiler, client, server, protocol, storage, SDK, infrastructure, examples, migration, and release preparation.
- The first round trip does not depend on decorators, the complete compiler, or every ORM, avoiding peripheral developer-experience work before transaction feasibility is proven.
- Per-mutation receipts, separating remove/delete, not skipping pull failures, and recordRevision are all deferred; preserve original behavior for now.
- Naming changes affect only new APIs and internal symbols; do not bulk-rename old wire/storage fields.
- Every open question has an explicit responsible phase, acceptance scenario, and release gate.
- When implementation next begins, confirm M0's default architecture choices first, then execute tasks one by one; implementation is already authorized, and progress should reflect verification results.

## Implementation evidence

This document preserves the original roadmap and its broader platform/release checklist. The current implementation and exact verified versus unverified coverage are recorded in [implementation-progress](../../implementation-progress.md); unchecked roadmap items must not be read as verified. Dedicated performance diagnostics live in `integration/rust/examples/capacity.rs`; host CI reuses `scripts/test.sh`. Public release, browser runtime, original-database importing and additional platform support require their own evidence.
