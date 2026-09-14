//! Guarantees D1–D6 from docs/guarantees.md as named scenarios on the simulation.
use ahead_sim::{Action, MutationSpec, Sim, schema::entry_key};

fn subscribe(sim: &mut Sim, client: usize, channels: &[&str]) {
    for c in channels {
        sim.apply(Action::Subscribe {
            client,
            channel: c.to_string(),
        })
        .unwrap();
    }
}
fn change(sim: &mut Sim, key: &str, text: Option<&str>, channels: &[&str]) {
    sim.apply(Action::ServerChange {
        key: key.into(),
        text: text.map(str::to_string),
        channels: channels.iter().map(|c| c.to_string()).collect(),
    })
    .unwrap();
}
fn pull(sim: &mut Sim, client: usize, channel: &str) {
    sim.apply(Action::Pull {
        client,
        channel: channel.into(),
    })
    .unwrap();
}

/// D1: two clients subscribed to one channel converge on every record after a mix
/// of local edits from both sides.
#[test]
fn d1_two_clients_on_one_channel_converge() {
    let mut sim = Sim::new(11, 2);
    subscribe(&mut sim, 0, &["a"]);
    subscribe(&mut sim, 1, &["a"]);
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e1".into(),
            text: "from 0".into(),
        },
    })
    .unwrap();
    sim.settle();
    sim.apply(Action::Enqueue {
        client: 1,
        mutation: MutationSpec::Edit {
            id: "e1".into(),
            text: "from 1".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::Edit {
            id: "e1".into(),
            text: "from 0 again".into(),
        },
    })
    .unwrap();
    sim.settle();
    let a = sim.read_text(0, &entry_key("e1"));
    let b = sim.read_text(1, &entry_key("e1"));
    assert_eq!(a, b);
    assert_eq!(
        a.as_deref(),
        Some(
            sim.host.state(&entry_key("e1")).unwrap()["text"]
                .as_str()
                .unwrap()
        )
    );
    sim.check().unwrap();
}

/// D2, fixtures/scenarios/delayed-page: B delivers stamp 8 first; A's page with stamp 7
/// arrives later and is discarded, but A's cursor advances and A's claim is recorded.
#[test]
fn d2_delayed_page_from_another_channel_cannot_regress_newer_content() {
    let mut sim = Sim::new(12, 1);
    subscribe(&mut sim, 0, &["a", "b"]);
    // The record lives on both channels. Snapshot a's page while the shared record
    // still holds "old" - a's pull request must be delivered (host.pull() reads the
    // live record at that point) before b's later change overwrites it, or a's page
    // would carry b's content instead of a genuinely stale copy.
    change(&mut sim, "Entry:e1", Some("old"), &["a"]);
    pull(&mut sim, 0, "a");
    sim.apply(Action::Deliver).unwrap(); // a's request -> a's page queued, snapshotting "old"
    change(&mut sim, "Entry:e1", Some("new"), &["b"]);
    pull(&mut sim, 0, "b"); // queue: [a's page, b's request]
    sim.apply(Action::Swap { i: 0, j: 1 }).unwrap(); // queue: [b's request, a's page]
    sim.apply(Action::Deliver).unwrap(); // b's request -> b's page queued (after a's page)
    sim.apply(Action::Swap { i: 0, j: 1 }).unwrap(); // queue: [b's page, a's page]
    sim.apply(Action::Deliver).unwrap(); // b's page
    assert_eq!(sim.read_text(0, &entry_key("e1")).as_deref(), Some("new"));
    sim.apply(Action::Deliver).unwrap(); // a's page, stale content
    assert_eq!(sim.read_text(0, &entry_key("e1")).as_deref(), Some("new"));
    assert_eq!(sim.client(0).cursor("a").unwrap(), 1);
    assert_eq!(sim.client(0).cursor("b").unwrap(), 1);
    let claims = sim.client(0).claims_of(&entry_key("e1")).unwrap();
    assert_eq!(claims, vec!["a".to_string(), "b".to_string()]);
    sim.check().unwrap();
}

/// D3: each (channel, record) publish allocates the next stamp - a notify that fans
/// out to two channels allocates one stamp per channel it touches, matching
/// packages/persistence-prisma/index.mts and the record-stamp spec; each channel's
/// cursor still advances on its own.
#[test]
fn d3_each_channel_publish_allocates_its_own_stamp() {
    let mut sim = Sim::new(13, 1);
    subscribe(&mut sim, 0, &["a", "b"]);
    change(&mut sim, "Entry:e1", Some("x"), &["a"]); // a:1 stamp 1
    change(&mut sim, "Entry:e1", Some("y"), &["a", "b"]); // a:2 stamp 2 on a, then b:1 stamp 3 on b
    assert_eq!(sim.host.head("a"), 2);
    assert_eq!(sim.host.head("b"), 1);
    assert_eq!(
        sim.host.stamp(&entry_key("e1")),
        3,
        "one stamp per (channel, record) publish, as the record-stamp design allocates"
    );
    sim.settle();
    assert_eq!(sim.read_text(0, &entry_key("e1")).as_deref(), Some("y"));
    assert_eq!(sim.client(0).cursor("a").unwrap(), 2);
    assert_eq!(sim.client(0).cursor("b").unwrap(), 1);
    sim.check().unwrap();
}

