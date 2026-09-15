mod common;
use ahead_client::*;
use ahead_sqlite::SqliteStore;
use common::*;
use serde_json::{Value, json};

fn receipt(channel: &str, cursor: u64) -> PushReceipt {
    PushReceipt {
        required_channel: channel.into(),
        required_cursor: cursor,
        required_checkpoints: vec![ChannelCheckpoint {
            channel: channel.into(),
            cursor,
        }],
        rejections: vec![],
    }
}

#[test]
fn offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("client.sqlite");
    let mut c = open(&path);
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    let bytes = c.freeze().unwrap().unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    drop(c);
    let mut c = open(&path);
    assert_eq!(
        c.freeze().unwrap().unwrap(),
        bytes,
        "re-encoded from rows, byte for byte"
    );
    c.acknowledge(1, receipt("book", 2)).unwrap();
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(table_count(&mut c, "ahead_push_checkpoint"), 1);
    c.apply_page(page("book", 1, 2, Some("NORMALIZED")))
        .unwrap();
    assert_eq!(c.pending_count().unwrap(), 0);
    assert_eq!(table_count(&mut c, "ahead_push_checkpoint"), 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NORMALIZED");
    assert_eq!(c.before_image_count().unwrap(), 0);
}

#[test]
fn pull_before_ack_and_later_local_edit_replay_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("C"))?;
        Ok(())
    })
    .unwrap();
    c.apply_page(page("book", 1, 2, Some("B"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
    c.acknowledge(1, receipt("book", 2)).unwrap();
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
}

#[test]
fn rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        tx.direct(Operation {
            values: Some(json!({"note":"local"})),
            ..update("unused")
        })
    })
    .unwrap();
    c.freeze().unwrap();
    let mut ack = receipt("book", 1);
    ack.rejections.push(Rejection {
        ordinal: 1,
        code: "denied".into(),
    });
    c.acknowledge(1, ack).unwrap();
    assert_eq!(
        c.read(&key()).unwrap().unwrap(),
        json!({"id":"e","text":"A","note":"local"})
    );
    assert_eq!(
        table_count(&mut c, "ahead_push_checkpoint"),
        0,
        "all rejected settles at once"
    );
    drop(c);
    let mut c = open(&path);
    assert_eq!(c.rejections().unwrap().len(), 1);
    let status = c.record_status(&key()).unwrap();
    assert_eq!(status["rejections"][0]["mutation"]["name"], "Edit");
    assert_eq!(status["rejections"][0]["code"], "denied");
    c.dismiss_rejection(1).unwrap();
    assert!(c.rejections().unwrap().is_empty());
}

#[test]
fn accepted_batches_only_settle_in_ready_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    subscribe(&mut c, "slow");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap();
    c.acknowledge(1, receipt("slow", 9)).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("C"))?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap();
    c.acknowledge(2, receipt("book", 1)).unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);
    c.apply_page(PullPage {
        channel: "slow".into(),
        from_cursor: 0,
        to_cursor: 9,
        changes: vec![],
    })
    .unwrap();
    assert_eq!(c.pending_count().unwrap(), 0);
}

#[test]
fn failed_prerequisite_stays_optimistic_independent_work_can_overtake() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        let mut m = mutation("B");
        m.prerequisites.push("upload:1".into());
        tx.enqueue(m)?;
        tx.enqueue(mutation("C"))?;
        Ok(())
    })
    .unwrap();
    let request = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(request.mutations.len(), 1);
    assert_eq!(request.mutations[0].ordinal, 2);
    c.set_readiness("upload:1", Readiness::Failed).unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);
    assert_eq!(c.pending_tasks().unwrap()[0]["state"], "failed");
    c.set_readiness("upload:1", Readiness::Ready).unwrap();
    assert!(c.pending_tasks().unwrap().is_empty());
}

#[test]
fn lifecycle_dependency_waits_for_parent_ack() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        let parent = tx.enqueue(mutation("B"))?;
        let mut child = mutation("C");
        child.lifecycle_dependencies.push(parent);
        tx.enqueue(child)?;
        Ok(())
    })
    .unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations.len(), 1);
    c.acknowledge(1, receipt("book", 9)).unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations[0].ordinal, 2);
}

#[test]
fn accepted_wire_rows_do_not_promote_companion_over_server_authority() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        let mut m = mutation("B");
        m.companion.push(update("COMPANION"));
        tx.enqueue(m)?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap();
    c.acknowledge(1, receipt("book", 2)).unwrap();
    c.apply_page(page("book", 1, 2, Some("SERVER"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "SERVER");
}

#[test]
fn schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut value = serde_json::to_value(schema()).unwrap();
    value["requirements"] =
        json!([{"model":"Entry","field":"note","name":"Upload","arguments":{"key":"self"}}]);
    value["prerequisites"] = json!([{"name":"Upload","fields":[{"name":"key","type":"String"}]}]);
    let schema = Schema::from_value(value).unwrap();
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), schema.clone()).unwrap();
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(Mutation::new(
            "Edit",
            vec![Operation {
                values: Some(json!({"note":"asset"})),
                ..update("x")
            }],
        ))?;
        Ok(())
    })
    .unwrap();
    assert!(c.freeze().unwrap().is_none());
    let tasks = c.pending_tasks().unwrap();
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0]["arguments"], json!({"key":"asset"}));
    let key = tasks[0]["key"].as_str().unwrap().to_string();
    drop(c);
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), schema).unwrap();
    assert_eq!(c.pending_tasks().unwrap().len(), 1);
    c.set_readiness(&key, Readiness::Ready).unwrap();
    assert!(c.freeze().unwrap().is_some());
}

