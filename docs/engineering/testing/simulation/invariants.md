# Simulation invariants

Generated sequences explore combinations that named scenarios may miss. An invariant checks a required property at each step; assertions about convergence also need the scenario's subscription and delivery conditions to hold.

The [current checker](../../../../crates/sim/src/invariants.rs) covers stamps, cursors, duplicate execution, convergence when caught up, claims, retained records, receipt agreement, settlement behind checkpoints and settlement order. Read each predicate's conditions before claiming that it covers a guarantee.

```sh
cargo test -p ahead-sim --test invariants --locked
```

The [runner](../../../../crates/sim/tests/invariants.rs) defaults to 60 seeds and 120 steps for its main random test. A longer exploration can use:

```sh
SIM_SEEDS=5000 SIM_STEPS=300 cargo test -p ahead-sim --test invariants --locked
```

Both random tests run by default: `random_sequences_violate_no_invariant` with direct writes off and `random_sequences_with_direct_writes` with them on ([#33](https://github.com/zanminwang/ahead/issues/33) fixed). Next review: examine whether the checker observes all relevant states without duplicating engine logic.

## Coverage review

Reviewed 2026-09-14 by reading [invariants.rs](../../../../crates/sim/src/invariants.rs), [step.rs](../../../../crates/sim/src/step.rs) and [sim.rs](../../../../crates/sim/src/sim.rs). The random runner subscribes every client to channel `a`, picks weighted actions (enqueue, freeze, pull, deliver, drop, duplicate, hold, swap, crash, restart, subscribe, unsubscribe, server change, membership move, reject-next, fail-next, and direct write when enabled), settles every 25 steps, and checks the nine predicates after every step. The default run is 60 seeds of 120 steps with three clients, once with direct writes off and once with them on.

| Predicate | Requirement it supports | What it actually checks | Limits |
| --- | --- | --- | --- |
| stamps never decrease | D2 (safety half) | per client and record, the stored stamp never drops while the row exists | The high-water mark is forgotten when the row disappears, so a legitimate reset after unsubscribe is not flagged, and neither would a wrong one be. |
| cursors never decrease | A2 | per subscribed channel, the cursor never drops | Marks are forgotten for unsubscribed channels for the same reason. |
| no mutation executes twice | P1 | `(clientId, batchSequence, ordinal)` triples from committed pushes are distinct | Invocations from an aborted batch are rolled back with the host tables, so a P6 retry is not counted as a duplicate; correct, but it means the check says nothing about aborted attempts. |
| no pending means converged | D1, R1, A1 | a client with nothing pending, at a channel's head, holds the server's content for that channel's records | Exempts direct-written keys until a change newer than the client's record stamp arrives (the client's own replacement rule, so a stale duplicate page does not lift the exemption), records whose membership left the channel, and channels whose own stamp is behind the content stamp. The runner asserts at least 1,000 comparisons across all seeds so the exemptions cannot silently empty the check. |
| claims belong to subscriptions | D6 | no claim row names an unsubscribed channel | none |
| record rows have a claim | L4 | every visible row has a claim or a pending mutation | This is the predicate that found [#33](https://github.com/zanminwang/ahead/issues/33); the direct-write run now passes it. |
| receipts match server | P1, protocol | each receipt the client stored equals the server's stored receipt for that sequence | Only the latest sequence per client is retained on the host, so older receipts are not compared. |
| batches wait for their checkpoints | A3 | every batch the client froze (recorded from the frozen bytes at `Freeze`) that is no longer queued has a receipt, and every checkpoint that receipt named on a channel the client was subscribed to when it arrived has been reached by the local cursor | A batch whose receipt rejected every mutation is exempt (it leaves through rejection). A channel the client has since unsubscribed, or unsubscribed and resubscribed (a new subscription generation), is exempt: D6 settles what waited on it and the cursor restarts at 0. Checkpoints on channels not subscribed at receipt time are not awaited, per A3's second sentence; what such a batch shows is [#52](https://github.com/zanminwang/ahead/issues/52) and is not asserted. |
| batches settle in sequence order | A5 | while any batch is queued, no batch with a higher sequence has left the queue unless every mutation in it was rejected | Reads the queue only; a batch the client never froze is not tracked. |

Requirements with no invariant: P4 byte stability and L3 rollback scope. They rely on named scenarios. Each of the last two predicates has a unit test that forges the violation behind the engine's back (deleting queue rows from the SQLite file of a crashed client) and asserts the report names the batch; a fourth shows the unsubscribe-and-resubscribe exemption.

Runs and results: `random_sequences_violate_no_invariant`, `random_sequences_with_direct_writes` and `every_run_ends_converged_after_settle` are the live checks. Verified 2026-09-14: `cargo test -p ahead-sim --locked --test invariants` passed at the default size and at `SIM_SEEDS=500 SIM_STEPS=200` (see the fix PR for #33). With the A3 and A5 predicates added: `cargo test -p ahead-sim --locked` passed, and the `--test invariants` runner passed at `SIM_SEEDS=500 SIM_STEPS=200` (268 s). A one-off instrumented run counted how often the new predicates reached a non-trivial comparison: the A3 predicate compared a settled batch's checkpoint against a live cursor about 24,000 times in the default run; the A5 predicate's exemption branch (a later batch absent while an earlier one is queued) was reached 6 times in 300 seeds, every time by a fully rejected batch. The unit tests are what prove each predicate reports a violation. Membership faults (`generate_membership_faults`) are off by default and no test turns them on.
