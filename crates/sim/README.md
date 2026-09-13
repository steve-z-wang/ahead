# Simulation

`cargo test -p otter-sim` runs the named scenarios for guarantees L, P, A, D and R and a
quick random run (60 seeds, 120 steps, 3 clients, with direct writes off; every invariant is
checked after every step). `random_sequences_with_direct_writes` is ignored until issue #33
is fixed. `SIM_SEEDS=5000 SIM_STEPS=300 cargo test -p otter-sim --test invariants` is the long
form. A failure prints the seed, the full trace and the minimal trace that still fails.

Design: docs/testing.md, section "Simulation crate". Guarantees: docs/guarantees.md.

## Capacity diagnostic

`cargo run -p otter-sim --example capacity --release` enqueues 10 and 1,000 updates to one
record with one real SQLite commit per mutation, then applies an authoritative page and
checks that pending replay preserves the latest local value. It reports enqueue p50/p95 and
one page-plus-replay duration. It is a diagnostic, not a gate; see issue #12.
