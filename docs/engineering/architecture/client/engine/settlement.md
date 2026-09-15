# Settlement

## 1. Introduction and Goals

A local write is shown to the user before the server has seen it. Settlement is the moment that optimism ends: the client learns the server's answer and replaces the optimistic row with the authoritative one, or rolls the write back. Its job is to do this exactly once per mutation, in the order batches were sent, and only after the content the server promised has actually arrived.

The rest of the engine sets settlement up. [Local operations](local-operations/README.md) keeps a *before image* (the last server-known row) under every record with pending mutations; [Push](push/README.md) freezes mutations into numbered batches; [Pull](pull.md) applies server pages and moves per-channel cursors. Settlement reads all three.

## 3. Context and Scope

Settlement is triggered by three events and works entirely inside the engine's transaction:

| Event | What arrives | What settlement does |
| --- | --- | --- |
| A receipt for a batch ([Protocol / Push](../../protocol/push.md)) | rejections and *required checkpoints* (channel → cursor) | removes rejected mutations, records what the accepted ones are waiting for, then tries to settle |
| A cursor advance from [Pull](pull.md) | one channel moved forward | tries to settle, because a checkpoint may now be reached |
| An unsubscribe | one channel will never move again | drops that channel's checkpoints and settles what they were holding |

State it owns: `ahead_push_checkpoint` (per batch, the cursor each channel must reach) and `ahead_rejection` (the durable inbox of rejected mutations). It deletes rows from the queue tables owned by [Queue](push/queue.md) and rewrites records through the replay logic of [Local operations](local-operations/README.md).

## 5. Building Block View

Settlement has no internal parts. It is the receipt, settle and rejection functions in [client/push.rs](../../../../../crates/client/src/push.rs) (`acknowledge`, `awaitable`, `settle`, `settle_push`, `remove_rejected`), the replay function `rebuild` in [client/mutate.rs](../../../../../crates/client/src/mutate.rs), and the unsubscribe path in the same file.

## 6. Runtime View

### Receiving a receipt

The first receipt for a batch is authoritative. A receipt for an unknown batch, or one whose rejections name an ordinal outside the batch, is refused. If the same batch is acknowledged again (a retried push whose first receipt was lost), the receipt must describe the same checkpoints and is otherwise ignored.

Rejected mutations are removed first (see below). For the accepted ones, the receipt's checkpoints are filtered: a cursor only moves for channels the client is subscribed to, so a checkpoint on any other channel could never be met and is dropped. What happens next depends on what is left:

- Some checkpoints remain: they are stored, and settlement waits for the cursors.
- Every checkpoint was dropped, or no accepted mutation remains in the batch: the batch settles immediately. Section 11 describes what the user sees in that case.

### Waiting and settling in order

Settlement walks batches by push number and stops at the first one that is *in flight* (sent, no receipt yet) or still waiting on a cursor. A later batch never settles before an earlier one, even if its own checkpoints are already reached (guarantee A5); this keeps replayed edits on the right base. Every cursor advance re-runs this walk.

The order in which the receipt and the page arrive does not matter. Two things move independently: the *authoritative base* (the before image, updated by pages) and the *visible row* (what the user sees, rewritten only at settlement). Both sequences end in the same state:

```
receipt first                                    page first
─────────────                                    ──────────
receipt: checkpoint {a: 5} stored                page a 4→5: base = server row
   visible row: still the local edit                 visible row: still the local edit
page a 4→5: base = server row                    receipt: checkpoint {a: 5} stored
   settle: cursor 5 reached → batch settles          settle: cursor already 5 → batch settles
visible row = server row, pending 0              visible row = server row, pending 0
```

Because a page writes the server's row into the base rather than the visible row while the record is still dirty, the user never sees the server value flash in and the local edit reappear.

### Replacing the optimistic row

- *Accepted.* The batch's mutations are deleted from the queue, then every touched record is rebuilt: the base becomes the visible row, any still-pending later mutations are replayed on top, and the base is dropped once nothing pending touches the record (guarantee A1). Companion operations, the local-only writes attached to a mutation, are folded into the base first so they become local truth, unless the same record also carries a wire operation, in which case the server's row wins.
- *Rejected.* The mutation and every mutation whose lifecycle depends on it (for example an edit of a record the rejected mutation created) are removed. Each gets a durable inbox entry with its code (`dependency.rejected` for the dependents) and the records it touched, and the touched records are rebuilt from their base, which undoes the optimistic change (guarantee P5). The application reads the inbox through `rejections()` or `record_status()` and clears entries with `dismiss_rejection`.

### Unsubscribing

Nothing will advance an unsubscribed channel's cursor again, so waiting would be forever. The channel's checkpoint rows are deleted and the batches they were holding are settled as if the checkpoint had been met.