#[test]
fn byte_budget_skips_large_candidate_but_always_allows_one() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("small"))?;
        tx.enqueue(mutation(&"x".repeat(2000)))?;
        tx.enqueue(mutation("third"))?;
        Ok(())
    })
    .unwrap();
    let first = PushRequest::decode(&c.freeze_with_limit(600).unwrap().unwrap()).unwrap();
    assert_eq!(
        first
            .mutations
            .iter()
            .map(|m| m.ordinal)
            .collect::<Vec<_>>(),
        vec![1, 3]
    );
    c.acknowledge(1, receipt("book", 1)).unwrap();
    let second = PushRequest::decode(&c.freeze_with_limit(1).unwrap().unwrap()).unwrap();
    assert_eq!(second.mutations[0].ordinal, 2);
}

#[test]
fn schema_sequence_relationship_freezes_dependent_with_its_predecessor() {
    let dir = tempfile::tempdir().unwrap();
    let mut value = serde_json::to_value(family_schema()).unwrap();
    value["clientPolicies"] = json!([
    {"name":"Rename","version":1,"slots":[{"name":"book","model":"Book","operation":"update","cardinality":"single"}]},
    {"name":"CommentEdit","version":1,"slots":[{"name":"comment","model":"Comment","operation":"update","cardinality":"single"}],"sequence":{"after":[{"name":"Rename","arguments":{"book":"comment.book"}}]}}
    ]);
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        Schema::from_value(value).unwrap(),
    )
    .unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"B"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"C"})))?;
        let mut m = Mutation::new(
            "Rename",
            vec![Operation {
                model: "Book".into(),
                op: OperationKind::Update,
                identity: json!({"id":"b"}),
                values: Some(json!({"title":"D"})),
            }],
        );
        m.prerequisites.push("pending".into());
        tx.enqueue(m)?;
        tx.enqueue(Mutation::new(
            "CommentEdit",
            vec![Operation {
                model: "Comment".into(),
                op: OperationKind::Update,
                identity: json!({"id":"c"}),
                values: Some(json!({"text":"E"})),
            }],
        ))?;
        Ok(())
    })
    .unwrap();
    assert!(c.freeze().unwrap().is_none());
    c.set_readiness("pending", Readiness::Ready).unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations.len(), 2);
}

#[test]
fn accepted_companion_cascade_does_not_resurrect_descendants() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), family_schema()).unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"B"})))?;
        tx.direct(create("Book", "other", json!({"title":"Other"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"C"})))?;
        let mut m = Mutation::new(
            "Edit",
            vec![Operation {
                model: "Book".into(),
                identity: json!({"id":"other"}),
                op: OperationKind::Update,
                values: Some(json!({"title":"New"})),
            }],
        );
        m.companion.push(Operation {
            model: "Book".into(),
            identity: json!({"id":"b"}),
            op: OperationKind::Delete,
            values: None,
        });
        tx.enqueue(m)?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap();
    c.acknowledge(1, receipt("book", 0)).unwrap();
    drop(c);
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), family_schema()).unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
}

#[test]
fn late_task_completion_does_not_resurrect_unused_readiness() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    let ordinal = c
        .transaction(|tx| {
            let mut m = mutation("B");
            m.prerequisites.push("upload".into());
            tx.enqueue(m)
        })
        .unwrap();
    c.drop_mutation(ordinal).unwrap();
    c.set_readiness("upload", Readiness::Ready).unwrap();
    assert!(c.pending_tasks().unwrap().is_empty());
    assert_eq!(table_count(&mut c, "ahead_mutation_prerequisite"), 0);
}

#[test]
fn record_status_reports_phases_and_duplicate_ack_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| tx.enqueue(mutation("B"))).unwrap();
    assert_eq!(
        c.record_status(&key()).unwrap()["pending"][0]["phase"],
        "queued"
    );
    c.freeze().unwrap();
    assert_eq!(
        c.record_status(&key()).unwrap()["pending"][0]["phase"],
        "frozen"
    );
    c.acknowledge(1, receipt("book", 5)).unwrap();
    assert_eq!(
        c.record_status(&key()).unwrap()["pending"][0]["phase"],
        "accepted"
    );
    c.acknowledge(1, receipt("book", 5)).unwrap();
    assert!(
        c.acknowledge(1, receipt("book", 6)).is_err(),
        "a different receipt for the same push is refused"
    );
    assert!(
        c.acknowledge(7, receipt("book", 1)).is_err(),
        "unknown push"
    );
}

