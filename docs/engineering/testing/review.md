# Coverage review

This page summarizes the coverage review of 2026-09-14 and lists the priorities for the next testing issue. The detailed tables (behavior, existing tests, coverage, gap) live in each testing topic:

- [Schema](components/schema.md), [Protocol](components/protocol.md), [Compiler](components/compiler.md), [Client](components/client.md), [Server](components/server.md)
- [Simulation scenarios](simulation/scenarios.md), [invariants](simulation/invariants.md), [failure and recovery](simulation/recovery.md)
- [Storage and persistence](integration/persistence.md), [SDKs and bindings](integration/bindings.md), [Connection](integration/connection.md)
- [End-to-end](end-to-end.md)

## How the review was done

For each component the reviewer read its architecture document (sections 10 and 11), listed the behaviors and failure conditions, then read the setup, execution path and assertions of every test named as evidence. Coverage was judged on assertions, not names. Every observation comes from reading the code at commit `d682dd2`; no test suite was executed for this review. The one experiment cited (settlement without authority) was executed earlier on another branch and its reproduction steps are kept in [Settlement](../architecture/client/engine/settlement.md).

Three things were kept apart throughout: a **missing test** (the behavior is decided and implemented, nobody asserts it), an **implementation defect** (a test would fail today), and an **undecided contract** (writing a test now would pin an accident). Ignored tests were not counted as coverage.

## What is well covered

The Rust sync core has named scenarios for every guarantee in L, P, A and D, most of them twice: once in the simulation across client and server, once in the SQLite harness with finer assertions. The random runner checks seven invariants after every step and forces convergence every 25 steps. Protocol encoding, argument decoding, checkpoint resolution and PostgreSQL atomicity each have direct assertions. Both language clients have parallel live-session tests for handshake, catch-up, overlap, gap recovery, subscription generations, cancellation and auth refresh.

## Priorities for the next testing issue

Decisions come first, because several gaps cannot be tested without them:

1. **Undecided contracts to resolve before encoding expectations.** Settlement without authority (A3 exception) and the immediate settlement path versus A5 ([Settlement §11](../architecture/client/engine/settlement.md)); receipt-hash enforcement (C1, [Server Push §11](../architecture/server/engine/push.md)); the `backend.notify(tx, …)` shortcut that never wakes subscribers ([Notify §11](../architecture/server/engine/notify.md)); visibility of skipped changes on the SDK path ([Pull §11](../architecture/client/engine/pull.md)); greedy decoding of adjacent slots ([Mutations §11](../architecture/schema/mutations.md)). For each, a scenario that constructs the situation and records the current outcome is useful now; the assertion is written after the decision.
2. **Defects with reproductions waiting to become regressions.** [#33](https://github.com/zanminwang/ahead/issues/33) (direct write on a pending create; the random direct-write run stays ignored until fixed) and [#32](https://github.com/zanminwang/ahead/issues/32) (page from a previous subscription; the sim repro is ignored). Semantic compiler errors reporting end-of-file ([Validate §11](../architecture/compiler/validate.md)) and `Model.update<>` compiling but never succeeding have no reproduction yet.
3. **Missing tests for decided behavior, in rough order of risk.**
   - Reconciliation with a populated queue: frozen bytes unchanged after an additive change (P4, C3).
   - The no-polling consequence: push succeeds while the upgrade is refused, pending does not settle, the lane retries ([Connection](integration/connection.md)).
   - Batching bounds: the 20-mutation cap and the zero byte budget; `drop_mutation` refusing a frozen mutation.
   - HTTP status mapping: `403`, `409` (gap, overlap, unsupported version with its fields), `404`, `405`, `413`; upgrade refusals and `1011` on drain error.
   - Core value rules with no assertion: `dateTime` and `float` normalization, enum value validation, list element and nullability rules, push-batch size boundaries.
   - Compiler: determinism (compile twice), multi-file error relocation, `--initialize-mutation-history` refusals, Dart negative fixtures.
   - Dart parity: `runPrerequisites`, buffer overflow at the Dart bound.
   - Named D4 scenario with a child record following its parent across channels.
   - Serialization-failure retry in the Prisma runner.
4. **Test hygiene.** Rename the two P3 tests whose names promise clauses their bodies lack; consider splitting the single Dart client test that bundles seven clauses. Do not move tests between directories for tidiness: the SQLite-harness tests are component evidence where they are, and the query-file controller test is fine where it is.
5. **Optional invariants.** A3 and A5 have no random-run predicate; both are expressible from queue and checkpoint tables and would extend R2's reach.

## Classification notes

- Simulation is a method, not a layer: its scenarios are counted as evidence for the guarantee they assert, and the same clause often has a SQLite-harness twin with finer assertions. That duplication is deliberate and cheap; it is not flagged as redundancy.
- The PostgreSQL suite carries server *component* rules (checkpoint resolution, rejection versus failure, wake sets) because that logic lives in the TypeScript runtime and has no in-process fixture. The tables in [Server tests](components/server.md) list those rows with that caveat rather than moving them.
- The Node transaction-bridge tests exercise the original spike probe, not `createBackend`. They remain useful boundary evidence for async callbacks inside a Prisma transaction but should not be cited for production server behavior.
- A close-and-reopen is not a process interruption. R3 evidence establishes recovery at step and commit boundaries the harness can reach; a crash between commits inside one action is unreachable by construction, and a kill during a commit relies on SQLite.

## Suggested scope for the testing issue

One issue with three checklists, in this order: decisions (item 1, each linking the owning architecture section), regressions and missing tests (items 2 and 3, each naming the file it belongs in and the command that runs it), and hygiene (item 4). Record every command run and its result in the topic page; update the tables there as rows close, and keep this page as the summary.
