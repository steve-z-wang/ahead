# Guarantees

What the framework promises, one sentence each, and where each promise is proven. A guarantee is a property of the whole system; the test that proves it lives in the layer that owns the logic. Most primary proofs belong in the Rust simulation crate (`crates/sim`, issue #13); adapter, binding and end-to-end tests only prove that a thin layer translates or persists that logic correctly.

Each entry lists:

- **Primary**: the test that exercises the guarantee's own logic, or `unproven`.
- **Supporting**: tests that prove a layer above or below does not break it.

Paths are `file::test name`. This page is the map; [testing strategy](testing-strategy.md) describes the layers and how to add a case.

## Summary

Eight groups. The first five are the sync engine and belong to the simulation; the last three are edges and belong to the layer they name.

Status on 2026-09-13, against the tests on `main` with `crates/sim` in place (issue #13): **25 proven, 8 partial, 1 unproven**. The one unproven is S3 (three clients, identical state); no runner drives all three languages yet. `partial` means a primary test exists but a named clause is not asserted; the note under the entry says which. C4 is still proven only in the PostgreSQL suite with no in-process counterpart. Two open engine bugs the simulation found, #32 and #33, are named in the A2 and L4 notes.

**L. Local writes** — what a transaction promises before anything reaches the network.

| ID | Guarantee | Primary |
| --- | --- | --- |
| L1 | Queries return the merged view; a local write is readable at once | proven |
| L2 | A committed local write survives restart | proven |
| L3 | A failed step rolls back the whole local transaction | proven |
| L4 | Direct writes never push; companions follow their mutation | proven |
| L5 | Delete cascades to local children as declared | proven |

**P. Push** — what happens to a mutation between the queue and the server's receipt.

| ID | Guarantee | Primary |
| --- | --- | --- |
| P1 | Each mutation executes at most once on the server | proven |
| P2 | Batches arrive in order with contiguous sequence numbers | proven |
| P3 | Unready and dependent mutations wait | proven |
| P4 | A frozen batch re-encodes byte-for-byte | partial |
| P5 | A rejected mutation rolls back and its reason is readable | proven |
| P6 | A handler exception aborts the whole batch | proven |

**A. Authority and settlement** — when the server's answer replaces the client's guess.

| ID | Guarantee | Primary |
| --- | --- | --- |
| A1 | Server-normalized values override optimism once settled | proven |
| A2 | Pages apply only in cursor order | proven |
| A3 | Optimism is removed only after every required checkpoint | proven |
| A4 | Checkpoints name only Channels the handler notified | proven |
| A5 | Batches settle in accepted-prefix order | proven |

**D. Distribution** — how content reaches clients through Channels and stays consistent across them.

| ID | Guarantee | Primary |
| --- | --- | --- |
| D1 | Clients on the same Channel converge | proven |
| D2 | Content updates only by record stamp | proven |
| D3 | Each publish allocates its own stamp; Channel cursors are independent | proven |
| D4 | Records moving between Channels end in the right state | partial |
| D5 | Deletes and tombstones respect stamps and claims | proven |
| D6 | Unsubscribe keeps what other Channels claim; null loads delete | proven |

**R. Resilience** — the above under bad networks and crashes.

| ID | Guarantee | Primary |
| --- | --- | --- |
| R1 | Clients work while the server is unreachable | proven |
| R2 | Drop, duplicate, reorder and delay violate nothing | partial |
| R3 | Crash at any durable boundary loses nothing | partial |
| R4 | A stale writer cannot write | proven |

**C. Compatibility** — wire and schema evolution.

| ID | Guarantee | Primary |
| --- | --- | --- |
| C1 | Wire format is byte-compatible with the reference | proven |
| C2 | Received states tolerate extra fields, not missing ones | proven |
| C3 | Additive schema changes open; others fail without damage | partial |
| C4 | Unsupported handler versions refuse the batch | partial |

**S. Developer surface** — compiler, generated code and the two language clients.

| ID | Guarantee | Primary |
| --- | --- | --- |
| S1 | The compiler is deterministic and locates errors | partial |
| S2 | Generated APIs type-check positives and reject negatives | partial |
| S3 | Rust, TS and Dart clients produce identical state | unproven |
| S4 | One end-to-end flow per language is wired | proven |

**N. Not guaranteed** — six things a reader might assume and should not. See the last section.

## L. Local writes

### L1 Queries return the merged view

A query returns the authoritative base with every unsettled pending edit applied on top, in queue order. A write inside a transaction is readable by the same transaction before commit and by every reader after commit.

Primary:
- crates/sim/tests/local.rs::l1_merged_view_shows_pending_edits_in_order
- crates/sqlite/tests/client.rs::session_reads_own_writes_without_notifying_until_commit_and_blocks_other_writes
- crates/sqlite/tests/client.rs::optimistic_edit_holds_truth_once_and_rejection_rebuilds_from_it
- crates/sqlite/tests/query.rs::readonly_sql_sees_optimistic_rows_and_refuses_write_statements
- crates/sqlite/tests/downlink.rs::newer_authority_lands_beneath_pending_edits_and_replays_them
- crates/sqlite/tests/push.rs::pull_before_ack_and_later_local_edit_replay_in_order

Supporting:
- bindings/common/tests/session.rs::language_commands_preserve_transaction_isolation_and_closed_handles
- integration/e2e/round-trip.test.mjs::local edit visible before sync
- integration/e2e/round-trip.test.mjs::local writes are not blocked by an in-flight push
- packages/dart/test/client_test.dart::Dart callbacks read their writes, rollback and reopen through native Rust

### L2 A committed local write survives restart

Closing and reopening the database at any point after commit returns the same rows, pending queue and rejections.

Primary:
- crates/sqlite/tests/client.rs::open_creates_tables_persists_identity_and_survives_reopen
- crates/sqlite/tests/push.rs::offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull (queue)
- crates/sqlite/tests/push.rs::rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox (rejections)

Supporting:
- packages/dart/test/client_test.dart::Dart callbacks read their writes, rollback and reopen through native Rust

### L3 A failed step rolls back the whole local transaction

An error anywhere in a transaction leaves the database as it was before the transaction. Nested savepoints roll back only their own scope; an unawaited or escaped call poisons the transaction.

Primary:
- crates/sqlite/tests/client.rs::local_transaction_and_mutation_savepoint_have_independent_fate
- crates/sqlite/tests/client.rs::session_reads_own_writes_without_notifying_until_commit_and_blocks_other_writes
- crates/sqlite/tests/client.rs::declared_unique_constraint_is_atomic
- crates/sqlite/tests/store.rs::savepoints_nest_and_rollback_independently

Supporting:
- integration/bindings/client-js/transaction.test.mjs::caught failed operation poisons outer transaction, savepoint confines failure
- integration/bindings/client-js/transaction.test.mjs::unawaited nested scope poisons transaction without releasing another scope
- packages/dart/test/client_test.dart::Dart callbacks read their writes, rollback and reopen through native Rust

Note: The unawaited-call clause is binding behavior and is proven only in the binding tests.

### L4 Direct writes never push; companions follow their mutation

A direct write outside a named mutation is final at commit, never enters the queue and is never sent. A companion operation attached to a mutation rolls back with it on rejection and becomes local truth on acceptance; the server never learns it existed. A direct write on a dirty row advances that row's rollback base so a later rejection does not undo it.

Primary:
- crates/sim/tests/local.rs::l4_direct_write_is_never_pushed_and_survives_rejection
- crates/sqlite/tests/push.rs::rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox (direct write on a dirty row survives the rejection)
- crates/sqlite/tests/client.rs::local_transaction_and_mutation_savepoint_have_independent_fate (direct write leaves the queue empty)
- crates/sqlite/tests/client.rs::schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations (companion rolls back with the mutation)
- crates/sqlite/tests/push.rs::accepted_companion_cascade_does_not_resurrect_descendants (companion becomes truth on acceptance)
- crates/sqlite/tests/push.rs::accepted_wire_rows_do_not_promote_companion_over_server_authority

Supporting:
- none

Note: The advancing-base clause applies only to rows that exist in authority; a direct write on a pending-create row currently fabricates truth. Open, #33.

### L5 Delete cascades to local children as declared

Deleting a record deletes the local child records the schema declares, in both direct writes and queued mutations.

Primary:
- crates/sim/tests/local.rs::l5_delete_cascades_locally_and_on_the_server
- crates/sqlite/tests/client.rs::schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations
- crates/sqlite/tests/client.rs::direct_cascade_handles_cyclic_relationships_once
- crates/sqlite/tests/push.rs::accepted_companion_cascade_does_not_resurrect_descendants
- crates/sqlite/tests/downlink.rs::delete_cascades_to_descendants_and_their_claims

Supporting:
- none

## P. Push

### P1 Each mutation executes at most once on the server

A client that lost the ACK re-sends the same batch bytes. The server recognizes `(clientId, batchSequence)`, returns the stored receipt and does not call the handler again. Requires the client's batch sequence to be persisted and monotonic.

Primary:
- crates/sim/tests/push.rs::p1_lost_receipt_retry_executes_once
- integration/persistence/server/runtime.test.mjs::concurrent same-client retry executes once under PostgreSQL lock
- integration/persistence/server/runtime.test.mjs::push commits business + compacted publication + exact durable receipt together

Supporting:
- integration/e2e/round-trip.test.mjs::lost ack after commit still converges without re-invoking the handler

### P2 Batches arrive in order with contiguous sequence numbers

The server accepts sequence `n + 1` after `n`; a gap or an overlap is refused with a stable code and nothing is executed.

Primary:
- crates/sim/tests/push.rs::p2_contiguous_sequence_and_server_refuses_gap_and_overlap (contiguous sequence, then a gap and an overlap refused in-process)
- integration/persistence/server/runtime.test.mjs::push commits business + compacted publication + exact durable receipt together (gap refused)
- integration/persistence/server/runtime.test.mjs::compaction materializes latest state; deletion is aligned null (overlap refused)
- crates/sqlite/tests/push.rs::accepted_batches_only_settle_in_ready_prefix (consecutive freezes numbered 1, 2)

Supporting:
- none

### P3 Unready and dependent mutations wait

A mutation whose prerequisite task is not ready is not frozen. A lifecycle dependency must be accepted before its dependent is sent, and the two are never in one batch. A sequence dependency may share a batch when the predecessor was selected earlier in it.

Primary:
- crates/sqlite/tests/push.rs::failed_prerequisite_stays_optimistic_independent_work_can_overtake
- crates/sqlite/tests/push.rs::lifecycle_dependency_waits_for_parent_ack_but_sequence_can_share_batch (lifecycle clause; the name promises a sequence case the body lacks)
- crates/sqlite/tests/push.rs::schema_sequence_relationship_blocks_dependent_but_not_independent_work (sequence clause; the name promises an independent mutation the body lacks)
- crates/sqlite/tests/push.rs::schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation

Supporting:
- integration/bindings/client-js/prerequisite.test.mjs::prerequisite failure stays optimistic and explicit retry unlocks Rust push

Note: Two test names overstate their bodies; rename in step 2.

### P4 A frozen batch re-encodes byte-for-byte

Once frozen, a batch's request bytes do not change on retry, after a schema change, or after restart; `freeze` returns the same bytes until the receipt arrives.

Primary:
- crates/sim/tests/push.rs::p4_frozen_bytes_are_stable
- crates/sqlite/tests/push.rs::offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull

Supporting:
- bindings/common/tests/session.rs::rust_selects_transport_actions_and_reuses_frozen_request_on_retry
- integration/e2e/round-trip.test.mjs::frozen batch survives restart

Note: Bytes after a schema change are not asserted.

### P5 A rejected mutation rolls back and its reason is readable

A rejected mutation is removed from the queue, its records rebuilt from the rollback base, and its lifecycle dependents rejected with it. The rejection code is readable until the application dismisses it.

Primary:
- crates/sim/tests/push.rs::p5_rejection_rolls_back_and_rejects_dependents (parent and lifecycle dependent both rolled back and rejected)
- crates/sqlite/tests/push.rs::rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox (rollback, readable after reopen, dismiss clears)
- crates/sqlite/tests/client.rs::schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations (cascaded child restored)

Supporting:
- integration/e2e/round-trip.test.mjs::server rejection reverts local state and is reported

### P6 A handler exception aborts the whole batch

A deterministic refusal rolls back only that mutation's savepoint and yields `{ordinal, code}`; other mutations in the batch proceed. Any other error aborts the request: business tables, framework tables and the receipt roll back together, and the client retries the same bytes.

Primary:
- crates/sim/tests/push.rs::p6_handler_failure_aborts_the_batch_and_the_client_retries
- integration/persistence/server/runtime.test.mjs::unknown error rolls back entire batch including earlier effects and client claim
- integration/persistence/server/runtime.test.mjs::explicit rejection rolls back only mutation and its publication
- integration/persistence/server/runtime.test.mjs::publication failures poison push and roll back business writes
- integration/persistence/server/runtime.test.mjs::checkpoint errors bypass translateRejection and abort the batch instead of settling as a rejection
- crates/server/tests/runtime.rs::known_disallowed_patch_is_explicit_refusal (stable refusal code)

Supporting:
- integration/bindings/node/transaction-bridge.test.mjs::Rust error after host write rolls back business and framework
- integration/bindings/node/transaction-bridge.test.mjs::business rejection rolls back its savepoint while preceding mutation commits

Note: Savepoint-level rollback against a real database is proven only against PostgreSQL; the sim's host does not model savepoints.

## A. Authority and settlement

Two numbers, each with one job. The Channel cursor orders pages and witnesses settlement. The record stamp orders content (D2). Neither is derived from the other.

### A1 Server-normalized values override optimism once settled

When a mutation settles, the value the server stored replaces the local optimistic value even if they differ; pending edits queued after it replay on top of the new base.

Primary:
- crates/sqlite/tests/push.rs::offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull (row reads the normalized value after settle)
- crates/sqlite/tests/push.rs::pull_before_ack_and_later_local_edit_replay_in_order (later edit replays on the new base)
- crates/sqlite/tests/downlink.rs::newer_authority_lands_beneath_pending_edits_and_replays_them
- crates/sqlite/tests/push.rs::accepted_wire_rows_do_not_promote_companion_over_server_authority
- crates/sim/tests/authority.rs::a1_server_value_overrides_optimism_and_later_edits_replay

Supporting:
- integration/e2e/round-trip.test.mjs::lost ack after commit still converges without re-invoking the handler

### A2 Pages apply only in cursor order

A page whose `fromCursor` does not equal the local cursor for that Channel is refused. Applying a page advances the cursor to its `toCursor`; the cursor never decreases.

Primary:
- crates/sim/tests/authority.rs::a2_pages_apply_only_in_cursor_order (a duplicated page is a no-op; the cursor does not move on the stale replay)
- crates/sqlite/tests/downlink.rs::original_bad_change_skip_policy_is_retained (page behind the cursor is stale, page ahead is an error, cursor advances to toCursor)
- crates/sqlite/tests/stamp_scenarios.rs::redelivered_page_is_a_no_op
- crates/sqlite/tests/downlink.rs::unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped

Supporting:
- crates/core/tests/contracts.rs::wire_names_remain_legacy_and_counters_are_safe (decode refuses fromCursor > toCursor)

Note: Cursor monotonicity follows from the gate but is not asserted on its own after a stale apply. A page from a previous subscription of the same Channel must be dropped as stale; open, #32.

### A3 Optimism is removed only after every required checkpoint

A receipt lists required checkpoints per Channel. The mutation stays optimistic until the local cursor of every listed Channel reaches its checkpoint, regardless of whether the ACK or the pages arrive first.

Primary:
- crates/sim/tests/authority.rs::a3_ack_alone_does_not_settle (ACK-then-page and page-then-ACK both end settled)
- crates/sqlite/tests/push.rs::offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull (pending stays 1 after the ACK, 0 after the page)
- crates/sqlite/tests/push.rs::accepted_batches_only_settle_in_ready_prefix
- crates/sqlite/tests/push.rs::record_status_reports_phases_and_duplicate_ack_is_idempotent (phase is accepted, not settled, after the ACK alone)
- crates/sqlite/tests/push.rs::pull_before_ack_and_later_local_edit_replay_in_order (order independence)
- crates/sqlite/tests/query.rs::transport_pulls_only_subscribed_channels_and_unawaitable_checkpoints_settle (documented exception: a checkpoint on a never-pulled channel settles at once)

Supporting:
- none

### A4 Checkpoints name only Channels the handler notified

The server derives required checkpoints from the Channels the handler notified during the batch. A handler that notifies no Channel, or leaves the selection ambiguous, is a framework error that aborts the batch; a checkpoint is never satisfied by an unrelated Channel.

Primary:
- crates/sim/tests/authority.rs::a4_handler_without_a_channel_aborts_the_batch
- integration/persistence/server/runtime.test.mjs::checkpoint is the single notified channel; several need an explicit choice; none is an error
- integration/persistence/server/runtime.test.mjs::checkpoint errors bypass translateRejection and abort the batch instead of settling as a rejection
- integration/persistence/server/runtime.test.mjs::an all-rejected batch settles with no checkpoints

Supporting:
- none

### A5 Batches settle in accepted-prefix order

Batches settle in sequence order. A later batch whose checkpoints are all reached does not settle while an earlier batch is still waiting.

Primary:
- crates/sim/tests/authority.rs::a5_batches_settle_in_accepted_prefix_order
- crates/sqlite/tests/push.rs::accepted_batches_only_settle_in_ready_prefix (batch 2's checkpoint is reached first; nothing settles until batch 1's does)

Supporting:
- none

## D. Distribution

### D1 Clients on the same Channel converge

Two clients subscribed to the same Channel, after every page and receipt has been delivered, hold identical authoritative content for every record in it.

Primary:
- crates/sim/tests/distribution.rs::d1_two_clients_on_one_channel_converge

Supporting:
- integration/e2e/round-trip.test.mjs::cross-runtime Dart client converges with the same server (a second client, but it writes a different record)

### D2 Content updates only by record stamp

Every delivered record carries a per-record stamp allocated by the server at notify. The client applies content when the stamp is greater than the stored one, treats an equal stamp as idempotent, and discards older content. Delivery order and delivering Channel do not matter. A page lacking a stamp is refused.

Primary:
- crates/sqlite/tests/downlink.rs::older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping
- crates/sqlite/tests/downlink.rs::equal_stamp_is_idempotent_or_a_diagnostic
- crates/sqlite/tests/stamp_scenarios.rs::delayed_page_from_another_channel_cannot_regress_newer_content
- crates/core/tests/contracts.rs::field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected (page without stamp refused)
- crates/server/tests/stamp.rs::pull_rejects_rows_without_a_positive_stamp

Supporting:
- crates/server/tests/stamp.rs::pull_copies_the_row_stamp_into_the_change
- crates/sqlite/tests/engine.rs::ledger_tracks_stamps_claims_and_subscriptions

### D3 Each publish allocates its own stamp; Channel cursors are independent

Every `(channel, record)` publish allocates the next stamp for that record, so one notify fanning out to Channel A then Channel B yields two consecutive stamps, ordered by the order the handler called notify. Each Channel's cursor advances on its own; it does not track or compare stamps.

Primary:
- crates/sim/tests/distribution.rs::d3_each_channel_publish_allocates_its_own_stamp (one notify to A then B allocates two consecutive stamps in notify order; each Channel's cursor advances independently)
- integration/persistence/server/runtime.test.mjs::publish allocates one stamp per notify and stores it on the invalidation row (stamps 1, 2, 3; cursors of a and b advance independently)
- crates/server/tests/stamp.rs::publish_requires_cursor_and_stamp_from_the_host
- crates/sqlite/tests/downlink.rs::channel_claims_and_cross_channel_delete (client cursors independent)

Supporting:
- none

### D4 Records moving between Channels end in the right state

A record moved from Channel A to B, or A to B and back to A, ends with the newest content and the right claims, including when A's delayed page arrives after B's, and including child records whose membership follows the parent.

Primary:
- crates/sim/tests/distribution.rs::d4_move_between_channels_and_back (A→B, B→A, each move's source delete arriving after the destination's upsert)
- crates/sqlite/tests/stamp_scenarios.rs::move_between_channels_and_back (A→B, B→A, delayed delete, re-notify)
- crates/sqlite/tests/stamp_scenarios.rs::delayed_page_from_another_channel_cannot_regress_newer_content

Supporting:
- crates/sqlite/tests/downlink.rs::delete_cascades_to_descendants_and_their_claims (child claim follows parent, single channel)

Note: Child records moving with their parent across channels is not asserted.

### D5 Deletes and tombstones respect stamps and claims

A delete with a newer stamp removes the record locally regardless of remaining claims; the remaining claims are the Channels whose delete has not arrived. An older delete cannot replace newer content. Releasing one Channel's claim never affects another Channel's claim.

Primary:
- crates/sqlite/tests/downlink.rs::channel_claims_and_cross_channel_delete
- crates/sqlite/tests/downlink.rs::older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping (older tombstone discarded, claim still released)
- crates/sqlite/tests/stamp_scenarios.rs::delete_across_channels_keeps_a_tombstone_until_every_claim_confirms
- crates/sqlite/tests/client.rs::unsubscribe_drops_records_nobody_else_claims_and_restarts_from_zero (releasing one claim leaves another)

Supporting:
- crates/sqlite/tests/engine.rs::ledger_tracks_stamps_claims_and_subscriptions

### D6 Unsubscribe keeps what other Channels claim; null loads delete

Unsubscribing a Channel drops its claims and the records no other Channel claims, then resets its cursor. A loader returning null for a record is applied as a delete on that Channel.

Primary:
- crates/sqlite/tests/client.rs::unsubscribe_drops_records_nobody_else_claims_and_restarts_from_zero
- crates/sqlite/tests/downlink.rs::channel_claims_and_cross_channel_delete (null state applied as delete)
- crates/sqlite/tests/downlink.rs::delete_cascades_to_descendants_and_their_claims
- crates/sqlite/tests/downlink.rs::unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped

Supporting:
- integration/persistence/server/runtime.test.mjs::undefined loader entries remain defects and never become tombstones (server side of the null rule)
- crates/sqlite/tests/engine.rs::ledger_tracks_stamps_claims_and_subscriptions

## R. Resilience

### R1 Clients work while the server is unreachable

Local reads and writes succeed with no server. When the server returns, queued batches are sent in order and the client converges with it.

Primary:
- crates/sim/tests/resilience.rs::r1_writes_continue_while_unreachable_and_converge_after
- crates/sqlite/tests/push.rs::offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull (write and freeze with no server, then apply)

Supporting:
- none

### R2 Drop, duplicate, reorder and delay violate nothing

Under any combination of dropped, duplicated, reordered and delayed pushes, receipts and pages, every guarantee in L, P, A and D still holds. This is the property the simulation checks after every step of a random sequence.

Primary:
- crates/sim/tests/invariants.rs::random_sequences_violate_no_invariant (random sequences over three clients, drop/duplicate/reorder/hold/crash included, every invariant checked after every step)
- crates/sqlite/tests/push.rs::record_status_reports_phases_and_duplicate_ack_is_idempotent
- crates/sqlite/tests/stamp_scenarios.rs::redelivered_page_is_a_no_op
- crates/sqlite/tests/stamp_scenarios.rs::delayed_page_from_another_channel_cannot_regress_newer_content
- crates/sqlite/tests/downlink.rs::original_bad_change_skip_policy_is_retained

Supporting:
- none

Note: The runner proves this with direct writes off. `crates/sim/tests/invariants.rs::random_sequences_with_direct_writes` is `#[ignore]`d until #33; direct writes are excluded from the checked property until that bug is fixed.

### R3 Crash at any durable boundary loses nothing

Killing the process after any commit and reopening leaves the queue, frozen batches, receipts, cursors, claims, stamps, tombstones and rejections exactly as committed; the next freeze, push or pull continues from there.

Primary:
- crates/sim/tests/resilience.rs::r3_crash_after_every_step_loses_nothing (crash and restart after every single step of a full round trip; nothing lost, still converges)
- crates/sqlite/tests/stamp_scenarios.rs::reopen_preserves_stamps_claims_and_tombstones
- crates/sqlite/tests/push.rs::offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull (queue, frozen bytes)
- crates/sqlite/tests/push.rs::rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox (rejections)
- crates/sqlite/tests/push.rs::schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation (tasks)
- crates/sqlite/tests/client.rs::open_creates_tables_persists_identity_and_survives_reopen

Supporting:
- integration/e2e/round-trip.test.mjs::frozen batch survives restart
- packages/dart/test/client_test.dart::Dart callbacks read their writes, rollback and reopen through native Rust

Note: Every listed artifact is checked after some reopen. The simulation crashes after every step of its script, but a step is not the same as a commit; no test kills the process at an arbitrary commit within a step.

### R4 A stale writer cannot write

A handle whose generation is behind the database's cannot commit, even a write that would otherwise succeed.

Primary:
- crates/sqlite/tests/client.rs::stale_writer_cannot_overwrite_committed_database

Supporting:
- none

Note: The name overstates it: the test fences the stale handle; the write itself would have succeeded.

## C. Compatibility

### C1 Wire format is byte-compatible with the reference

Field names, number spellings, key order and counter limits match the reference implementation byte for byte. Unknown fields in a request are preserved in the receipt hash so a retry with different unknown data is detected.

Primary:
- crates/core/tests/contracts.rs::wire_names_remain_legacy_and_counters_are_safe
- crates/core/tests/contracts.rs::batch_envelope_keeps_unknown_data_in_receipt_hash
- crates/core/tests/contracts.rs::canonical_numbers_match_javascript_and_utf16_key_order
- crates/core/tests/contracts.rs::checkpoint_wire_roundtrip_retains_legacy_fallback
- crates/core/tests/contracts.rs::receipt_distinguishes_missing_checkpoints_from_explicit_empty
- crates/core/tests/contracts.rs::shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries
- crates/core/tests/contracts.rs::identities_are_exact_normalized_and_independent_of_channels
- crates/core/tests/contracts.rs::server_pull_request_accepts_js_integer_number_spellings

Supporting:
- integration/persistence/server/runtime.test.mjs::loader safely converts PostgreSQL BigInt scalar and list values without widening wire range

### C2 Received states tolerate extra fields, not missing ones

A received state with fields the client does not know is accepted and the extras discarded. A state missing a declared required field is refused.

Primary:
- crates/core/tests/contracts.rs::received_state_supports_additive_schema_evolution
- crates/core/tests/contracts.rs::state_is_complete_but_patch_preserves_absent_and_null
- crates/server/tests/runtime.rs::ordered_slot_decodes_known_fields_and_ignores_new_fields

Supporting:
- none

### C3 Additive schema changes open; others fail without damage

Opening with a schema that adds a nullable column, or a non-nullable column with a default, succeeds and fills existing rows. Identity, type or index changes the reconciliation does not support fail to open and leave the file untouched. Queued operation bytes are never rewritten.

Primary:
- crates/sqlite/tests/ddl.rs::adds_missing_columns_to_both_tables_and_keeps_unknown_ones
- crates/sqlite/tests/ddl.rs::rejects_non_nullable_column_without_default_identity_change_and_type_change
- crates/sqlite/tests/ddl.rs::creates_model_before_and_framework_tables

Supporting:
- crates/compiler/tests/history.rs (compile-time fence on the .model source)

Note: Index changes and queued operation bytes across a schema change are not asserted; the reconciliation tests run with an empty queue.

### C4 Unsupported handler versions refuse the batch

A mutation naming a version the backend does not register refuses the whole batch with a stable code before any mutation runs.

Primary:
- integration/persistence/server/runtime.test.mjs::unsupported versions abort before handlers, invalid bodies settle with empty checkpoints

Supporting:
- none

Note: Asserts no handler runs; the stable code is not asserted, and there is no in-process test in `crates/server`.

## S. Developer surface

### S1 The compiler is deterministic and locates errors

The same `.model` input produces identical output; invalid input reports the file and position.

Primary:
- crates/compiler/tests/compiler.rs::schema_and_mutations
- crates/compiler/tests/compiler.rs::rejects_unknown_with_location
- crates/compiler/tests/compiler.rs::rejects_invalid_identity
- crates/compiler/tests/compiler.rs::rejects_dependency_typos
- crates/compiler/tests/compiler.rs::singular_inverse_requires_a_unique_foreign_key

Supporting:
- none

Note: Determinism (same input twice, identical bytes) is not asserted.

### S2 Generated APIs type-check positives and reject negatives

Generated TypeScript and Dart compile against valid usage and fail to compile against misuse: writing identity fields, patching disallowed fields, invalid enum literals, wrong filter types.

Primary:
- integration/generated-api/test.ts::compile-time API misuse rejected (`@ts-expect-error` block)

Supporting:
- none

Note: TypeScript only; no Dart negative examples.

### S3 Rust, TS and Dart clients produce identical state

One operation script from `fixtures/scenarios`, run directly through the Rust client, through the TypeScript client and through the Dart client, ends in byte-identical local state.

Primary:
- unproven

Supporting:
- none

Note: `fixtures/scenarios` holds three scripts and no runner.

### S4 One end-to-end flow per language is wired

A real HTTP backend, PostgreSQL and SQLite, driven once from Node and once from Dart, complete a write, push, pull and read.

Primary:
- integration/e2e/round-trip.test.mjs::initial sync makes server data visible (Node)
- integration/e2e/round-trip.test.mjs::cross-runtime Dart client converges with the same server (Dart)

Supporting:
- none

Note: The one guarantee whose primary proof is end-to-end by definition.

## N. Not guaranteed

- **N1 Bounded storage.** Tombstones and stamps are retained; there is no TTL cleanup. Cleanup requires proving late messages cannot arrive (channel generations, a follow-up).
- **N2 Per-mutation transactions.** The batch is the transaction unit on the server and the settlement unit on the client.
- **N3 Destructive schema migration.** Identity, type, removal and rename changes are not migrated; the answer today is a new database file (#20).
- **N4 Protection of direct writes.** A direct write is final only in the sense that no local action undoes it; any later authoritative content for that record replaces it.
- **N5 Channel-level authorization.** The framework authenticates the request and passes `userId` and `channel` to loaders and handlers; what a user may see or change is the application's decision inside them.
- **N6 Delivery latency.** Pull is a catch-up protocol; the live wake is a hint. Nothing bounds how long a change takes to reach a client.
