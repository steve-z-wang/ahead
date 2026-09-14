mod common;
use ahead_client::*;
use ahead_sqlite::SqliteStore;
use common::*;
use serde_json::json;

#[test]
fn query_normalizes_filters_orders_nulls_and_resolves_relationships() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        family_schema(),
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
    assert_eq!(c.query("Comment", &json!({"bookId":"b"})).unwrap().len(), 2);
    c.transaction(|tx| {
        assert_eq!(tx.query("Comment", &json!({}))?.len(), 3);
        tx.direct(create("Comment", "c4", json!({"bookId":"b","text":"Q"})))?;
        assert_eq!(
            tx.query("Comment", &json!({}))?.len(),
            4,
            "reads inside the transaction see its writes"
        );
        Ok(())
    })
    .unwrap();
}

#[test]
fn readonly_sql_sees_optimistic_rows_and_refuses_write_statements() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
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
    assert!(
        c.read_sql("SELECT id, id FROM Entry", &[]).is_err(),
        "duplicate column names need aliases"
    );
    c.begin_session().unwrap();
    c.session(|tx| tx.direct(update("C"))).unwrap();
    assert_eq!(
        c.session_sql("SELECT text FROM Entry", &[]).unwrap(),
        vec![json!({"text":"C"})]
    );
    assert_eq!(
        c.read_sql("SELECT text FROM Entry", &[]).unwrap(),
        vec![json!({"text":"B"})]
    );
    c.rollback_session().unwrap();
}

#[test]
fn transport_pulls_only_subscribed_channels_and_unawaitable_checkpoints_settle() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    seed(&mut c, "A");
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    let mut cycle = SyncCycle::default();
    let push = cycle.next(&mut c).unwrap().unwrap();
    assert_eq!(push.kind, "push");
    let receipt = PushReceipt {
        required_channel: "other".into(),
        required_cursor: 3,
        required_checkpoints: vec![ChannelCheckpoint {
            channel: "other".into(),
            cursor: 3,
        }],
        rejections: vec![],
    };
    cycle.complete(&mut c, &receipt.encode().unwrap()).unwrap();
    assert_eq!(
        c.pending_count().unwrap(),
        0,
        "a checkpoint on a channel nothing pulls cannot be awaited, so the push settles"
    );
    assert_eq!(table_count(&mut c, "ahead_push_checkpoint"), 0);
    let first = cycle.next(&mut c).unwrap().unwrap();
    assert_eq!(first.kind, "pull");
    let request = PullRequest::decode(first.body.as_bytes()).unwrap();
    assert_eq!(request.channel, "book");
    cycle
        .complete(
            &mut c,
            &PullPage {
                channel: "book".into(),
                from_cursor: 0,
                to_cursor: 0,
                changes: vec![],
            }
            .encode()
            .unwrap(),
        )
        .unwrap();
    assert!(
        cycle.next(&mut c).unwrap().is_none(),
        "the unsubscribed checkpoint channel is never pulled"
    );
}
