//! Settlement without subscribed authority (decision [#52]): a receipt confirms
//! execution, not the final record. Checkpoints outside the current subscriptions
//! are never awaited, so the batch settles in sequence order and every touched
//! record is rebuilt from the available base plus the remaining pending edits.
//! Each test asserts the visible records *and* the pending work.
//!
//! [#52]: https://github.com/zanminwang/ahead/issues/52
mod common;
use ahead_client::*;
use common::*;
use serde_json::json;

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

/// The record a local create introduces; no channel ever claims it.
fn created() -> RecordKey {
    schema().record_key("Entry", &json!({"id":"n"})).unwrap()
}

fn create_entry() -> Mutation {
    Mutation::new(
        "Create",
        vec![create("Entry", "n", json!({"text":"new","note":null}))],
    )
}

/// Everything settled: no queue, no stored checkpoint, no before image, no rejection.
fn assert_quiet(c: &mut Client<ahead_sqlite::SqliteStore>) {
    assert_eq!(c.pending_count().unwrap(), 0, "nothing pending");
    assert_eq!(table_count(c, "ahead_push_checkpoint"), 0);
    assert_eq!(c.before_image_count().unwrap(), 0, "no base is retained");
    assert!(
        c.rejections().unwrap().is_empty(),
        "the batch was accepted, not rejected"
    );
}

/// The client follows no channel, so the receipt's checkpoint can never be met and
/// is dropped: the accepted update settles at once and the row reverts to its base.
#[test]
fn update_without_subscription_reverts_to_the_base_on_settlement() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");
    c.transaction(|tx| tx.enqueue(mutation("B")).map(|_| ()))
        .unwrap();
    c.freeze().unwrap().unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(c.pending_count().unwrap(), 1);

    c.acknowledge(1, receipt("other", 3)).unwrap();

    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "A",
        "no page can deliver the server's row, so the rebuild restores the base"
    );
    assert!(
        c.record_status(&key()).unwrap()["pending"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_quiet(&mut c);
}

/// The same shape for a local create: without authority the rebuild has no base to
/// restore, so the accepted record disappears from the client.
#[test]
fn create_without_subscription_disappears_on_settlement() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.transaction(|tx| tx.enqueue(create_entry()).map(|_| ()))
        .unwrap();
    c.freeze().unwrap().unwrap();
    assert_eq!(c.read(&created()).unwrap().unwrap()["text"], "new");
    assert_eq!(c.pending_count().unwrap(), 1);

    c.acknowledge(1, receipt("other", 4)).unwrap();

    assert!(
        c.read(&created()).unwrap().is_none(),
        "the accepted create has no base and no authority, so the row is gone"
    );
    assert_eq!(table_count(&mut c, "Entry"), 0);
    assert_quiet(&mut c);
}

/// Subscribing to a channel the receipt does not name awaits nothing either: the
/// batch settles at once and the unrelated subscription's cursor never moves.
#[test]
fn unrelated_subscription_does_not_await_the_checkpoint() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "book");
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        tx.enqueue(create_entry())?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap().unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);

    c.acknowledge(1, receipt("other", 3)).unwrap();

    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "A",
        "the update reverts to the page that is still the base"
    );
    assert!(c.read(&created()).unwrap().is_none());
    assert_eq!(
        c.cursor("book").unwrap(),
        1,
        "settling a batch never moves an unrelated subscription's cursor"
    );
    assert_quiet(&mut c);
}

/// Subscribing after settlement still delivers the server's result: the page
/// restores the updated value and brings the created record back, with the content
/// the backend holds rather than the optimistic prediction.
#[test]
fn later_subscription_delivers_the_authoritative_result() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        tx.enqueue(create_entry())?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap().unwrap();
    c.acknowledge(1, receipt("notify", 5)).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert!(c.read(&created()).unwrap().is_none());
    assert_quiet(&mut c);

    subscribe(&mut c, "notify");
    let mut delivered = page("notify", 0, 5, Some("SERVER"));
    delivered.changes[0].cursor = 4;
    delivered.changes.push(RecordChange {
        cursor: 5,
        model: "Entry".into(),
        identity: json!({"id":"n"}),
        stamp: 5,
        state: json!({"text":"server new","note":null}),
    });
    let report = c.apply_page(delivered).unwrap();
    assert_eq!((report.applied, report.skipped), (2, 0));

    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "SERVER",
        "the handler's result arrives through the channel it was published to"
    );
    assert_eq!(c.read(&created()).unwrap().unwrap()["text"], "server new");
    assert_quiet(&mut c);
}

/// While the notified channel is subscribed the batch does wait for its checkpoint
/// and the optimistic rows stay visible. Unsubscribing releases the requirement:
/// the batch settles, the update reverts and the created record, which no channel
/// claims, is removed.
#[test]
fn unsubscribe_releases_the_wait_and_removes_unclaimed_records() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "notify");
    seed(&mut c, "A");
    c.transaction(|tx| {
        tx.enqueue(mutation("B"))?;
        tx.enqueue(create_entry())?;
        Ok(())
    })
    .unwrap();
    c.freeze().unwrap().unwrap();
    c.acknowledge(1, receipt("notify", 9)).unwrap();

    assert_eq!(
        c.pending_count().unwrap(),
        2,
        "the subscribed channel's checkpoint is awaited"
    );
    assert_eq!(table_count(&mut c, "ahead_push_checkpoint"), 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(c.read(&created()).unwrap().unwrap()["text"], "new");

    c.transaction(|tx| tx.set_channel("notify".into(), false))
        .unwrap();

    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "A",
        "the direct base survives the unsubscribe and the update reverts onto it"
    );
    assert!(
        c.read(&created()).unwrap().is_none(),
        "nothing claims the created record once its optimism is removed"
    );
    assert_eq!(table_count(&mut c, "ahead_subscription"), 0);
    assert_quiet(&mut c);
}

/// Settling without authority rebuilds from the base *plus* the edits that are
/// still pending: a later batch's edit is replayed on top and stays pending.
#[test]
fn remaining_pending_edits_replay_over_the_base() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");
    c.transaction(|tx| tx.enqueue(mutation("B")).map(|_| ()))
        .unwrap();
    c.freeze().unwrap().unwrap();
    c.transaction(|tx| tx.enqueue(mutation("C")).map(|_| ()))
        .unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);

    c.acknowledge(1, receipt("other", 3)).unwrap();

    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "C",
        "base plus the second edit, not the settled batch's optimistic value"
    );
    let status = c.record_status(&key()).unwrap();
    assert_eq!(status["pending"].as_array().unwrap().len(), 1);
    assert_eq!(status["pending"][0]["phase"], "queued");
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(
        c.before_image_count().unwrap(),
        1,
        "the base is kept while a mutation still touches the record"
    );
    assert!(c.rejections().unwrap().is_empty());

    c.freeze().unwrap().unwrap();
    c.acknowledge(2, receipt("other", 4)).unwrap();
    assert_eq!(
        c.read(&key()).unwrap().unwrap()["text"],
        "A",
        "the second batch settles onto the same base"
    );
    assert_quiet(&mut c);
}