## 10. Quality Requirements

- **Optimism is removed only after every stored checkpoint is met, regardless of arrival order** (guarantee A3). Evidence: [crates/sim/tests/authority.rs](../../../../../crates/sim/tests/authority.rs) `a3_ack_alone_does_not_settle`; [sqlite/tests/push.rs](../../../../../crates/sqlite/tests/push.rs) `offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull`, `pull_before_ack_and_later_local_edit_replay_in_order`, `record_status_reports_phases_and_duplicate_ack_is_idempotent`.
- **Batches settle in accepted-prefix order** (guarantee A5). Evidence: `a5_batches_settle_in_accepted_prefix_order`; `accepted_batches_only_settle_in_ready_prefix`.
- **The server's value replaces the optimistic one, and later local edits replay on top** (guarantee A1). Evidence: `a1_server_value_overrides_optimism_and_later_edits_replay`; `accepted_wire_rows_do_not_promote_companion_over_server_authority`.
- **A rejection rolls back the mutation and its lifecycle dependents, and the reason survives restart until dismissed** (guarantee P5). Evidence: [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p5_rejection_rolls_back_and_rejects_dependents`; `rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox`.
- **Unsubscribing settles the batches that were waiting on that channel.** Evidence: [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs) `unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped`.
- **When none of a receipt's checkpoints can be awaited, the batch settles at once.** Evidence: [sqlite/tests/query.rs](../../../../../crates/sqlite/tests/query.rs) `transport_pulls_only_subscribed_channels_and_unawaitable_checkpoints_settle`. This test asserts the pending count only; see section 11.

All tests above were read, not executed, in this review.

## 11. Risks and Technical Debt

**Potential risk: settling without authority reverts the record.**

- *Condition.* Every checkpoint in a receipt names a channel the client is not subscribed to, so all are dropped and the batch settles at once. In practice: a client that subscribes to nothing, or a handler that publishes the record only to channels this client does not follow.
- *Consequence.* No page ever delivers the server's version, so the rebuild restores the base as it was before the mutation: an updated row reverts to its pre-mutation value, and a locally created row disappears, even though the server accepted the mutation. The record reappears only if some subscribed channel later delivers it.
- *Status.* Owned here; the guarantees page notes the consequence under A3. **To confirm:** whether this is the intended contract for records outside the client's channels, or whether such a mutation should keep its optimistic row until a page arrives.
- *Evidence.* Code path: `awaitable` and `settle_push` in [client/push.rs](../../../../../crates/client/src/push.rs), then `rebuild` in [client/mutate.rs](../../../../../crates/client/src/mutate.rs). Executed once on this branch with the test below (`cargo test -p ahead-sqlite --test zz_scratch_probe -- --nocapture`, passed, file not committed). Observed: the updated row read `text: "A"` after settlement; the created row read `None`.

<details>
<summary>Reproduction: a test file for <code>crates/sqlite/tests/</code> using the existing <code>common</code> helpers</summary>

```rust
mod common;
use ahead_client::*;
use common::*;
use serde_json::json;

fn receipt(channel: &str, cursor: u64) -> PushReceipt {
    PushReceipt {
        required_channel: channel.into(), required_cursor: cursor,
        required_checkpoints: vec![ChannelCheckpoint { channel: channel.into(), cursor }],
        rejections: vec![],
    }
}

#[test]
fn settling_without_authority_reverts_the_record() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");                        // direct create; no subscription at all
    c.transaction(|tx| tx.enqueue(mutation("B")).map(|_| ())).unwrap();
    c.freeze().unwrap().unwrap();
    c.acknowledge(1, receipt("other", 3)).unwrap();   // "other" is not subscribed
    assert_eq!(c.pending_count().unwrap(), 0);
    println!("{:?}", c.read(&key()).unwrap());        // text is "A" again, not "B"

    let created = schema().record_key("Entry", &json!({"id":"n"})).unwrap();
    c.transaction(|tx| tx.enqueue(Mutation::new("Create", vec![Operation {
        model: "Entry".into(), op: OperationKind::Create,
        identity: json!({"id":"n"}), values: Some(json!({"text":"new","note":null})),
    }])).map(|_| ())).unwrap();
    c.freeze().unwrap().unwrap();
    c.acknowledge(2, receipt("other", 4)).unwrap();
    println!("{:?}", c.read(&created).unwrap());      // None: the row is gone
}
```

</details>

**Accepted limitation.** Only lifecycle dependents are rejected with their parent; a sequence dependent of a rejected mutation is still sent. This matches guarantee P5 as written and is noted because the two dependency kinds are easy to confuse ([Dependencies](push/dependencies.md)).
