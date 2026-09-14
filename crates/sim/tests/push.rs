//! Guarantees P1–P6 on the simulation.
use ahead_core::PushReceipt;
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
fn edit(sim: &mut Sim, text: &str) {
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::Edit {
            id: "e1".into(),
            text: text.into(),
        },
    })
    .unwrap();
}

/// P1: a push whose receipt is lost is re-sent with the same bytes and executes once.
#[test]
fn p1_lost_receipt_retry_executes_once() {
    let mut sim = setup(21);
    edit(&mut sim, "x");
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.apply(Action::Deliver).unwrap(); // executes, receipt queued
    assert_eq!(sim.host.handler_calls(), 2);
    sim.apply(Action::Drop).unwrap(); // receipt lost
    sim.apply(Action::Crash { client: 0 }).unwrap();
    sim.apply(Action::Restart { client: 0 }).unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap(); // same batch again
    sim.apply(Action::Deliver).unwrap();
    assert_eq!(
        sim.host.handler_calls(),
        2,
        "cached receipt, no second execution"
    );
    sim.settle();
    assert_eq!(sim.client(0).pending_count().unwrap(), 0);
    sim.check().unwrap();
}

/// P2: the client numbers batches contiguously; the server refuses a gap and an
/// overlap in process.
#[test]
fn p2_contiguous_sequence_and_server_refuses_gap_and_overlap() {
    let mut sim = setup(22);
    edit(&mut sim, "one");
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.settle();
    edit(&mut sim, "two");
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    sim.settle();
    let sequences: Vec<u64> = sim.clients[0].receipts.keys().copied().collect();
    assert_eq!(sequences, vec![1, 2, 3]);
    // Hand-built gap and overlap against the host directly.
    let id = sim.client(0).client_id().to_string();
    let batch = |seq: u64| {
        let body = serde_json::json!({"clientId":id,"batchSequence":seq,"mutations":[{"ordinal":99,"name":"Edit","version":1,"operations":[{"model":"Entry","op":"update","identity":{"id":"e1"},"values":{"text":"z"}}]}]});
        ahead_core::PushRequest::decode(ahead_core::canonical_json(&body).unwrap().as_bytes())
            .unwrap()
            .encode()
            .unwrap()
    };
    assert_eq!(sim.host.push("u", &batch(5)).unwrap_err(), "gap");
    assert_eq!(sim.host.push("u", &batch(2)).unwrap_err(), "overlap");
    sim.check().unwrap();
}

