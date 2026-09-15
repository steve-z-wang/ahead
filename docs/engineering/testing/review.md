# Coverage review

This is the starting point for the next testing issue. The documentation PR defines responsibilities and expected behavior; test changes follow separately. The observations below come from reading this branch's code and assertions, not a fresh test-suite run. Recheck them against the implementation revision used for that issue.

## Review process

For each component, read its contract and risks, then inspect test assertions. Record the behavior, owning document, test location, coverage gap and required scope. Distinguish a missing test from an implementation defect or an undecided contract. A test name, a fixture or a passing suite alone is not evidence for every clause.

For each overall [guarantee](../guarantees.md), identify a named scenario and any generated invariant or real-boundary check it needs. Record commands and actual results when executing them. Keep detailed findings with the owning component; this page is the cross-cutting follow-up list.

## Existing evidence and follow-up

| Area | Existing evidence | Follow-up |
| --- | --- | --- |
| Local writes (L) | [local scenarios](../../../crates/sim/tests/local.rs), [SQLite client tests](../../../crates/sqlite/tests/client.rs) | Check direct writes on pending creates and cascaded rejection. The current generated direct-write suite is ignored; do not report it as covered. |
| Push (P) | [push scenarios](../../../crates/sim/tests/push.rs), [SQLite push tests](../../../crates/sqlite/tests/push.rs) | Split assertions for lifecycle, sequence and independent work. Two P3 test names claim cases their bodies omit. Verify frozen bytes through supported schema changes with a populated queue. |
| Settlement (A) | [authority scenarios](../../../crates/sim/tests/authority.rs), [SQLite downlink tests](../../../crates/sqlite/tests/downlink.rs) | Assert overlapping pages, gaps and subscription generations. Decide state after settlement with no subscribed checkpoint; test visible records, not only pending count. Check A5 for receipt paths with no awaitable checkpoints as well as the normal prefix loop. |
| Distribution (D) | [distribution scenarios](../../../crates/sim/tests/distribution.rs), [stamp scenarios](../../../crates/sqlite/tests/stamp_scenarios.rs) | Add parent/child channel moves; distinguish content stamps, claim removal and subscription epochs. |
| Network faults (R1–R2) | [generated runs](../../../crates/sim/tests/invariants.rs), [invariant checks](../../../crates/sim/src/invariants.rs) | Map the seven implemented invariants to requirements. Finite seeded runs do not establish all guarantees; retain convergence preconditions and direct-write exclusions. |
| Recovery (L2, R3–R4) | [resilience scenarios](../../../crates/sim/tests/resilience.rs), SQLite reopen and stale-writer tests | Current simulation restarts between actions. Add or explicitly defer process-failure injection at durable boundaries, including within an action. |

## Component contracts

The former compatibility (C), developer-surface (S) and limitation (N) entries belong to these owners, rather than the overall guarantees list.

| Owner | Contract and remaining evidence |
| --- | --- |
| [Schema](components/schema.md) / [Protocol](components/protocol.md) | Field completeness, unknown-field policies, counter limits and canonical wire values. Core hash tests do not establish server enforcement. |
| [Compiler](components/compiler.md) | Deterministic output and useful diagnostics. Repeated compilation is not asserted; semantic validation currently reports EOF rather than the offending declaration. |
| [SDKs and bindings](integration/bindings.md) | Generated positive and negative type checks, value translation, transaction callback failures and lifetimes. Dart lacks negative compilation fixtures. [Shared scenarios](../../../fixtures/scenarios) are three prose READMEs, not executable cross-language scripts. |
| [Storage](integration/persistence.md) | Supported schema reconciliation, transaction isolation and durability. Current reconciliation retains extra columns, checks SQL storage types and identities, and leaves enum changes unchecked. It does not uniformly reject every unsupported schema change. Queue preservation and changed unique indexes need explicit cases. |
| [Server](components/server.md) | Unsupported handler versions must abort before handlers; the current PostgreSQL test does not assert the error code. Same-sequence retries currently return the cached receipt even if the body differs; hash enforcement remains a contract decision in [Server Push](../architecture/server/engine/push.md). |
| [Connection](integration/connection.md) | HTTP catch-up follows WebSocket acknowledgement; live delivery uses WebSocket. No HTTP polling fallback is planned. Test blocked upgrades and reconnect without treating HTTP write success as proof of downlink progress. |
| [End-to-end](end-to-end.md) | Exercise assembled TypeScript and Dart paths. Separate language round trips do not establish identical outcomes for the same operation sequence. |

Storage retention belongs to storage/persistence risks; authorization belongs to the backend interface. Direct-write overwrite behavior belongs to L4, batch atomicity to P6, and delivery preconditions to R1. They do not need a separate miscellaneous guarantees group.

## Completion of the follow-up

The next issue should produce an assertion-level coverage map, focused regression tests or explicit deferred gaps, and verified commands for each affected area. Resolve behavior questions before encoding an expectation. Update component evidence and this review as cases are completed; do not rewrite assertions merely to match an accidental implementation behavior.
