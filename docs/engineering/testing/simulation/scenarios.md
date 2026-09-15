# Simulation scenarios

A named scenario shows one observable promise through an explicit sequence of actions and assertions. It should explain why the order matters, such as a page arriving before a receipt or a rejected mutation having dependents.

Existing [scenario tests](../../../../crates/sim/tests) are grouped into local writes, push, authority, distribution and resilience. They use the same [Sim and Action types](../../../../crates/sim/src/sim.rs) as the random runner.

```sh
cargo test -p ahead-sim --test authority --locked
```

Choose a minimal model, channel and client setup. Apply the relevant actions, then assert visible records, pending work or checkpoints according to the promise. Run invariant checks at meaningful intermediate states as well.

Next review: connect each overall guarantee to named assertions and identify clauses not exercised by the existing scenarios.