/// Batching bounds: at most 20 mutations per batch, and a zero byte budget freezes
/// nothing and assigns nothing ([Batching]).
#[test]
fn batch_holds_at_most_twenty_mutations_and_zero_budget_freezes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        for i in 0..21 {
            tx.enqueue(mutation(&format!("v{i}")))?;
        }
        Ok(())
    })
    .unwrap();
    assert!(c.freeze_with_limit(0).unwrap().is_none());
    assert_eq!(c.pending_count().unwrap(), 21);
    let status = c.record_status(&key()).unwrap();
    assert!(
        status["pending"]
            .as_array()
            .unwrap()
            .iter()
            .all(|m| m["phase"] == "queued"),
        "a zero budget assigns no push: {status}"
    );
    let first = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(
        first
            .mutations
            .iter()
            .map(|m| m.ordinal)
            .collect::<Vec<_>>(),
        (1..=20).collect::<Vec<u64>>()
    );
    assert_eq!(
        PushRequest::decode(&c.freeze().unwrap().unwrap())
            .unwrap()
            .batch_sequence,
        1,
        "the in-flight batch is returned again, not a second one"
    );
    c.acknowledge(1, receipt("book", 1)).unwrap();
    let second = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(second.batch_sequence, 2);
    assert_eq!(
        second
            .mutations
            .iter()
            .map(|m| m.ordinal)
            .collect::<Vec<_>>(),
        vec![21]
    );
}

/// A frozen mutation cannot be dropped (its outcome is unknown or accepted); an
/// unfrozen one can, and leaves a `dropped` rejection. A dependency on an unknown
/// ordinal is refused at enqueue.
#[test]
fn frozen_mutations_cannot_be_dropped_and_unknown_dependencies_are_refused() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| tx.enqueue(mutation("B")).map(|_| ()))
        .unwrap();
    c.freeze().unwrap().unwrap();
    let err = c.drop_mutation(1).unwrap_err();
    assert!(err.to_string().contains("cannot drop"), "{err}");
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    for unknown in [
        {
            let mut m = mutation("C");
            m.lifecycle_dependencies.push(99);
            m
        },
        {
            let mut m = mutation("C");
            m.sequence_dependencies.push(99);
            m
        },
    ] {
        let err = c
            .transaction(|tx| tx.enqueue(unknown).map(|_| ()))
            .unwrap_err();
        assert!(
            err.to_string().contains("unknown mutation dependency"),
            "{err}"
        );
    }
    assert_eq!(
        c.pending_count().unwrap(),
        1,
        "a refused enqueue leaves no row"
    );
    c.transaction(|tx| tx.enqueue(mutation("C")).map(|_| ()))
        .unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
    c.drop_mutation(2).unwrap();
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "B",
        "dropping replays the remaining edit"
    );
    let rejections = c.rejections().unwrap();
    assert_eq!(rejections.len(), 1);
    assert_eq!(
        (rejections[0].ordinal, rejections[0].code.as_str()),
        (2, "dropped")
    );
    c.drop_mutation(42).unwrap();
}

/// P4 across a supported schema change: reopening a populated queue after an
/// additive reconciliation keeps the frozen bytes, the pending operations and the
/// visible records ([Reconciliation]).
#[test]
fn populated_queue_survives_additive_reconciliation_with_frozen_bytes_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| tx.enqueue(mutation("B")).map(|_| ()))
        .unwrap();
    let frozen = c.freeze().unwrap().unwrap();
    c.transaction(|tx| {
        tx.enqueue(Mutation::new(
            "Create",
            vec![create("Entry", "n", json!({"text":"new","note":null}))],
        ))
        .map(|_| ())
    })
    .unwrap();
    drop(c);
    let mut wider = serde_json::to_value(schema()).unwrap();
    wider["models"][0]["fields"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":"extra","nullable":true,"type":{"kind":"scalar","name":"string"}}));
    let mut c = Client::open(
        SqliteStore::open(&path).unwrap(),
        Schema::from_value(wider).unwrap(),
    )
    .unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);
    assert_eq!(
        c.freeze().unwrap().unwrap(),
        frozen,
        "the in-flight batch keeps its bytes across reconciliation"
    );
    let row = c.read(&key()).unwrap().unwrap();
    assert_eq!(row["text"], "B");
    assert_eq!(row["extra"], Value::Null, "the added column reads as null");
    let created = schema().record_key("Entry", &json!({"id":"n"})).unwrap();
    assert_eq!(c.read(&created).unwrap().unwrap()["text"], "new");
    c.acknowledge(1, receipt("book", 1)).unwrap();
    let next = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(next.mutations.len(), 1);
    assert_eq!(
        next.mutations[0].raw["operations"][0]["values"],
        json!({"text":"new","note":null}),
        "queued operations are sent as enqueued, without the new field"
    );
}
