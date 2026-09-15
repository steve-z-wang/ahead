# Simulation invariants

Generated sequences explore combinations that named scenarios may miss. An invariant checks a required property at each step; assertions about convergence also need the scenario's subscription and delivery conditions to hold.

The [current checker](../../../../crates/sim/src/invariants.rs) covers stamps, cursors, duplicate execution, convergence when caught up, claims, retained records and receipt agreement. Read each predicate's conditions before claiming that it covers a guarantee.

```sh
cargo test -p ahead-sim --test invariants --locked
```

The [runner](../../../../crates/sim/tests/invariants.rs) defaults to 60 seeds and 120 steps for its main random test. A longer exploration can use:

```sh
SIM_SEEDS=5000 SIM_STEPS=300 cargo test -p ahead-sim --test invariants --locked
```

At this base, the random test including direct writes is explicitly ignored for [#33](https://github.com/zanminwang/ahead/issues/33). Raising the seed count does not enable it. Next review: re-check ignored cases after rebase, and examine whether the checker observes all relevant states without duplicating engine logic.
