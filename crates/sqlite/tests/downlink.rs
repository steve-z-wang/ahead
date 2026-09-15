mod common;
use ahead_client::*;
use ahead_sqlite::SqliteStore;
use common::*;
use serde_json::{Value, json};

fn stamped(channel: &str, from: u64, to: u64, stamp: u64, text: Option<&str>) -> PullPage {
    let mut p = page(channel, from, to, text);
    p.changes[0].stamp = stamp;
    p
}

/// A delete applies across channels by stamp: the record goes on the first
/// channel that delivers it and the stamp stays as evidence; the other
/// channel's copy of the delete is a no-op that still advances its cursor.
#[test]
fn cross_channel_delete_applies_by_stamp_and_retains_the_stamp() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    c.apply_page(stamped("b", 0, 1, 2, Some("B"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    c.apply_page(stamped("a", 1, 2, 3, None)).unwrap();
    assert!(
        c.read(&key()).unwrap().is_none(),
        "a stamped delete applies across channels"
    );
    assert_eq!(c.record_stamp(&key()).unwrap(), 3);
    assert_eq!(table_count(&mut c, "ahead_record"), 1);
    c.apply_page(stamped("b", 1, 2, 4, None)).unwrap();
    assert_eq!(c.record_stamp(&key()).unwrap(), 4);
    assert_eq!(
        table_count(&mut c, "ahead_record"),
        1,
        "the stamp is retained after every channel confirmed the delete"
    );
    assert_eq!(c.cursor("a").unwrap(), 2);
    assert_eq!(c.cursor("b").unwrap(), 2);
}

#[test]
fn older_stamp_cannot_regress_newer_authority_but_advances_the_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("b", 0, 1, 11, Some("NEW"))).unwrap();
    let report = c.apply_page(stamped("a", 0, 1, 10, Some("OLD"))).unwrap();
    assert_eq!(
        (report.applied, report.skipped, report.conflicts),
        (1, 0, 0)
    );
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NEW");
    assert_eq!(c.record_stamp(&key()).unwrap(), 11);
    assert_eq!(c.cursor("a").unwrap(), 1);
    let old_delete = c.apply_page(stamped("a", 1, 2, 9, None)).unwrap();
    assert_eq!(old_delete.applied, 1);
    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "NEW",
        "an old tombstone cannot delete newer content"
    );
    assert_eq!(c.cursor("a").unwrap(), 2);
}

