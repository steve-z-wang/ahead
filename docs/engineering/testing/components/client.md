# Client tests

Verify local transactions, dependency eligibility, stable frozen batches, page application and settlement. See [Client architecture](../../architecture/client/README.md).

Many engine tests currently live in [sqlite/tests](../../../../crates/sqlite/tests), where real SQLite provides the client harness. Retry scheduling also has inline tests in [connection.rs](../../../../crates/client/src/connection.rs).

```sh
cargo test -p ahead-client --locked
cargo test -p ahead-sqlite --locked
```

For a batching change, assert which mutations are eligible and whether retry bytes remain stable. For settlement, assert the resulting visible state and pending work, rather than only the pending count.

Use [Simulation](../simulation/README.md) for interactions across clients and server. Next review: identify missing assertions and distinguish engine coverage from SQLite-specific coverage.

## Coverage review

Reviewed 2026-09-14 against the client architecture documents; tests read, not executed. Tests in [sqlite/tests](../../../../crates/sqlite/tests) use real SQLite as the harness but assert engine rules, so they are counted here as component evidence; the SQLite contract itself is under [Storage and persistence](../integration/persistence.md). Simulation scenarios that establish the same clause across client and server are listed under [Simulation scenarios](../simulation/scenarios.md) and referenced here only where they add a clause.

