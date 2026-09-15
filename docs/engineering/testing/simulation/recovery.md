# Failure and recovery

Explore delayed, duplicated, reordered or dropped messages, rejected mutations, subscription changes and client restart. These are logical faults chosen by the harness; a restart reopens a client's SQLite file, not an operating-system power failure.

Existing entry points: [resilience scenarios](../../../../crates/sim/tests/resilience.rs), [network queues](../../../../crates/sim/src/net.rs) and [action execution](../../../../crates/sim/src/step.rs).

```sh
cargo test -p ahead-sim --test resilience --locked
```

A generated failure reports its seed, step, error and traces. Keep the commit, client count, run settings and trace when reporting it. [Replay and shrinking](../../../../crates/sim/src/shrink.rs) replay an action list and remove actions while preserving the failure identity.

Preserve a minimal failing trace as a named regression before fixing its cause. Next review: inspect crash-boundary coverage and ensure minimized traces still expose the original defect.
