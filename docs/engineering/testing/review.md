# Coverage review

This page summarizes the coverage review of 2026-09-14. The strategy and audit are tracked in [#13](https://github.com/zanminwang/ahead/issues/13); the consolidated test-implementation checklist is [#68](https://github.com/zanminwang/ahead/issues/68). The detailed tables (behavior, existing tests, coverage, gap) live in each testing topic:

- [Schema](components/schema.md), [Protocol](components/protocol.md), [Compiler](components/compiler.md), [Client](components/client.md), [Server](components/server.md)
- [Simulation scenarios](simulation/scenarios.md), [invariants](simulation/invariants.md), [failure and recovery](simulation/recovery.md)
- [Storage and persistence](integration/persistence.md), [SDKs and bindings](integration/bindings.md), [Connection](integration/connection.md)
- [End-to-end](end-to-end.md)

## How the review was done

For each component the reviewer read its architecture document (sections 10 and 11), listed the behaviors and failure conditions, then read the setup, execution path and assertions of every test named as evidence. Coverage was judged on assertions, not names. Every observation comes from reading the code at commit `d682dd2`; no test suite was executed for this review. The one experiment cited (settlement without authority) was executed earlier on another branch and its reproduction steps are kept in [Settlement](../architecture/client/engine/settlement.md).

Three things were kept apart throughout: a **missing test** (the behavior is decided and implemented, nobody asserts it), an **implementation defect** (a test would fail today), and an **undecided contract** (writing a test now would pin an accident). Ignored tests were not counted as coverage.

## What is well covered

Named simulation scenarios cover most L, P, A and D behaviors; L2 and L3 rely primarily on the SQLite harness. Several behaviors also have finer assertions in that harness. The topic tables identify the clauses each test covers and the remaining gaps. The random runner checks seven invariants after every step and forces convergence every 25 steps. Protocol encoding, argument decoding, checkpoint resolution and PostgreSQL atomicity each have direct assertions. Both language clients have parallel live-session tests for handshake, catch-up, overlap, gap recovery, subscription generations, cancellation and auth refresh.

## Implementation priorities

Only expectations involving undecided behavior must wait for the owning decision. Independent coverage work in [#68](https://github.com/zanminwang/ahead/issues/68) can proceed:

1. **Undecided contracts to resolve before encoding expectations.** Settlement without authority (A3 exception, [#52](https://github.com/zanminwang/ahead/issues/52); the immediate settlement path now obeys A5, [#53](https://github.com/zanminwang/ahead/issues/53)); receipt-hash enforcement ([#47](https://github.com/zanminwang/ahead/issues/47), [Server Push §11](../architecture/server/engine/push.md)); the `backend.notify(tx, …)` shortcut that never wakes subscribers ([#50](https://github.com/zanminwang/ahead/issues/50), [Notify §11](../architecture/server/engine/notify.md)); visibility of skipped changes on the SDK path ([#51](https://github.com/zanminwang/ahead/issues/51), [Pull §11](../architecture/client/engine/pull.md)); greedy decoding of adjacent slots ([#54](https://github.com/zanminwang/ahead/issues/54), [Mutations §11](../architecture/schema/mutations.md)). For each, a scenario that constructs the situation and records the current outcome is useful now; the assertion is written after the decision.
2. **Defects with reproductions waiting to become regressions.** [#32](https://github.com/zanminwang/ahead/issues/32) is fixed: pages from previous subscriptions are handled and the sim reproduction is enabled. [#33](https://github.com/zanminwang/ahead/issues/33) is fixed: its five-action reproduction is a named L4 scenario and the direct-write random run is enabled. `Model.update<>` compiling but never succeeding ([#49](https://github.com/zanminwang/ahead/issues/49)) needs a focused regression with its fix. Semantic compiler errors now report the offending declaration ([#48](https://github.com/zanminwang/ahead/issues/48)); see [Compiler tests](components/compiler.md).
3. **Missing tests for decided behavior, in rough order of risk.** Closed in this round: reconciliation with a populated queue, batching bounds and the frozen-drop refusal, core value rules and batch boundaries, the named D4 parent-and-child scenario, unsupported query shapes and unclosed savepoints (see the client, schema, persistence and simulation tables).
   - Upgrade refusals (`401`, `503` while closing). The HTTP status table (`403`, `409` gap/overlap/unsupported version with its fields, `404`, `405`, `413`) and `1011`/`1002` live close codes are now asserted in [runtime.test.mjs](../../../integration/persistence/server/runtime.test.mjs).
   - Compiler: Dart negative fixtures. Determinism, multi-file error relocation and `--initialize-mutation-history` refusals are covered in [compiler/tests/cli.rs](../../../crates/compiler/tests/cli.rs).
   - Serialization-failure retry in the Prisma runner.
4. **Test hygiene.** The two P3 tests are renamed to what they assert (`lifecycle_dependency_waits_for_parent_ack`, `schema_sequence_relationship_freezes_dependent_with_its_predecessor`); consider splitting the single Dart client test that bundles seven clauses. Do not move tests between directories for tidiness: the SQLite-harness tests are component evidence where they are, and the query-file controller test is fine where it is.
5. **Optional invariants.** A3 and A5 now have random-run predicates (`batches wait for their checkpoints`, `batches settle in sequence order`); see [Invariants](simulation/invariants.md) for what each exempts.

## Classification notes

- Simulation is a method, not a layer: its scenarios are counted as evidence for the guarantee they assert, and the same clause often has a SQLite-harness twin with finer assertions. That duplication is deliberate and cheap; it is not flagged as redundancy.
- The PostgreSQL suite carries server *component* rules (checkpoint resolution, rejection versus failure, wake sets) because that logic lives in the TypeScript runtime and has no in-process fixture. The tables in [Server tests](components/server.md) list those rows with that caveat rather than moving them.
- The Node transaction-bridge tests exercise the probe-only addon build (`--features probe`), not `createBackend`. They remain useful boundary evidence for async callbacks inside a Prisma transaction but should not be cited for production server behavior; [SDK and binding tests](integration/bindings.md) lists which of their clauses are unique.
- A close-and-reopen is not a process interruption. R3 evidence establishes recovery at step and commit boundaries the harness can reach; a crash between commits inside one action is unreachable by construction, and a kill during a commit relies on SQLite.

## Tracking implementation

Use [#68](https://github.com/zanminwang/ahead/issues/68) as the single checklist for missing tests and test hygiene. Code defects and contract decisions stay in their owning issues above; link their regression PRs rather than recreating the work. Record commands and actual results in the topic tables, mark blocked or deferred items explicitly, and keep this page as the summary.
