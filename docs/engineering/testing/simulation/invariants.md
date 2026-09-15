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

At this base, the random test including direct writes is explicitly ignored for [#33](https://github.com/zanminwang/ahead/issues/33). Raising the seed count does not enable it. The coverage review below records what the existing tests assert; missing tests are tracked in [#68](https://github.com/zanminwang/ahead/issues/68).

## Coverage review

Reviewed 2026-09-14 by reading [invariants.rs](../../../../crates/sim/src/invariants.rs), [step.rs](../../../../crates/sim/src/step.rs) and [sim.rs](../../../../crates/sim/src/sim.rs); not executed. The random runner subscribes every client to channel `a`, picks weighted actions (enqueue, freeze, pull, deliver, drop, duplicate, hold, swap, crash, restart, subscribe, unsubscribe, server change, membership move, reject-next, fail-next, and direct write when enabled), settles every 25 steps, and checks the seven predicates after every step. The default run is 60 seeds of 120 steps with three clients and direct writes off.

| Predicate | Requirement it supports | What it actually checks | Limits |
| --- | --- | --- | --- |
| stamps never decrease | D2 (safety half) | per client and record, the stored stamp never drops while the row exists | The high-water mark is forgotten when the row disappears, so a legitimate reset after unsubscribe is not flagged, and neither would a wrong one be. |
| cursors never decrease | A2 | per subscribed channel, the cursor never drops | Marks are forgotten for unsubscribed channels for the same reason. |
| no mutation executes twice | P1 | `(clientId, batchSequence, ordinal)` triples from committed pushes are distinct | Invocations from an aborted batch are rolled back with the host tables, so a P6 retry is not counted as a duplicate; correct, but it means the check says nothing about aborted attempts. |
| no pending means converged | D1, R1, A1 | a client with nothing pending, at a channel's head, holds the server's content for that channel's records | Exempts direct-written keys, records whose membership left the channel, and channels whose own stamp is behind the content stamp. The runner asserts at least 1,000 comparisons across all seeds so the exemptions cannot silently empty the check. |
| claims belong to subscriptions | D6 | no claim row names an unsubscribed channel | none |
| record rows have a claim | L4 / [#33](https://github.com/zanminwang/ahead/issues/33) | every visible row has a claim or a pending mutation | This is the predicate the ignored direct-write run violates. |
| receipts match server | P1, protocol | each receipt the client stored equals the server's stored receipt for that sequence | Only the latest sequence per client is retained on the host, so older receipts are not compared. |

Requirements with no invariant: A3 (a pending mutation must not settle before its checkpoint), A5 ordering, P4 byte stability, L3 rollback scope. They rely on named scenarios. A3 and A5 would be natural additions: after every step, no batch with a stored checkpoint above the local cursor may be absent from the queue, and no later batch may be gone while an earlier one remains.

Runs and results: `random_sequences_violate_no_invariant` and `every_run_ends_converged_after_settle` are the live checks. `random_sequences_with_direct_writes` is ignored; it must not be counted, and the seed count does not change that. Membership faults (`generate_membership_faults`) are off by default and no test turns them on.