/// D4: A -> B then B -> A, with the source channel's delete arriving after the
/// destination's upsert both times.
#[test]
fn d4_move_between_channels_and_back() {
    let mut sim = Sim::new(14, 1);
    subscribe(&mut sim, 0, &["a", "b"]);
    change(&mut sim, "Entry:e1", Some("in a"), &["a"]);
    sim.settle();
    // Move to b: b gets the upsert, a gets a delete (loader returns null for a's row
    // because membership moved). Membership is now explicit and channel-aware
    // (MemHost's "load" arm), so a's page genuinely sees the record as absent once
    // membership excludes it - not merely a stale copy of a's own delete.
    sim.host.set_membership(&entry_key("e1"), &["b"]);
    change(&mut sim, "Entry:e1", None, &["a"]); // a: delete (stamp 2)
    change(&mut sim, "Entry:e1", Some("in b"), &["b"]); // b: upsert (stamp 3)
    pull(&mut sim, 0, "a");
    pull(&mut sim, 0, "b");
    sim.apply(Action::Deliver).unwrap();
    sim.apply(Action::Deliver).unwrap();
    sim.apply(Action::Swap { i: 0, j: 1 }).unwrap(); // b's page first
    sim.drain();
    assert_eq!(sim.read_text(0, &entry_key("e1")).as_deref(), Some("in b"));
    assert_eq!(
        sim.client(0).claims_of(&entry_key("e1")).unwrap(),
        vec!["b".to_string()]
    );
    // Move back to a.
    sim.host.set_membership(&entry_key("e1"), &["a"]);
    change(&mut sim, "Entry:e1", None, &["b"]); // b: delete (stamp 4)
    change(&mut sim, "Entry:e1", Some("back in a"), &["a"]); // a: upsert (stamp 5)
    sim.settle();
    assert_eq!(
        sim.read_text(0, &entry_key("e1")).as_deref(),
        Some("back in a")
    );
    assert_eq!(
        sim.client(0).claims_of(&entry_key("e1")).unwrap(),
        vec!["a".to_string()]
    );
    sim.check().unwrap();
}

/// D5, fixtures/scenarios/delete-across-channels: the delete is notified to both
/// channels; B delivers it first; an older upsert on A is discarded; A's delete removes
/// the last claim and the tombstone.
#[test]
fn d5_delete_across_channels_keeps_a_tombstone_until_every_claim_confirms() {
    let mut sim = Sim::new(15, 1);
    subscribe(&mut sim, 0, &["a", "b"]);
    change(&mut sim, "Entry:e1", Some("v1"), &["a", "b"]); // stamps 1 (a), 2 (b)
    sim.settle();
    change(&mut sim, "Entry:e1", Some("v2"), &["a"]); // stamp 3 on a (the delayed upsert)
    change(&mut sim, "Entry:e1", None, &["b", "a"]); // stamps 4 (b), 5 (a): delete
    pull(&mut sim, 0, "b");
    sim.drain();
    assert_eq!(
        sim.read_text(0, &entry_key("e1")),
        None,
        "b's delete removes the row"
    );
    let claims = sim.client(0).claims_of(&entry_key("e1")).unwrap();
    assert_eq!(
        claims,
        vec!["a".to_string()],
        "a's claim remains as the tombstone marker"
    );
    let tomb = sim
        .client(0)
        .read_sql("SELECT stamp FROM ahead_record WHERE model='Entry'", &[])
        .unwrap();
    assert_eq!(tomb.len(), 1);
    pull(&mut sim, 0, "a"); // a's page carries only its latest row: the delete at stamp 5
    sim.drain();
    assert_eq!(sim.read_text(0, &entry_key("e1")), None);
    assert!(
        sim.client(0)
            .claims_of(&entry_key("e1"))
            .unwrap()
            .is_empty()
    );
    let tomb = sim
        .client(0)
        .read_sql("SELECT stamp FROM ahead_record WHERE model='Entry'", &[])
        .unwrap();
    assert!(
        tomb.is_empty(),
        "tombstone dropped when the last claim confirmed"
    );
    sim.check().unwrap();
}

/// D6: unsubscribing drops records only that channel claimed and keeps the rest; a
/// loader null is applied as a delete.
#[test]
fn d6_unsubscribe_keeps_what_other_channels_claim() {
    let mut sim = Sim::new(16, 1);
    subscribe(&mut sim, 0, &["a", "b"]);
    change(&mut sim, "Entry:e1", Some("shared"), &["a", "b"]);
    change(&mut sim, "Entry:e2", Some("only a"), &["a"]);
    sim.settle();
    assert_eq!(
        sim.read_text(0, &entry_key("e2")).as_deref(),
        Some("only a")
    );
    sim.apply(Action::Unsubscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    assert_eq!(
        sim.read_text(0, &entry_key("e1")).as_deref(),
        Some("shared")
    );
    assert_eq!(sim.read_text(0, &entry_key("e2")), None);
    assert_eq!(
        sim.client(0).claims_of(&entry_key("e1")).unwrap(),
        vec!["b".to_string()]
    );
    // Null load is a delete.
    change(&mut sim, "Entry:e1", None, &["b"]);
    sim.settle();
    assert_eq!(sim.read_text(0, &entry_key("e1")), None);
    sim.check().unwrap();
}