#[test]
fn equal_stamp_is_idempotent_or_a_diagnostic() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
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
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        Ok(())
    })
    .unwrap();
    c.apply_page(page("book", 1, 2, Some("SERVER"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(
        c.read_sql("SELECT text FROM ahead_before_Entry", &[])
            .unwrap(),
        vec![json!({"text":"SERVER"})]
    );
}

#[test]
fn original_bad_change_skip_policy_is_retained() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
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

/// A parent's authoritative deletion cascades to its declared descendants
/// locally without touching their stamp evidence: a child keeps the stamp it
/// was delivered at, and a newer child page can still bring it back.
#[test]
fn delete_cascades_to_descendants_and_keeps_their_stamps() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(
        SqliteStore::open(dir.path().join("db")).unwrap(),
        family_schema(),
    )
    .unwrap();
    subscribe(&mut c, "lib");
    let book = |cursor, state| PullPage {
        channel: "lib".into(),
        from_cursor: cursor - 1,
        to_cursor: cursor,
        changes: vec![RecordChange {
            cursor,
            model: "Book".into(),
            identity: json!({"id":"b"}),
            stamp: cursor,
            state,
        }],
    };
    let comment = |cursor, stamp, state| PullPage {
        channel: "lib".into(),
        from_cursor: cursor - 1,
        to_cursor: cursor,
        changes: vec![RecordChange {
            cursor,
            model: "Comment".into(),
            identity: json!({"id":"c"}),
            stamp,
            state,
        }],
    };
    let comment_key = family_schema()
        .record_key("Comment", &json!({"id":"c"}))
        .unwrap();
    c.apply_page(book(1, json!({"title":"T"}))).unwrap();
    c.apply_page(comment(2, 2, json!({"bookId":"b","text":"hi"})))
        .unwrap();
    c.apply_page(book(3, Value::Null)).unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
    assert_eq!(
        c.record_stamp(&comment_key).unwrap(),
        2,
        "the parent's deletion does not rewrite the child's stamp"
    );
    assert_eq!(table_count(&mut c, "ahead_record"), 2);
    let stale = c
        .apply_page(comment(4, 2, json!({"bookId":"b","text":"hi"})))
        .unwrap();
    assert_eq!(
        stale.conflicts, 1,
        "equal stamp, different content: reported"
    );
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
    c.apply_page(comment(5, 3, json!({"bookId":"b","text":"again"})))
        .unwrap();
    assert_eq!(
        c.query("Comment", &json!({})).unwrap().len(),
        1,
        "newer child authority applies on its own stamp"
    );
}

/// Unsubscribing stops the channel's delivery and nothing else: rows, stamps,
/// before images and pending edits stay; a page still in flight for the
/// channel is dropped without writing anything.
#[test]
fn unsubscribing_retains_records_and_later_pages_are_dropped() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    c.apply_page(stamped("a", 0, 1, 5, Some("A"))).unwrap();
    let mut clean = stamped("a", 1, 2, 6, Some("C"));
    clean.changes[0].identity = json!({"id":"clean"});
    c.apply_page(clean).unwrap();
    c.transaction(|tx| tx.enqueue(mutation("B"))).unwrap();
    c.freeze().unwrap().unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    assert_eq!(table_count(&mut c, "ahead_subscription"), 0);
    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "B",
        "the dirty row keeps its pending edit"
    );
    let clean_key = schema()
        .record_key("Entry", &json!({"id":"clean"}))
        .unwrap();
    assert_eq!(
        c.read(&clean_key).unwrap().unwrap()["text"],
        "C",
        "the clean row is retained"
    );
    assert_eq!(
        c.pending_count().unwrap(),
        1,
        "the push in flight is untouched"
    );
    assert_eq!(c.before_image_count().unwrap(), 1, "the base is kept");
    assert_eq!(c.record_stamp(&key()).unwrap(), 5);
    assert_eq!(c.record_stamp(&clean_key).unwrap(), 6);
    let report = c.apply_page(stamped("a", 2, 3, 7, Some("X"))).unwrap();
    assert!(
        report.stale,
        "a page for an unsubscribed channel is dropped whole"
    );
    assert_eq!(table_count(&mut c, "ahead_subscription"), 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    // Completion still works with no subscription at all.
    let r = receipt(&mut c, 1, vec![authority(Some("B"), 8)]);
    c.acknowledge(1, r).unwrap();
    assert_eq!(c.pending_count().unwrap(), 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
}

/// Retained content is still updated by another active channel, and the
/// last subscription going away removes nothing. Everything survives reopen.
#[test]
fn another_channel_updates_retained_content_and_restart_keeps_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("from a"))).unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.apply_page(stamped("b", 0, 1, 2, Some("from b"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "from b");
    c.transaction(|tx| tx.set_channel("b".into(), false))
        .unwrap();
    assert!(c.subscriptions().unwrap().is_empty());
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "from b");
    drop(c);
    let mut c = open(&path);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "from b");
    assert_eq!(c.record_stamp(&key()).unwrap(), 2);
    // A newer deletion still applies; stale content cannot resurrect it.
    subscribe(&mut c, "a");
    c.apply_page(stamped("a", 0, 1, 3, None)).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    c.apply_page(stamped("a", 1, 2, 2, Some("stale"))).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(c.record_stamp(&key()).unwrap(), 3);
}

/// A channel cursor and a record stamp are independent counters: a page whose
/// cursors are far ahead of the stamp, and one whose stamp is far ahead of
/// the cursors, both apply by their own rule.
#[test]
fn cursor_and_stamp_are_independent() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    c.apply_page(stamped("a", 0, 100, 2, Some("low stamp, high cursor")))
        .unwrap();
    assert_eq!(c.cursor("a").unwrap(), 100);
    assert_eq!(c.record_stamp(&key()).unwrap(), 2);
    c.apply_page(stamped("a", 100, 101, 900, Some("high stamp")))
        .unwrap();
    assert_eq!(c.cursor("a").unwrap(), 101);
    assert_eq!(c.record_stamp(&key()).unwrap(), 900);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "high stamp");
    // A receipt never moves a cursor.
    c.transaction(|tx| tx.enqueue(mutation("B"))).unwrap();
    c.freeze().unwrap().unwrap();
    let r = receipt(&mut c, 1, vec![authority(Some("B"), 901)]);
    c.acknowledge(1, r).unwrap();
    assert_eq!(c.cursor("a").unwrap(), 101);
}

