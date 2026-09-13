mod common;
use common::*;
use otter_client::*;
use otter_sqlite::SqliteStore;
use serde_json::{Value, json};

fn stamped(channel: &str, from: u64, to: u64, stamp: u64, text: Option<&str>) -> PullPage {
    let mut p = page(channel, from, to, text);
    p.changes[0].stamp = Some(stamp);
    p
}

#[test]
fn channel_claims_and_cross_channel_delete() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("a", 0, 1, Some("A"))).unwrap();
    c.apply_page(page("b", 0, 1, Some("B"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(table_count(&mut c, "otter_claim"), 2);
    c.apply_page(page("a", 1, 2, None)).unwrap();
    assert!(
        c.read(&key()).unwrap().is_none(),
        "delete applies across channels"
    );
    assert_eq!(
        table_count(&mut c, "otter_claim"),
        1,
        "b's claim is the pending tombstone confirmation"
    );
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    c.apply_page(page("b", 1, 2, None)).unwrap();
    assert_eq!(table_count(&mut c, "otter_claim"), 0);
    assert_eq!(
        table_count(&mut c, "otter_record"),
        0,
        "tombstone dropped once every channel confirmed"
    );
    assert_eq!(c.cursor("a").unwrap(), 2);
    assert_eq!(c.cursor("b").unwrap(), 2);
}

#[test]
fn older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(stamped("b", 0, 1, 11, Some("NEW"))).unwrap();
    let report = c.apply_page(stamped("a", 0, 1, 10, Some("OLD"))).unwrap();
    assert_eq!(
        (report.applied, report.skipped, report.conflicts),
        (1, 0, 0)
    );
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NEW");
    assert_eq!(
        table_count(&mut c, "otter_claim"),
        2,
        "stale content still records the claim"
    );
    assert_eq!(c.cursor("a").unwrap(), 1);
    let old_delete = c.apply_page(stamped("a", 1, 2, 9, None)).unwrap();
    assert_eq!(old_delete.applied, 1);
    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "NEW",
        "an old tombstone cannot delete newer content"
    );
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
}

#[test]
fn equal_stamp_is_idempotent_or_a_diagnostic() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(stamped("a", 0, 1, 5, Some("X"))).unwrap();
    let same = c.apply_page(stamped("b", 0, 1, 5, Some("X"))).unwrap();
    assert_eq!(same.conflicts, 0);
    let conflict = c.apply_page(stamped("b", 1, 2, 5, Some("Y"))).unwrap();
    assert_eq!(conflict.conflicts, 1);
    assert_eq!(conflict.diagnostics[0]["stamp"], 5);
    assert_eq!(conflict.diagnostics[0]["model"], "Entry");
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "X");
    assert_eq!(c.cursor("b").unwrap(), 2, "the channel is not stalled");
}

#[test]
fn newer_authority_lands_beneath_pending_edits_and_replays_them() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    c.apply_page(page("book", 1, 2, Some("SERVER"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(
        c.read_sql("SELECT text FROM otter_before_Entry", &[])
            .unwrap(),
        vec![json!({"text":"SERVER"})]
    );
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
    assert_eq!(c.cursor("book").unwrap(), 2);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    let stale = c.apply_page(page("book", 1, 2, Some("Z"))).unwrap();
    assert!(stale.stale);
    assert!(
        c.apply_page(page("book", 5, 6, Some("Z"))).is_err(),
        "cursor gap"
    );
}

#[test]
fn delete_cascades_to_descendants_and_their_claims() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        family_schema(),
    )
    .unwrap();
    let book = |cursor, state| PullPage {
        channel: "lib".into(),
        from_cursor: cursor - 1,
        to_cursor: cursor,
        changes: vec![RecordChange {
            cursor,
            model: "Book".into(),
            identity: json!({"id":"b"}),
            stamp: None,
            state,
        }],
    };
    c.apply_page(book(1, json!({"title":"T"}))).unwrap();
    c.apply_page(PullPage {
        channel: "lib".into(),
        from_cursor: 1,
        to_cursor: 2,
        changes: vec![RecordChange {
            cursor: 2,
            model: "Comment".into(),
            identity: json!({"id":"c"}),
            stamp: None,
            state: json!({"bookId":"b","text":"hi"}),
        }],
    })
    .unwrap();
    assert_eq!(table_count(&mut c, "otter_claim"), 2);
    c.apply_page(book(3, Value::Null)).unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
    assert_eq!(table_count(&mut c, "otter_claim"), 0);
    assert_eq!(table_count(&mut c, "otter_record"), 0);
}
