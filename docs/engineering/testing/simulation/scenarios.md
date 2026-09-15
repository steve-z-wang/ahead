# Simulation scenarios

A named scenario shows one observable promise through an explicit sequence of actions and assertions. It should explain why the order matters, such as a page arriving before a receipt or a rejected mutation having dependents.

Existing [scenario tests](../../../../crates/sim/tests) are grouped into local writes, push, authority, distribution and resilience. They use the same [Sim and Action types](../../../../crates/sim/src/sim.rs) as the random runner.

```sh
cargo test -p ahead-sim --test authority --locked
```

Choose a minimal model, channel and client setup. Apply the relevant actions, then assert visible records, pending work or checkpoints according to the promise. Run invariant checks at meaningful intermediate states as well.

Next review: connect each overall guarantee to named assertions and identify clauses not exercised by the existing scenarios.

## Coverage review

Reviewed 2026-09-14 by reading the scenarios in [crates/sim/tests](../../../../crates/sim/tests) against each [guarantee](../../guarantees.md); not executed. The simulation runs the real client crate over temporary SQLite files and the real server crate over an in-memory host ([host.rs](../../../../crates/sim/src/host.rs)), so a scenario here proves engine logic across both sides but not database or transport semantics. Where a clause is proven only in the SQLite harness or the PostgreSQL suite, the row says so.

| Guarantee | Named scenario | Coverage | Gap and next step |
| --- | --- | --- | --- |
| L1 merged view, in order, across settlement | [local.rs](../../../../crates/sim/tests/local.rs) `l1_merged_view_shows_pending_edits_in_order` | covered | none |
| L2 reopen preserves committed state | none here; SQLite harness (`open_creates_tables_persists_identity_and_survives_reopen`) and R3 below | covered elsewhere | Appropriate: L2 is a store contract. |
| L3 rollback and savepoint scope | none here; SQLite harness | covered elsewhere | Appropriate. |
| L4 direct writes never push and survive rejection | `l4_direct_write_is_never_pushed_and_survives_rejection` (skips the invariant check on purpose) | covered for an authoritative record | Pending-create case is [#33](https://github.com/zanminwang/ahead/issues/33); no named scenario yet. |
| L5 cascade locally and on the server | `l5_delete_cascades_locally_and_on_the_server` | covered | The server cascade here is the in-memory host's own logic, not a framework rule; a real backend must cascade itself ([Relations §11](../../architecture/schema/relations.md)). |
| P1 lost receipt, same bytes, one execution | [push.rs](../../../../crates/sim/tests/push.rs) `p1_lost_receipt_retry_executes_once` | covered | Concurrent retries need the PostgreSQL lock test. |
| P2 contiguous sequences; gap and overlap refused | `p2_contiguous_sequence_and_server_refuses_gap_and_overlap` | covered | none |
| P3 lifecycle dependent waits for the receipt, never shares the batch | `p3_lifecycle_dependent_waits_for_the_parent_receipt` (byte-for-byte) | covered | Sequence and prerequisite clauses are in the SQLite harness ([Client tests](../components/client.md)). |
| P4 frozen bytes stable across duplicate freeze and crash | `p4_frozen_bytes_are_stable` | covered | After a schema change: missing everywhere. |
| P5 rejection rolls back parent and lifecycle dependents, both readable | `p5_rejection_rolls_back_and_rejects_dependents` | covered | none |
| P6 handler failure aborts the batch; head untouched; same bytes retried | `p6_handler_failure_aborts_the_batch_and_the_client_retries` | covered on the snapshot host | Real savepoint rollback is the PostgreSQL suite's job. |
| A1 server value replaces optimism; later edit replays | [authority.rs](../../../../crates/sim/tests/authority.rs) `a1_server_value_overrides_optimism_and_later_edits_replay` (asserts the before image too) | covered | none |
| A2 stale duplicate page is a no-op; cursor stays | `a2_pages_apply_only_in_cursor_order` | covered | `a2_page_from_a_previous_subscription_is_stale_not_a_gap` is `#[ignore]`d for [#32](https://github.com/zanminwang/ahead/issues/32): a repro, not coverage. |
| A3 receipt alone does not settle, in either order | `a3_ack_alone_does_not_settle` | covered | The non-subscribed-checkpoint outcome is *undecided*; see [Settlement](../../architecture/client/engine/settlement.md). |
| A4 handler without a channel aborts the batch | `a4_handler_without_a_channel_aborts_the_batch` | covered | Ambiguous-channel and explicit-choice clauses are PostgreSQL-only (the logic is in the TypeScript runtime). |
| A5 later ready batch waits for the earlier one | `a5_batches_settle_in_accepted_prefix_order` | covered (ordered path) | Immediate path *undecided*; no scenario constructs it. |
| D1 two clients converge | [distribution.rs](../../../../crates/sim/tests/distribution.rs) `d1_two_clients_on_one_channel_converge` | covered | none |
| D2 delayed older page cannot regress newer content | `d2_delayed_page_from_another_channel_cannot_regress_newer_content` | covered | none |
| D3 one stamp per publication, independent cursors | `d3_each_channel_publish_allocates_its_own_stamp` | covered through the client | Stamp allocation itself is the host's counter; the PostgreSQL suite proves the real adapter. |
| D4 move between channels and back | `d4_move_between_channels_and_back` | covered for one record | Child membership following the parent is exercised only by `MoveMembership` in random runs; add a named parent-and-child move. |
| D5 delete across channels with tombstone | `d5_delete_across_channels_keeps_a_tombstone_until_every_claim_confirms` | covered | none |
| D6 unsubscribe keeps other claims; null load deletes | `d6_unsubscribe_keeps_what_other_channels_claim` | covered | none |
| R1 offline writes then convergence | [resilience.rs](../../../../crates/sim/tests/resilience.rs) `r1_writes_continue_while_unreachable_and_converge_after` | covered | none |
| R3 crash after every step of a round trip | `r3_crash_after_every_step_loses_nothing` | covered for step boundaries | See [Failure and recovery](recovery.md) for what a crash is here. |
| R4 stale writer | none here; SQLite harness | covered elsewhere | Appropriate. |
