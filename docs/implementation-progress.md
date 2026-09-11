# First version implementation progress

The user approved end-to-end implementation on 2026-09-10. Keep the accepted architecture, naming and reference behavior. This ledger records evidence, not projected completion.

- [ ] M0: protocol fixtures, Node transaction bridge, Dart SQLite session.
- [ ] M1: persistent optimistic client, Rust server, real database adapter, SDK/network round trip.
- [ ] M2: reference multi-channel behavior.
- [ ] M3: remaining client behavior and compatibility coverage.
- [ ] M4: Rust compiler, generated Dart/TS APIs, backend registration.
- [ ] M5: runnable examples, build/test automation, supported-platform evidence.

No public release or package publishing is authorized by this implementation step. Additional record revision and behavior changes stay in Next things.

## Verified during implementation

- Real Node/N-API/Prisma transaction probe: 12 tests (commit, rollback, savepoints, late/caught failure gates).
- Rust core protocol vectors: 10 tests; Rust server argument contracts: 5 tests.
- Rust client with actual SQLite: 24 tests, including restart, frozen retry, ACK/Pull interleavings, multi-channel claims, companion cascade, lifecycle/sequence/prerequisite policies, byte limits, explicit replay migration, CAS stale writers.
- Rust common native command boundary: 2 tests; real Dart native client transaction/restart test passes.
- Node client callback boundary: 5 deterministic tests for ordered commands, forgotten awaits, savepoint failures/overlap and nonfinite JSON.
- Real Rust server through Node/Prisma/PostgreSQL: 18 tests (before live transport extension).
- Real Node HTTP + PostgreSQL + Node/Dart SQLite E2E passed, including lost ACK retry and local writes during delayed network response.
- Compiler: 9 tests and generated TypeScript positive/negative checks, Dart analysis/runtime, both generated facades calling actual native Rust. Reference `.model` corpus compiles.

Active: Rust live transport and committed wake delivery; full runtime query APIs, SDK lifecycle, Rust-to-Rust scenarios, backend decorators and startup registration checks, example/documentation/build gates. These entries are not a release-complete assertion. Test numbers record the last verified run and will be superseded by final validation.

## Later verification and review fixes

- Rust client now has 27 actual SQLite tests; shared connection driver has 2 lifecycle/backoff tests. `integration/rust` exercises 64 deterministic ACK/Pull/restart/rejection traces directly between Rust runtimes.
- Compiler now has 10 tests; generated Dart and TypeScript typed filter/order/relation accessors pass real native integration. Singular inverse keys are validated for uniqueness; Dart order enums use safe identifiers and explicit wire names.
- Node boundary suite now has 10 tests, including prerequisite failure/retry and connection cancellation. Dart has equivalent connection race tests plus native transaction tests.
- Real server suite: 22 tests, including committed live wakes, no wake before commit/after rollback, handshaking catch-up, closed sockets, native startup validation.
- Nest suite: 5 tests. Discovery now runs after provider construction; async dependencies/private fields and unsupported scoped-provider startup rejection are covered.
- Reviewed and fixed companion-cascade resurrection, missing-await transaction escape, overlapping/nested savepoint finalization, orphan readiness, live lost wakes/closed-socket recursion/early errors, invalid update capabilities, and Nest premature method binding. Targeted re-reviews found no remaining critical issue in those changes.
- Full Node/Dart HTTP E2E including background pause/resume passed after a real test exposed and fixed cancellation of an already-running sync cycle.
- Read-only SQL uses an isolated optimistic snapshot; SQL cannot access writable framework tables. Explicit additive row migration preserves frozen bytes and resets Pull cursors only once when requested.

Active now: full host gate and broad final review; independent iOS simulator smoke. Android SDK is absent from the standard host location; no Android runtime validation claimed. Broader platform matrix, original database/history importing, dedicated performance indexing, and multi-process wake delivery remain explicitly bounded rather than inferred from source compilation.