/// P3 is proven in crates/sqlite/tests/push.rs; the simulation adds the cross-batch
/// clause: a lifecycle dependent is sent only after its parent's receipt arrives.
#[test]
fn p3_lifecycle_dependent_waits_for_the_parent_receipt() {
    let mut sim = Sim::new(23, 1);
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e1".into(),
            text: "new".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateComment {
            id: "c1".into(),
            entry: "e1".into(),
            text: "child".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    assert_eq!(sim.net.len(), 1);
    let bytes = match sim.net.pop().unwrap() {
        ahead_sim::net::Message::Push { bytes, .. } => bytes,
        _ => unreachable!(),
    };
    let first = ahead_core::PushRequest::decode(&bytes).unwrap();
    assert_eq!(
        first.mutations.len(),
        1,
        "the child is not in the parent's batch"
    );
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    // freeze() is idempotent while a push is in flight (this is the P1 retry
    // mechanism): with no receipt yet for push 1, it re-encodes and re-sends that
    // same still-unacknowledged batch rather than opening a new one, so the queue
    // gains one message again here - but it is the parent's batch, byte-identical
    // to `first`, not a new batch carrying the child.
    assert_eq!(
        sim.net.len(),
        1,
        "freeze retries the parent's unacknowledged push rather than sending nothing"
    );
    let retried = match sim.net.pop().unwrap() {
        ahead_sim::net::Message::Push { bytes, .. } => bytes,
        _ => unreachable!(),
    };
    assert_eq!(
        retried,
        first.encode().unwrap(),
        "the retry is byte-identical to the parent's push; the child never entered a batch"
    );
    // Re-send the parent and let it through.
    sim.net.send(ahead_sim::net::Message::Push {
        client: 0,
        bytes: first.encode().unwrap(),
    });
    sim.drain();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    assert_eq!(sim.net.len(), 1, "now the child goes");
    sim.settle();
    sim.check().unwrap();
}

/// P4: the frozen bytes are identical across a crash and across a duplicate freeze.
#[test]
fn p4_frozen_bytes_are_stable() {
    let mut sim = setup(24);
    edit(&mut sim, "x");
    let a = sim.client(0).freeze().unwrap().unwrap();
    let b = sim.client(0).freeze().unwrap().unwrap();
    assert_eq!(a, b);
    sim.apply(Action::Crash { client: 0 }).unwrap();
    sim.apply(Action::Restart { client: 0 }).unwrap();
    let c = sim.client(0).freeze().unwrap().unwrap();
    assert_eq!(a, c);
    sim.check().unwrap();
}

/// P5: a rejected mutation rolls back and its lifecycle dependent is rejected with it.
#[test]
fn p5_rejection_rolls_back_and_rejects_dependents() {
    let mut sim = Sim::new(25, 1);
    sim.apply(Action::Subscribe {
        client: 0,
        channel: "a".into(),
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateEntry {
            id: "e1".into(),
            text: "new".into(),
        },
    })
    .unwrap();
    sim.apply(Action::Enqueue {
        client: 0,
        mutation: MutationSpec::CreateComment {
            id: "c1".into(),
            entry: "e1".into(),
            text: "child".into(),
        },
    })
    .unwrap();
    sim.apply(Action::RejectNext {
        code: "entry.denied".into(),
    })
    .unwrap();
    sim.settle();
    assert_eq!(
        sim.read_text(0, &entry_key("e1")),
        None,
        "parent rolled back"
    );
    assert_eq!(
        sim.read_text(0, &ahead_sim::schema::comment_key("c1")),
        None,
        "dependent rolled back"
    );
    let rejections = sim.client(0).rejections().unwrap();
    assert_eq!(rejections.len(), 2);
    assert!(rejections.iter().any(|r| r.code == "entry.denied"));
    assert!(rejections.iter().any(|r| r.code == "dependency.rejected"));
    assert_eq!(sim.host.handler_calls(), 1, "the dependent was never sent");
    sim.check().unwrap();
}

/// P6: a handler failure aborts the batch; the business state and channel head are
/// untouched and the client retries the same bytes.
#[test]
fn p6_handler_failure_aborts_the_batch_and_the_client_retries() {
    let mut sim = setup(26);
    edit(&mut sim, "x");
    sim.apply(Action::FailNext).unwrap();
    sim.apply(Action::Freeze { client: 0 }).unwrap();
    let bytes = match sim.net.pop().unwrap() {
        ahead_sim::net::Message::Push { bytes, .. } => bytes,
        _ => unreachable!(),
    };
    sim.net.send(ahead_sim::net::Message::Push {
        client: 0,
        bytes: bytes.clone(),
    });
    sim.apply(Action::Deliver).unwrap();
    assert_eq!(sim.host.state(&entry_key("e1")).unwrap()["text"], "base");
    assert_eq!(sim.host.head("a"), 1);
    sim.drain(); // PushFailed is consumed
    assert_eq!(
        sim.client(0).freeze().unwrap().unwrap(),
        bytes,
        "same bytes on retry"
    );
    sim.settle();
    assert_eq!(sim.host.state(&entry_key("e1")).unwrap()["text"], "x");
    sim.check().unwrap();
}

/// Receipts the client holds are exactly what the server stored.
#[test]
fn receipts_round_trip() {
    let mut sim = setup(27);
    edit(&mut sim, "x");
    sim.settle();
    let r: &PushReceipt = sim.clients[0].receipts.get(&2).unwrap();
    assert_eq!(r.required_checkpoints.len(), 1);
    sim.check().unwrap();
}
