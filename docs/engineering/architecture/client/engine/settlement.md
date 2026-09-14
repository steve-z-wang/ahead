# Settlement

Process decoded receipts and cursors to confirm mutations, roll back rejections and replay pending changes.

Current code: [client/push.rs](../../../../../crates/client/src/push.rs) (`acknowledge`, `awaitable`, `settle`, `settle_satisfied`, `settle_push`, `remove_rejected`); replay in [client/mutate.rs](../../../../../crates/client/src/mutate.rs) (`rebuild`); unsubscribe interplay in `unsubscribe`.

## 1. Introduction and Goals

- Replace optimism with the server's answer exactly once, in batch order, only after the authoritative content the server promised has arrived.

## 3. Context and Scope

- Inputs: a decoded [PushReceipt](../../protocol/push.md) for a push number; cursor advances from [Pull](pull.md); unsubscribes.
- State: `ahead_push_checkpoint (push, channel, cursor)`, `ahead_rejection (ordinal, name, code, detail)`, the queue tables and before images.
- Callers: `Client::acknowledge`, `apply_page` (after every change), `Client::open`, `unsubscribe`, `drop_mutation`.

## 5. Building Block View

- `acknowledge(push, receipt)`: if checkpoints already exist for the push, the receipt must reproduce them (`receipt changed`) and is otherwise a no-op; an unknown push is `unknown batch receipt`; rejection ordinals must belong to the batch. Rejected mutations are removed first; then, if nothing awaitable remains or the batch is empty, the push settles at once; otherwise the awaitable checkpoints are stored and `settle` runs.
- `awaitable`: keeps only checkpoints on channels with a subscription row; a checkpoint on any other channel can never be met and is dropped (the guarantee A3 exception).
- `settle`: loop over push numbers in order; stop at the first push that is in flight (no checkpoint rows, unless an unsubscribe just removed them) or whose checkpoints are not all reached by the local cursors; otherwise `settle_push` (guarantee A5).
- `settle_push`: fold companion operations into before images (cascading companion deletes to descendants) unless the record is also a wire row, delete the batch's mutations and checkpoints, then `rebuild` every touched record so the before image becomes the visible row and is dropped when no operations remain.
- `remove_rejected`: transitively add lifecycle dependents with code `dependency.rejected`, store `{ordinal, code, mutation, records}` in `ahead_rejection`, delete the mutations, `rebuild` every touched record from its before image (guarantee P5). The application reads `rejections()`/`record_status` and calls `dismiss_rejection`.
- `unsubscribe(channel)`: release the channel's claims, drop unclaimed records, delete the subscription row, delete the channel's checkpoint rows and settle the pushes that were waiting on them.

## 6. Runtime View

- Receipt-then-page and page-then-receipt both end settled: the checkpoint rows wait for the cursor, and every applied change re-runs `settle` (guarantee A3).
- A later batch whose checkpoints are all reached does not settle while an earlier batch waits (guarantee A5).

## 10. Quality Requirements

- A1, A3, A5, P5: [crates/sim/tests/authority.rs](../../../../../crates/sim/tests/authority.rs) `a1_…`, `a3_…`, `a5_…`; [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p5_rejection_rolls_back_and_rejects_dependents`; [sqlite/tests/push.rs](../../../../../crates/sqlite/tests/push.rs) `accepted_batches_only_settle_in_ready_prefix`, `rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox`, `record_status_reports_phases_and_duplicate_ack_is_idempotent`, `accepted_wire_rows_do_not_promote_companion_over_server_authority`; [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs) `unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped`; [sqlite/tests/query.rs](../../../../../crates/sqlite/tests/query.rs) `transport_pulls_only_subscribed_channels_and_unawaitable_checkpoints_settle`.

## 11. Risks and Technical Debt

- **Potential risk: settling without authority reverts the record.** When the receipt's checkpoints name only channels the client is not subscribed to, the push settles immediately and `rebuild` restores the before image: an updated row reverts to its pre-mutation value and a locally created row disappears, even though the server accepted the mutation. The record reappears only if some subscribed channel later delivers it. Evidence: `awaitable` plus `settle_push` → `rebuild`; confirmed by executing a throwaway test on this branch (update reverted to the seeded value, created row read `None`); the existing test asserts only `pending_count == 0`. Whether this is the intended contract for records outside the client's channels needs deciding; the guarantees page now names the consequence under A3.
- **Confirmed limitation: only lifecycle dependents are rejected with their parent.** A sequence dependent of a rejected mutation is still sent. Evidence: `remove_rejected` filters `lifecycle_dependencies` only. This matches the P5 wording; noted because the two dependency kinds are easy to confuse.
- **Confirmed debt: `ahead_rejection.detail` stores the whole mutation JSON.** The inbox grows with mutation size and is retained until dismissed; there is no bound. Evidence: `remove_rejected`.