### Local operations

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| A write is readable at once; the before image is taken once; dropping the last pending mutation restores it ([Writes](../../architecture/client/engine/local-operations/writes.md)) | [client.rs](../../../../crates/sqlite/tests/client.rs) `optimistic_edit_holds_truth_once_and_rejection_rebuilds_from_it`, `session_reads_own_writes_without_notifying_until_commit_and_blocks_other_writes` | covered | none |
| A failed step rolls back the transaction; a savepoint confines its scope (L3) | `local_transaction_and_mutation_savepoint_have_independent_fate`, `declared_unique_constraint_is_atomic` | covered | none |
| Direct writes never queue; a direct write on a dirty authoritative record survives rejection (L4) | `l4_…` in [sim local.rs](../../../../crates/sim/tests/local.rs); [push.rs](../../../../crates/sqlite/tests/push.rs) `rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox` | covered for authoritative records | A direct write on a pending-create record fabricates truth: *defect* [#33](https://github.com/zanminwang/ahead/issues/33). The only reproduction is the ignored `random_sequences_with_direct_writes`; add the five-action repro from the issue as a named scenario before fixing. |
| Cascades apply to descendants once, including cycles, on all three paths (L5) | `schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations`, `direct_cascade_handles_cyclic_relationships_once`; [downlink.rs](../../../../crates/sqlite/tests/downlink.rs) `delete_cascades_to_descendants_and_their_claims` | covered | none |
| Server truth lands in the before image and pending edits replay on top (A1) | `newer_authority_lands_beneath_pending_edits_and_replays_them`; `pull_before_ack_and_later_local_edit_replay_in_order` | covered | none |
| A replay that no longer applies falls back to the before image silently | none | missing | Behavior is a *potential risk* in Writes §11; decide whether to surface it before writing an expectation. |
| Queries: equality filters, null matching, ordering with nulls first and identity tiebreak, limit, relation navigation ([Queries](../../architecture/client/engine/local-operations/queries.md)) | [query.rs](../../../../crates/sqlite/tests/query.rs) `query_normalizes_filters_orders_nulls_and_resolves_relationships` | covered | List-field filters and ordering by a non-scalar are refused by code but not asserted. |
| Read-only SQL sees optimistic rows and refuses writes | `readonly_sql_sees_optimistic_rows_and_refuses_write_statements` | covered | none |

### Push

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Queue rows reconstruct mutations, operation kinds and dependencies ([Queue](../../architecture/client/engine/push/queue.md)) | [engine.rs](../../../../crates/sqlite/tests/engine.rs) `queue_rows_reconstruct_mutations_and_cascade_on_delete` | covered | Counter exhaustion at 2^53−1 returns an error by code; not asserted (low value). |
| Lifecycle dependents wait for the parent's receipt and never share its batch (P3) | [push.rs](../../../../crates/sqlite/tests/push.rs) `lifecycle_dependency_waits_for_parent_ack_but_sequence_can_share_batch`; [sim push.rs](../../../../crates/sim/tests/push.rs) `p3_lifecycle_dependent_waits_for_the_parent_receipt`; [client.rs](../../../../crates/sqlite/tests/client.rs) `creating_then_editing_a_record_automatically_has_lifecycle_dependency` | covered | The first test's name promises a sequence clause its body lacks; rename rather than add. |
| Sequence dependents may share the batch with their predecessor ([Dependencies](../../architecture/client/engine/push/dependencies.md)) | `schema_sequence_relationship_blocks_dependent_but_not_independent_work` (two mutations frozen together after readiness) | covered | The test name promises an independent mutation the body lacks; rename, or add the independent mutation and assert it is sent first. |
| Unready or failed prerequisites block only their mutation | `failed_prerequisite_stays_optimistic_independent_work_can_overtake`, `schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation` | covered | none |
| An explicit dependency on an unknown ordinal is refused | none | missing | Cheap negative case. |
| Frozen bytes are stable across retry and restart (P4) | `offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull`; `p4_frozen_bytes_are_stable`; [session.rs](../../../../bindings/common/tests/session.rs) `rust_selects_transport_actions_and_reuses_frozen_request_on_retry` | covered | Bytes after a supported schema reconciliation with a populated queue are not asserted; see [Storage and persistence](../integration/persistence.md). |
| Byte budget: oversized candidates are skipped, the first eligible one is selected even if it exceeds a non-zero budget, zero budget yields nothing ([Batching](../../architecture/client/engine/push/batching.md)) | `byte_budget_skips_large_candidate_but_always_allows_one` | partial | The zero-budget rule and the 20-mutation cap have no assertion; no test read enqueues more than 20 mutations. |
| An in-flight batch is returned unchanged until its receipt | `p3_lifecycle_dependent_waits_for_the_parent_receipt` (retry is byte-identical) | covered | none |

### Pull

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Stale pages are no-ops; a page beyond the cursor cannot skip the gap; the cursor advances to `toCursor` (A2) | [downlink.rs](../../../../crates/sqlite/tests/downlink.rs) `original_bad_change_skip_policy_is_retained`; [stamp_scenarios.rs](../../../../crates/sqlite/tests/stamp_scenarios.rs) `redelivered_page_is_a_no_op`; sim `a2_pages_apply_only_in_cursor_order` | covered | A page from a previous subscription of the same channel: *defect* [#32](https://github.com/zanminwang/ahead/issues/32); the sim repro `a2_page_from_a_previous_subscription_is_stale_not_a_gap` exists but is ignored and does not count as coverage. |
| Covered, applied and recover dispositions are the same for HTTP and streamed pages ([Pull](../../architecture/client/engine/pull.md)) | [session.rs](../../../../bindings/common/tests/session.rs) `incoming_pages_share_cursor_policy_and_do_not_overwrite_push_cycle`, `incoming_overlap_is_identical_with_or_without_http_request_metadata` | covered | none |
| Content applies by stamp: newer wins, equal idempotent or diagnostic, older discarded but claims kept (D2) | `older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping`, `equal_stamp_is_idempotent_or_a_diagnostic`, stamp scenarios | covered | none |
| Deletes, tombstones, claims and channel moves (D4, D5, D6) | `channel_claims_and_cross_channel_delete`, `delete_across_channels_keeps_a_tombstone_until_every_claim_confirms`, `move_between_channels_and_back`, [client.rs](../../../../crates/sqlite/tests/client.rs) `unsubscribe_drops_records_nobody_else_claims_and_restarts_from_zero` | covered | Child records moving with their parent are asserted only in the simulation's `MoveMembership` action inside random runs, not in a named scenario. |
| A change that fails validation is skipped and the cursor still advances | `original_bad_change_skip_policy_is_retained` | covered (behavior) | Whether skipping should be visible or fatal is a *potential risk* awaiting a decision; the report is dropped on the SDK path by design today. |
| A page for an unsubscribed channel is dropped whole | `unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped` | covered | none |

### Settlement

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Optimism is removed only after every stored checkpoint is reached, in either arrival order (A3) | sim `a3_ack_alone_does_not_settle`; [push.rs](../../../../crates/sqlite/tests/push.rs) `offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull`, `record_status_reports_phases_and_duplicate_ack_is_idempotent` | covered | none |
| Batches with stored checkpoints settle in accepted-prefix order (A5) | sim `a5_batches_settle_in_accepted_prefix_order`; `accepted_batches_only_settle_in_ready_prefix` | covered (ordered path) | The immediate path (receipt whose checkpoints are all unawaitable while an earlier batch waits) bypasses the order; whether A5 must hold there is *undecided*, see [Settlement §11](../../architecture/client/engine/settlement.md). Do not encode an expectation until decided; a scenario that constructs the sequence and records the outcome is useful either way. |
| A batch whose checkpoints are all unawaitable settles at once, and the record is rebuilt from the before image | [query.rs](../../../../crates/sqlite/tests/query.rs) `transport_pulls_only_subscribed_channels_and_unawaitable_checkpoints_settle` (pending count only) | partial, *undecided* | The visible-row outcome (update reverts, create disappears) is reproduced by the steps kept in Settlement §11; it was executed once outside the suite. Decide the contract, then assert the visible row. |
| Rejection removes the mutation and its lifecycle dependents, keeps a durable inbox until dismissed (P5) | sim `p5_rejection_rolls_back_and_rejects_dependents`; `rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox`; `schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations` | covered | none |
| Duplicate receipts are idempotent; a different receipt for the same batch and an unknown batch are refused | `record_status_reports_phases_and_duplicate_ack_is_idempotent` | covered | none |
| Companions become truth on acceptance unless the server's row wins | `accepted_companion_cascade_does_not_resurrect_descendants`, `accepted_wire_rows_do_not_promote_companion_over_server_authority` | covered | none |
| Unsubscribing settles batches waiting on that channel | `unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped` | covered | none |

### Frontend interface

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Committed state survives reopen (L2); a stale handle cannot commit (R4) | [client.rs](../../../../crates/sqlite/tests/client.rs) `open_creates_tables_persists_identity_and_survives_reopen`, `stale_writer_cannot_overwrite_committed_database` | covered | The R4 test fences a write that would otherwise succeed; it does not show a lost update, which is fine, but the name overstates it. |
| Watchers fire only for named tables and only after commit | `watch_fires_only_for_declared_tables`, `session_reads_own_writes…` | covered | none |
| Session API: reads inside see the session; sync commands are refused while open; unclosed savepoints refuse commit | `session_reads_own_writes…` (apply_page refused); [session.rs](../../../../bindings/common/tests/session.rs) | partial | `commit_session` with an unclosed savepoint is not asserted. |
| `drop_mutation` refuses a frozen mutation | none | missing | Tests drop only unsent mutations. Add the refusal case; it is the boundary of the "poisoned batch" limitation. |

### Connection controller (Rust parts)

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Backoff is bounded, wake does not busy-loop, pause and stop behave ([Scheduling](../../architecture/client/connection/controller/scheduling.md)) | unit tests in [connection.rs](../../../../crates/client/src/connection.rs) | covered | none |
| Lanes have independent retry state; the push-only cycle never pulls; the full cycle pulls each subscribed channel once | [session.rs](../../../../bindings/common/tests/session.rs) `live_and_push_drivers_have_independent_lifecycle_and_retry_state`, `live_push_cycle_keeps_receipts_but_leaves_reads_to_the_stream`, `rust_selects_transport_actions_and_reuses_frozen_request_on_retry`; [query.rs](../../../../crates/sqlite/tests/query.rs) `transport_pulls_only_subscribed_channels_and_unawaitable_checkpoints_settle` | covered | The last test lives in a query file; leave it, but it is a controller test. |

Host-side session behavior (catch-up, generations, refresh) is under [Connection integration](../integration/connection.md).
