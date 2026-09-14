# Testing strategy

This page describes the planned test organization. The simulation and conformance runners below are proposed work; see [running the current tests](testing.md) for commands available in this checkout. Simulation implementation is tracked in [PR #34](https://github.com/zanminwang/ahead/pull/34).

[guarantees](guarantees.md) says what the framework promises and where each promise is proven. This page says how the test suite is organized to produce those proofs, and how to add one.

## Principle

Tests live where the logic lives. Thin layers above only prove they translate correctly; they never re-test the logic.

Almost all logic is in the Rust crates: optimistic writes, the queue, settlement, rejection, checkpoints, deduplication, stamps and claims. Everything else, the SQLite adapter, the Prisma adapter, the TypeScript and Dart clients, the HTTP server, is a translation or persistence layer over that logic. The suite is shaped accordingly.

| Layer | Logic | Proof style | Share |
| --- | --- | --- | --- |
| Rust crates | almost all | simulation over random operation sequences with invariants after every step; named Given/When/Then scenarios; unit tests for pure functions | about 80% |
| Adapters and bindings | little | contract tests: written is read back, rollback takes effect, commands translate, lifecycles do not leak | about 15% |
| End to end | none, wiring only | one smoke flow per language | about 5% |

## Layout

```
crates/
  core/tests/         wire encoding, normalization                   C1 C2
  server/tests/       argument decoding, refusal codes, checkpoints  C4, server half of A4 P6
  client/tests/       policies, query IR, connection state machine   pure units
  sqlite/tests/       store contract, DDL reconciliation             L2 L3 R3 R4 C3
  compiler/tests/     golden output, negative input, history, CLI    S1 S2
  sim/                deterministic simulation                       L P A D R (primary proofs)
    src/              harness: clients, server, network, oracle, actions, invariants
    tests/
      invariants.rs   random sequences, every invariant after every step   R2
      local.rs        L1 L4 L5 named scenarios
      push.rs         P1–P6
      authority.rs    A1–A5
      distribution.rs D1–D6
      resilience.rs   R1 R3
    examples/
      capacity.rs     performance diagnostic (#12), not a test

integration/
  persistence/        Prisma adapter against real PostgreSQL          server half of P1 P6 A4
  bindings/           TypeScript and Dart boundary tests              translation only
  conformance/        one script, three clients, identical state      S3
  e2e/                one smoke flow per language                     S4
  platform/           device smoke (iOS simulator), manual

fixtures/
  schemas/            shared schema descriptors
  protocol/           shared wire boundary cases                      read by C1 tests
  scenarios/          conformance scripts and expected state          read by S3 runner
```

`cargo test --workspace` is the local subset and requires no external services. Once the simulation crate lands, it will run in this subset too. The target runtime is under a minute. `scripts/test.sh` adds `integration/` and needs Node, Dart, Python and PostgreSQL on the host; run it before a PR and in CI.

## Simulation crate

`crates/sim` is the arena for the sync engine. The design uses client and server as pure Rust state machines behind host callbacks, so N clients and one server can run in one process with no network and no database.

### Parts

| Part | What it is |
| --- | --- |
| Clients | `Client<SqliteStore>`, one temporary SQLite file each. Real files, so "crash" is dropping the client and reopening the same path, and DDL reconciliation is on the path too. |
| Server | `ahead_server` over an in-memory host that implements claim, receipt, head, scan, load, publish. PostgreSQL semantics are proven separately in `integration/persistence`. |
| Network | Two queues, requests and responses. No clock. Delay is "not delivered this step"; reorder, duplicate and drop are queue operations chosen by the RNG. |
| RNG | One seeded generator; every random choice comes from it, so a seed reproduces a run exactly. |
| Trace | The list of actions taken. Printed on failure; used by the shrinker. |
| Oracle | The reference answer. Records, per record, the authoritative content the server holds and its stamp; per client, the set of mutations not yet settled. It does not compute the merged view. |

The oracle is deliberately small. It knows semantics (what the server accepted, what each client has been told) and nothing about how the engine stores or replays. A large oracle that mirrors engine code would only prove the engine agrees with a copy of itself.

### Actions

Each step the RNG picks one:

| Action | Guarantees it exercises |
| --- | --- |
| `local_write(client, mutation)` | L, P |
| `direct_write(client, operation)` | L4 |
| `freeze_and_send(client)` | P; puts a request on the network |
| `deliver_request`, `deliver_response` | normal delivery |
| `drop`, `duplicate`, `reorder`, `hold` | R2 |
| `pull(client, channel)` | A, D |
| `crash_restart(client)` | R3 |
| `subscribe`, `unsubscribe(client, channel)` | D6 |
| `server_notify(record, channels)` | D2, D3; a change from another source |
| `reject_next(client)` | P5, P6; the host refuses the next handler call |

### Invariants

Checked after every step:

- Each client's authoritative base for every record equals the oracle's content at the stamp the client has accepted.
- Each client's pending set equals the oracle's unsettled set for that client.
- Per record, the local stamp never decreases. Per channel, the cursor never decreases.
- Handler invocations on the server equal the number of distinct accepted mutations (P1).
- A client with nothing pending and every subscribed channel at head holds the server's current content (convergence).
- Claim rows belong to subscribed channels; a record row has at least one claim; a tombstone has no record row (the #8 invariants).
- The receipt a client stored equals the receipt the server stored, byte for byte.

### Two kinds of test on one harness

- `tests/invariants.rs` runs `for seed in 0..N { step; check }`. `N` defaults to a few hundred so `cargo test` stays fast; `SIM_SEEDS=100000 cargo test -p sim` runs the long form, for a nightly job. A failure prints the seed and the trace. `random_sequences_violate_no_invariant` runs with direct writes off; `random_sequences_with_direct_writes` is `#[ignore]`d until #33 is fixed.
- The other files are named scenarios: a hand-written action list and a Given/When/Then assertion, one per guarantee clause. The test name is the guarantee.

### Shrinking

On failure, remove one action from the trace at a time from the end, replay, and keep the removal if the failure still reproduces. Repeat until nothing can be removed. Simple delta debugging; no external property-testing crate.

### Schema and size

Two models with one relation (an `Entry` with `Comment` children), two or three channels, two or three clients. Enough to reach every D scenario; more adds time, not information.

### Order of work

1. Done: the three `fixtures/scenarios` cases are `crates/sim/tests/distribution.rs`.
2. Done: `crates/sim/tests/invariants.rs`.
3. Remaining: named scenarios for the clauses [guarantees](guarantees.md) still marks `partial`: P4 after a schema change, D4 child membership, R3 crash at every commit, C3 queued bytes across a schema change, and the two clauses opened by #32 and #33.
4. Done: the old in-process integration crate under `integration/` is deleted.

## Adding a test

Ask which guarantee it proves. If none, it is either a unit test for a pure function (put it next to that function) or a translation test for a binding (put it in `integration/bindings`, and keep it about translation).

- **A new guarantee**: add the entry to [guarantees](guarantees.md) first, with `unproven`, then write the primary proof, then update the entry.
- **A new clause of an existing guarantee**: a named scenario in the matching `crates/sim/tests/*.rs`, named after the clause.
- **A new invariant**: add it to the sim's invariant list; every existing seed now checks it.
- **A conformance case**: a script under `fixtures/scenarios/<name>/` with expected final state; the runner picks it up in all three languages.
- **A wire boundary**: a case in `fixtures/protocol`, read by `crates/core/tests`.

Do not add a second test for a behavior in a language binding when the Rust proof exists. One test per language that the call reaches Rust is enough.

## Reporting

Every layer prints test names on failure: `cargo test` natively, `node --test` and `dart test` natively. The shell-driven layers under `integration/` invoke those runners directly rather than wrapping them, so a red gate names the failing case.

## What is not here

- Performance measurements: [performance work](https://github.com/zanminwang/ahead/issues/12). The `sim` harness is reused for workloads, but numbers are a diagnostic, not a gate.
- Connection lifecycle (wake, backoff, close): unit tests in `crates/client`, plus one translation test per binding. Not a guarantee in the list because it is a scheduling policy, not a correctness property.
