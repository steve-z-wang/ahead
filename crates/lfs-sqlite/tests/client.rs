use lfs_client::*;
use lfs_core::*;
use lfs_sqlite::SqliteStore;
use serde_json::{Value, json};
fn schema() -> Schema {
    Schema::from_value(
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap(),
    )
    .unwrap()
}
fn open(path: &std::path::Path) -> Client<SqliteStore> {
    Client::open(SqliteStore::open(path).unwrap(), schema(), "owner".into()).unwrap()
}
fn key() -> RecordKey {
    schema().record_key("Entry", &json!({"id":"e"})).unwrap()
}
fn update(text: &str) -> Operation {
    Operation {
        model: "Entry".into(),
        op: OperationKind::Update,
        identity: json!({"id":"e"}),
        values: Some(json!({"text":text})),
    }
}
fn mutation(text: &str) -> Mutation {
    Mutation::new("Edit", vec![update(text)])
}
fn page(channel: &str, from: u64, to: u64, text: Option<&str>) -> PullPage {
    PullPage {
        channel: channel.into(),
        from_cursor: from,
        to_cursor: to,
        changes: vec![RecordChange {
            cursor: to,
            model: "Entry".into(),
            identity: json!({"id":"e"}),
            state: text
                .map(|t| json!({"text":t,"note":null}))
                .unwrap_or(Value::Null),
        }],
    }
}
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
    assert_eq!(c.freeze().unwrap().unwrap(), bytes);
    c.acknowledge(1, receipt("book", 2)).unwrap();
    assert_eq!(c.pending_count(), 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    c.apply_page(page("book", 1, 2, Some("NORMALIZED")))
        .unwrap();
    assert_eq!(c.pending_count(), 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NORMALIZED");
    assert_eq!(c.before_image_count(), 0);
}
#[test]
fn pull_before_ack_and_later_local_edit_replay_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
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
    assert_eq!(c.pending_count(), 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
}
#[test]
fn local_transaction_and_mutation_savepoint_have_independent_fate() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    let events = c.subscribe();
    let result: Result<()> = c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Err(invalid("rollback"))
    });
    assert!(result.is_err());
    assert_eq!(c.pending_count(), 0);
    assert!(events.try_recv().is_err());
    c.transaction(|tx| {
        tx.direct(update("LOCAL"))?;
        let failed: Result<()> = tx.savepoint(|tx| {
            tx.enqueue(mutation("bad"))?;
            Err(invalid("refuse"))
        });
        assert!(failed.is_err());
        Ok(())
    })
    .unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "LOCAL");
    assert_eq!(c.pending_count(), 0);
    assert!(events.try_recv().is_ok());
    assert!(events.try_recv().is_err());
}
#[test]
fn rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
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
    drop(c);
    let mut c = open(&path);
    assert_eq!(c.rejections().len(), 1);
    c.dismiss_rejection(1).unwrap();
    assert!(c.rejections().is_empty());
}
#[test]
fn channel_claims_are_separate_from_record_identity() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("a", 0, 1, Some("A"))).unwrap();
    c.apply_page(page("b", 0, 1, Some("B"))).unwrap();
    c.apply_page(page("a", 1, 2, None)).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    c.apply_page(page("b", 1, 2, None)).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
}
#[test]
fn accepted_batches_only_settle_in_ready_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
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
    assert_eq!(c.pending_count(), 2);
    c.apply_page(PullPage {
        channel: "slow".into(),
        from_cursor: 0,
        to_cursor: 9,
        changes: vec![],
    })
    .unwrap();
    assert_eq!(c.pending_count(), 0);
}
#[test]
fn failed_prerequisite_stays_optimistic_independent_work_can_overtake() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
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
    assert_eq!(c.pending_count(), 2);
}
#[test]
fn stale_writer_cannot_overwrite_committed_database() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut a = open(&path);
    let mut b = open(&path);
    a.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    assert!(b.apply_page(page("book", 0, 1, Some("B"))).is_err());
    assert_eq!(open(&path).read(&key()).unwrap().unwrap()["text"], "A");
}
#[test]
fn original_bad_change_skip_policy_is_retained() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    let mut bad = page("book", 1, 2, Some("B"));
    bad.changes[0].state = json!({"text":22});
    let report = c.apply_page(bad).unwrap();
    assert_eq!(report.skipped, 1);
    assert_eq!(c.cursor("book"), 2);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
}
#[test]
fn multiple_edits_in_one_mutation_restore_original_before_image() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(Mutation::new("Composite", vec![update("B"), update("C")]))?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap();
    let mut ack = receipt("book", 1);
    ack.rejections.push(Rejection {
        ordinal: 1,
        code: "denied".into(),
    });
    c.acknowledge(1, ack).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
}
#[test]
fn lifecycle_dependency_waits_for_parent_ack_but_sequence_can_share_batch() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
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
fn language_transaction_session_reads_own_writes_without_notifying_until_commit() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    let events = c.subscribe();
    let mut session = c.begin_session();
    session
        .run(|tx| {
            tx.enqueue(mutation("B"))?;
            Ok(())
        })
        .unwrap();
    assert_eq!(
        session.run(|tx| tx.read(&key())).unwrap().unwrap()["text"],
        "B"
    );
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert!(events.try_recv().is_err());
    c.commit_session(session).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert!(events.try_recv().is_ok());
}
#[test]
fn stale_language_transaction_session_cannot_overwrite_new_authority() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    let session = c.begin_session();
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    assert!(c.commit_session(session).is_err());
}
fn family_schema() -> Schema {
    Schema::from_value(json!({"enums":[],"models":[
 {"name":"Book","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"title","nullable":false,"type":{"kind":"scalar","name":"string"}}]},
 {"name":"Comment","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"bookId","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"text","nullable":false,"type":{"kind":"scalar","name":"string"}}],"relations":[{"name":"book","target":"Book","fields":["bookId"],"targetFields":["id"],"onDelete":"delete"}],"unique":[["bookId","text"]]}
]})).unwrap()
}
fn create(model: &str, id: &str, values: Value) -> Operation {
    Operation {
        model: model.into(),
        op: OperationKind::Create,
        identity: json!({"id":id}),
        values: Some(values),
    }
}
#[test]
fn schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        family_schema(),
        "u".into(),
    )
    .unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"Book"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"hello"})))?;
        Ok(())
    })
    .unwrap();
    c.transaction(|tx| {
        tx.enqueue(Mutation::new(
            "DeleteBook",
            vec![Operation {
                model: "Book".into(),
                op: OperationKind::Delete,
                identity: json!({"id":"b"}),
                values: None,
            }],
        ))?;
        Ok(())
    })
    .unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
    let request = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(
        request.raw["mutations"][0]["operations"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let mut ack = receipt("book", 0);
    ack.rejections.push(Rejection {
        ordinal: 1,
        code: "denied".into(),
    });
    c.acknowledge(1, ack).unwrap();
    assert_eq!(c.query("Comment", &json!({})).unwrap().len(), 1);
}
#[test]
fn declared_unique_constraint_is_atomic() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        family_schema(),
        "u".into(),
    )
    .unwrap();
    let result = c.transaction(|tx| {
        tx.direct(create("Comment", "c1", json!({"bookId":"b","text":"same"})))?;
        tx.direct(create("Comment", "c2", json!({"bookId":"b","text":"same"})))?;
        Ok(())
    });
    assert!(result.is_err());
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
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
    let mut c = Client::open(
        SqliteStore::open(&path).unwrap(),
        schema.clone(),
        "u".into(),
    )
    .unwrap();
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
    let tasks = c.pending_tasks();
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0]["arguments"], json!({"key":"asset"}));
    let key = tasks[0]["key"].as_str().unwrap().to_string();
    drop(c);
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), schema, "u".into()).unwrap();
    assert_eq!(c.pending_tasks().len(), 1);
    c.set_readiness(&key, Readiness::Ready).unwrap();
    assert!(c.freeze().unwrap().is_some());
}
#[test]
fn creating_then_editing_a_record_automatically_has_lifecycle_dependency() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.transaction(|tx| {
        tx.enqueue(Mutation::new(
            "Create",
            vec![create("Entry", "e", json!({"text":"A"}))],
        ))?;
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations.len(), 1);
}
#[test]
fn byte_budget_skips_large_candidate_but_always_allows_one() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
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
fn direct_cascade_handles_cyclic_relationships_once() {
    let dir = tempfile::tempdir().unwrap();
    let mut value = serde_json::to_value(family_schema()).unwrap();
    value["models"][0]["fields"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":"commentId","nullable":true,"type":{"kind":"scalar","name":"string"}}));
    value["models"][0]["relations"] = json!([{"name":"comment","target":"Comment","fields":["commentId"],"targetFields":["id"],"onDelete":"delete"}]);
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        Schema::from_value(value).unwrap(),
        "u".into(),
    )
    .unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"B","commentId":"c"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"C"})))?;
        tx.direct(Operation {
            model: "Book".into(),
            op: OperationKind::Delete,
            identity: json!({"id":"b"}),
            values: None,
        })
    })
    .unwrap();
    assert!(c.query("Book", &json!({})).unwrap().is_empty());
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
}
#[test]
fn schema_sequence_relationship_blocks_dependent_but_not_independent_work() {
    let dir = tempfile::tempdir().unwrap();
    let mut value = serde_json::to_value(family_schema()).unwrap();
    value["clientPolicies"] = json!([
    {"name":"Rename","version":1,"slots":[{"name":"book","model":"Book","operation":"update","cardinality":"single"}]},
    {"name":"CommentEdit","version":1,"slots":[{"name":"comment","model":"Comment","operation":"update","cardinality":"single"}],"sequence":{"after":[{"name":"Rename","arguments":{"book":"comment.book"}}]}}
    ]);
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        Schema::from_value(value).unwrap(),
        "u".into(),
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
fn explicit_schema_migration_preserves_frozen_requests_and_replays_channels_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    let bytes = c.freeze().unwrap().unwrap();
    let id = c.client_id().to_string();
    drop(c);
    let mut value = serde_json::to_value(schema()).unwrap();
    value["models"][0]["fields"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name":"rank","nullable":false,"type":{"kind":"scalar","name":"int"}}));
    let next = Schema::from_value(value).unwrap();
    let migration = SchemaMigration {
        defaults: json!({"Entry":{"rank":0}}),
        replay_pull: true,
    };
    let mut c = Client::open_with_migration(
        SqliteStore::open(&path).unwrap(),
        next.clone(),
        "owner".into(),
        Some(migration.clone()),
    )
    .unwrap();
    assert_eq!(c.client_id(), id);
    assert_eq!(c.cursor("book"), 0);
    assert_eq!(c.freeze().unwrap().unwrap(), bytes);
    assert_eq!(c.read(&key()).unwrap().unwrap()["rank"], 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    let mut page = page("book", 0, 2, Some("SERVER"));
    page.changes[0].state["rank"] = json!(4);
    c.apply_page(page).unwrap();
    c.acknowledge(1, receipt("book", 2)).unwrap();
    drop(c);
    let c = Client::open_with_migration(
        SqliteStore::open(&path).unwrap(),
        next,
        "owner".into(),
        Some(migration),
    )
    .unwrap();
    assert_eq!(c.cursor("book"), 2);
    assert_eq!(c.read(&key()).unwrap().unwrap()["rank"], 4);
}

#[test]
fn accepted_companion_cascade_does_not_resurrect_descendants() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = Client::open(
        SqliteStore::open(&path).unwrap(),
        family_schema(),
        "u".into(),
    )
    .unwrap();
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
    let c = Client::open(
        SqliteStore::open(&path).unwrap(),
        family_schema(),
        "u".into(),
    )
    .unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
}
#[test]
fn late_task_completion_does_not_resurrect_unused_readiness() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
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
    assert!(c.snapshot().readiness.is_empty());
}
#[test]
fn query_normalizes_filters_orders_nulls_and_resolves_relationships() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        family_schema(),
        "u".into(),
    )
    .unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"Book"})))?;
        for (id, text) in [("c1", "Z"), ("c2", "A"), ("c3", "A")] {
            tx.direct(create(
                "Comment",
                id,
                json!({"bookId":if id=="c3"{"other"}else{"b"},"text":text}),
            ))?;
        }
        Ok(())
    })
    .unwrap();
    let spec: QuerySpec = serde_json::from_value(
        json!({"orderBy":[{"field":"text","direction":"ascending"}],"limit":2}),
    )
    .unwrap();
    let rows = c.query_spec("Comment", &spec).unwrap();
    assert_eq!(
        rows.iter()
            .map(|r| r["id"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["c2", "c3"]
    );
    let key = family_schema()
        .record_key("Comment", &json!({"id":"c1"}))
        .unwrap();
    assert_eq!(c.related(&key, "book").unwrap().unwrap()["id"], "b");
    let book = family_schema()
        .record_key("Book", &json!({"id":"b"}))
        .unwrap();
    assert_eq!(c.referencing(&book, "Comment", "book").unwrap().len(), 2);
    assert!(c.query("Comment", &json!({"missing":1})).is_err());
}
#[test]
fn readonly_sql_sees_optimistic_rows_and_refuses_write_statements() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    assert_eq!(
        c.read_sql("SELECT id,text FROM Entry WHERE id=?", &[json!("e")])
            .unwrap(),
        vec![json!({"id":"e","text":"B"})]
    );
    assert!(c.read_sql("DELETE FROM Entry RETURNING id", &[]).is_err());
    assert!(c.read_sql("PRAGMA user_version=10", &[]).is_err());
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    let mut session = c.begin_session();
    session.run(|tx| tx.direct(update("C"))).unwrap();
    assert_eq!(
        c.session_sql(&session, "SELECT text FROM Entry", &[])
            .unwrap(),
        vec![json!({"text":"C"})]
    );
    assert_eq!(
        c.read_sql("SELECT text FROM Entry", &[]).unwrap(),
        vec![json!({"text":"B"})]
    );
}
#[test]
fn record_status_and_rejection_context_survive_restart_until_dismissed() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
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
    let mut ack = receipt("book", 1);
    ack.rejections.push(Rejection {
        ordinal: 1,
        code: "entry.denied".into(),
    });
    c.acknowledge(1, ack).unwrap();
    drop(c);
    let mut c = open(&path);
    let status = c.record_status(&key()).unwrap();
    assert_eq!(status["rejections"][0]["mutation"]["name"], "Edit");
    assert_eq!(status["rejections"][0]["code"], "entry.denied");
    c.dismiss_rejection(1).unwrap();
    assert!(
        c.record_status(&key()).unwrap()["rejections"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}