/// A2: a page answering a pull issued before the channel was unsubscribed and
/// subscribed again is stale, not a gap, on every incoming path (issue #32). A page
/// the client never requested that starts beyond its cursor is still a gap.
#[test]
fn page_from_a_previous_subscription_is_stale_not_a_gap() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    c.apply_page(page("a", 0, 1, Some("A"))).unwrap();
    let in_flight = c.downlink_request("a").unwrap();
    assert!(in_flight.contains("\"fromCursor\":1"));
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), true))
        .unwrap();
    assert_eq!(c.cursor("a").unwrap(), 0);

    // apply_page: the answer to the old request is dropped, the cursor stays at 0
    // and the retained row is untouched.
    let report = c.apply_page(page("a", 1, 2, Some("B"))).unwrap();
    assert!(report.stale, "{report:?}");
    assert_eq!(report.applied, 0);
    assert_eq!(c.cursor("a").unwrap(), 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    // The same page with no request behind it is a genuine gap for direct callers.
    assert!(c.apply_page(page("a", 1, 2, Some("B"))).is_err());
    // A fresh pull from the reset cursor delivers everything.
    let fresh = c.downlink_request("a").unwrap();
    assert!(fresh.contains("\"fromCursor\":0"));
    assert_eq!(c.apply_page(page("a", 0, 2, Some("B"))).unwrap().applied, 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");

    // receive_downlink: covered rather than recover, so the SDK does not re-catch-up.
    let request = PullRequest::decode(c.downlink_request("a").unwrap().as_bytes()).unwrap();
    assert_eq!(request.from_cursor, 2);
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), true))
        .unwrap();
    let progress = c
        .receive_downlink(page("a", 2, 3, Some("C")), Some(request))
        .unwrap();
    assert_eq!(progress.disposition, "covered");
    assert_eq!(c.cursor("a").unwrap(), 0);
    // The SDK's late-catch-up shape: the old request is still outstanding when the
    // new subscription issues its own request from the same cursor; the fresh
    // answer applies, and the obsolete answer is then dropped.
    let old = PullRequest::decode(c.downlink_request("a").unwrap().as_bytes()).unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), true))
        .unwrap();
    let fresh = PullRequest::decode(c.downlink_request("a").unwrap().as_bytes()).unwrap();
    assert_eq!((old.from_cursor, fresh.from_cursor), (0, 0));
    // Stamps keep counting up: the retained row only takes newer content.
    let progress = c
        .receive_downlink(stamped("a", 0, 1, 3, Some("fresh")), Some(fresh))
        .unwrap();
    assert_eq!(progress.disposition, "applied");
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "fresh");
    let progress = c
        .receive_downlink(stamped("a", 0, 1, 4, Some("obsolete")), Some(old))
        .unwrap();
    assert_eq!(progress.disposition, "covered");
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "fresh");
    // Back to a clean channel for the SyncCycle steps below.
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), true))
        .unwrap();
    // An unrequested page beyond the cursor is still a gap to recover from.
    let progress = c
        .receive_downlink(page("a", 2, 3, Some("C")), None)
        .unwrap();
    assert_eq!(progress.disposition, "recover");

    // SyncCycle: completing the old pull after a resubscribe is not an error.
    let mut cycle = SyncCycle::default();
    cycle.restart();
    let action = cycle.next(&mut c).unwrap().unwrap();
    assert_eq!(action.kind, "pull");
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), true))
        .unwrap();
    cycle
        .complete(
            &mut c,
            &stamped("a", 0, 1, 5, Some("old")).encode().unwrap(),
        )
        .unwrap();
    assert_eq!(
        c.cursor("a").unwrap(),
        0,
        "the stale answer did not move the cursor"
    );
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "fresh");

    // Subscribing another channel does not make channel a's pull stale.
    cycle.restart();
    let action = cycle.next(&mut c).unwrap().unwrap();
    assert_eq!(action.kind, "pull");
    c.transaction(|tx| tx.set_channel("b".into(), true))
        .unwrap();
    cycle
        .complete(
            &mut c,
            &stamped("a", 0, 1, 6, Some("kept")).encode().unwrap(),
        )
        .unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "kept");
}

#[test]
fn older_subscription_response_cannot_discard_a_fresh_response() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    let old = PullRequest::decode(c.downlink_request("a").unwrap().as_bytes()).unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), false))
        .unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), true))
        .unwrap();
    let fresh = PullRequest::decode(c.downlink_request("a").unwrap().as_bytes()).unwrap();
    // The requests have identical wire identities. Receiving the old answer
    // first must not consume the fresh request and discard its later answer.
    c.receive_downlink(stamped("a", 0, 1, 1, Some("old")), Some(old))
        .unwrap();
    let fresh_progress = c
        .receive_downlink(stamped("a", 0, 2, 2, Some("fresh")), Some(fresh))
        .unwrap();
    assert_eq!(fresh_progress.disposition, "applied");
    assert_eq!(c.cursor("a").unwrap(), 2);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "fresh");
}
