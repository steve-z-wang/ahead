//! Guarantees A1–A5 on the simulation.
use ahead_sim::{Action, MutationSpec, Sim, schema::entry_key};

fn setup(seed: u64) -> Sim {
    let mut sim = Sim::new(seed, 1);
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e1".into(),
            text: "base".into(),
        },
    })
    .unwrap();
    sim.settle();
    sim
}

/// A1: the value the server stored replaces the optimistic value; a later pending
/// edit replays on top.
#[test]
fn a1_server_value_overrides_optimism_and_later_edits_replay() {
    let mut sim = setup(31);
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::Edit {
            id: "e1".into(),
            text: "mine".into(),
        },
    })
    .unwrap();
    // The server "normalizes" by storing something else for the same mutation.
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.apply(Action::Deliver).unwrap();
    sim.host.set_state(
        &entry_key("e1"),
        Some(serde_json::json!({"id":"e1","text":"MINE","note":null})),
    );
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::Edit {
            id: "e1".into(),
            text: "later".into(),
        },
    })
    .unwrap();
    assert_eq!(sim.read_text(0, &entry_key("e1")).as_deref(), Some("later"));
    sim.apply(Action::Deliver).unwrap(); // receipt for batch 2
    sim.apply(Action::Pull {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.drain();
    assert_eq!(
        sim.read_text(0, &entry_key("e1")).as_deref(),
        Some("later"),
        "pending edit replays on the new base"
    );
    let base = sim
        .client(0)
        .read_sql("SELECT text FROM ahead_before_Entry", &[])
        .unwrap();
    assert_eq!(
        base[0]["text"], "MINE",
        "the base beneath it is the server's value"
    );
    sim.settle();
    sim.check().unwrap();
}

/// A2: a page whose fromCursor is behind is stale and does not move the cursor back;
/// a page ahead is refused.
#[test]
fn a2_pages_apply_only_in_cursor_order() {
    let mut sim = setup(32);
    sim.apply(Action::ServerChange {
        key: "Entry:e1".into(),
        text: Some("v2".into()),
        channels: vec!["a".into()],
    })
    .unwrap();
    sim.apply(Action::Pull {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Deliver).unwrap();
    sim.apply(Action::Duplicate).unwrap(); // the same page twice
    sim.apply(Action::Deliver).unwrap();
    assert_eq!(sim.client(0).cursor("a").unwrap(), 2);
    sim.apply(Action::Deliver).unwrap(); // stale duplicate
    assert_eq!(sim.client(0).cursor("a").unwrap(), 2);
    sim.check().unwrap();
}

/// A3: the ACK alone leaves the mutation pending; the page for the required
/// checkpoint settles it, in either order.
#[test]
fn a3_ack_alone_does_not_settle() {
    for page_first in [false, true] {
        let mut sim = setup(33);
        sim.apply(Action::Enqueue {
            client: 0,
            mutation: MutationSpec::Edit {
                id: "e1".into(),
                text: "x".into(),
            },
        })
        .unwrap();
        sim.apply(Action::Freeze { client: 0 }).unwrap();
        sim.apply(Action::Deliver).unwrap(); // receipt queued
        sim.apply(Action::Pull {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        sim.apply(Action::Hold).unwrap(); // receipt to the back
        sim.apply(Action::Deliver).unwrap(); // pull request -> page queued
        if page_first {
            sim.apply(Action::Hold).unwrap(); // receipt to the back again, page first
        }
        sim.apply(Action::Deliver).unwrap();
        let pending_after_first = sim.client(0).pending_count().unwrap();
        sim.apply(Action::Deliver).unwrap();
        assert_eq!(sim.client(0).pending_count().unwrap(), 0);
        if !page_first {
            assert_eq!(pending_after_first, 1, "ACK alone did not settle");
        } else {
            assert_eq!(pending_after_first, 1, "page alone did not settle either");
        }
        sim.check().unwrap();
    }
}

/// A4: a handler that notifies no channel is a server error; the batch aborts and
/// the client retries the same bytes.
#[test]
fn a4_handler_without_a_channel_aborts_the_batch() {
    let mut sim = Sim::new(34, 1);
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.host.set_membership(&entry_key("e9"), &[]);
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e9".into(),
            text: "nowhere".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    let frozen = sim
        .client(0)
        .freeze()
        .unwrap()
        .expect("still frozen, unacknowledged");
    sim.apply(Action::Deliver).unwrap();
    assert!(matches!(
        sim.net.pop(),
        Some(ahead_sim::net::Message::PushFailed { .. })
    ));
    assert!(
        sim.host.state(&entry_key("e9")).is_none(),
        "aborted batch left nothing"
    );
    assert_eq!(sim.client(0).pending_count().unwrap(), 1);
    assert_eq!(
        sim.client(0).freeze().unwrap().unwrap(),
        frozen,
        "the client retries the same bytes"
    );
    sim.check().unwrap();
}

/// A2 (open): a page pulled from channel "a" before an Unsubscribe/Subscribe cycle
/// can still be in flight when the resubscribe resets the channel's cursor to 0; it
/// must be dropped as stale, a page from a previous subscription, rather than
/// treated as a gap or applied against the reset cursor. No reproduction of this
/// existed in the repo; this is the nine-action repro from issue #32.
#[test]
#[ignore = "issue #32: a page from a previous subscription of the same channel is not \
recognized as stale; it can be delivered after Unsubscribe/Subscribe resets the cursor to \
0 and either errors as a gap or is wrongly applied, instead of being dropped. See A2 in \
docs/guarantees.md."]
fn a2_page_from_a_previous_subscription_is_stale_not_a_gap() {
    let mut sim = Sim::new(36, 1);
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e1".into(),
            text: "1".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.drain();
    sim.apply(Action::Pull {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.drain();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e2".into(),
            text: "2".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.drain();
    sim.apply(Action::Pull {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Unsubscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    assert!(
        sim.apply(Action::Deliver).is_ok(),
        "the client must drop the stale page rather than error"
    );
    assert_eq!(sim.client(0).cursor("a").unwrap(), 0);
}

/// A5: batch 2's checkpoint is reached before batch 1's; nothing settles until batch
/// 1's does, then both settle.
#[test]
fn a5_batches_settle_in_accepted_prefix_order() {
    let mut sim = Sim::new(35, 1);
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "slow".into(),
    })
    .unwrap();
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "fast".into(),
    })
    .unwrap();
    sim.host.set_membership(&entry_key("s"), &["slow"]);
    sim.host.set_membership(&entry_key("f"), &["fast"]);
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "s".into(),
            text: "1".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "f".into(),
            text: "2".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Deliver).unwrap(); // batch 1 executed, receipt 1 queued
    // freeze() is idempotent on an in-flight (unacknowledged) push: with receipt 1
    // still sitting in the network, not yet delivered to the client, push 1's
    // checkpoints are still empty, so freeze() here would just retry push 1, not
    // open batch 2. Deliver the receipt first so push 1 is acknowledged (its
    // checkpoint recorded, even though not yet met) before batch 2 is frozen.
    sim.apply(Action::Deliver).unwrap(); // receipt 1 delivered and acknowledged
    sim.apply(Action::Freeze { client: 0 }).unwrap(); // batch 2 opened
    sim.apply(Action::Deliver).unwrap(); // batch 2 executed, receipt 2 queued
    sim.apply(Action::Deliver).unwrap(); // receipt 2 delivered and acknowledged
    sim.apply(Action::Pull {
        client: 0,
        channel: "fast".into(),
    })
    .unwrap();
    sim.drain();
    let fast_cursor = sim.clients[0].receipts[&2]
        .required_checkpoints
        .iter()
        .find(|cp| cp.channel == "fast")
        .expect("batch 2's receipt requires a fast checkpoint")
        .cursor;
    assert_eq!(
        sim.client(0).cursor("fast").unwrap(),
        fast_cursor,
        "batch 2's checkpoint is genuinely reached before batch 1's"
    );
    assert_eq!(
        sim.client(0).pending_count().unwrap(),
        2,
        "batch 2 is ready but waits for batch 1"
    );
    sim.apply(Action::Pull {
        client: 0,
        channel: "slow".into(),
    })
    .unwrap();
    sim.drain();
    assert_eq!(sim.client(0).pending_count().unwrap(), 0);
    sim.check().unwrap();
}
