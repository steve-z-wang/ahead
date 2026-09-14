//! Acceptance scenarios for per-record stamps across channels.
mod common;
use common::*;
use otter_client::*;

fn stamped(channel: &str, from: u64, to: u64, stamp: u64, text: Option<&str>) -> PullPage {
    let mut p = page(channel, from, to, text);
    p.changes[0].stamp = stamp;
    p
}

/// Spec scenario 1: the newer content arrives through B first; A's delayed older page
/// cannot regress it, but A's cursor still advances and A's claim is recorded.
#[test]
fn delayed_page_from_another_channel_cannot_regress_newer_content() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("b", 0, 5, 8, Some("new"))).unwrap();
    let report = c.apply_page(stamped("a", 0, 10, 7, Some("old"))).unwrap();
    assert_eq!(report.applied, 1);
    assert_eq!(report.conflicts, 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "new");
    assert_eq!(c.cursor("a").unwrap(), 10);
    assert_eq!(c.cursor("b").unwrap(), 5);
    assert_eq!(table_count(&mut c, "otter_claim"), 2);
    // A catches up with the same change at its own stamp: still nothing to change.
    c.apply_page(stamped("a", 10, 11, 9, Some("new"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "new");
}

/// Spec scenario 2: the same page delivered twice is idempotent.
#[test]
fn redelivered_page_is_a_no_op() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    let again = c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    assert!(again.stale);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
}

/// Spec scenario 6: a delete with a newer stamp removes the record on the first channel
/// that delivers it; the tombstone survives until every claiming channel has delivered
/// the delete; an older upsert arriving in between is discarded.
#[test]
fn delete_across_channels_keeps_a_tombstone_until_every_claim_confirms() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    c.apply_page(stamped("b", 0, 1, 2, Some("B"))).unwrap();
    // The delete reaches B first (stamp 4): record gone, A's claim remains as the tombstone marker.
    c.apply_page(stamped("b", 1, 2, 4, None)).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    // A delayed older upsert (stamp 3) on A must not resurrect the record.
    c.apply_page(stamped("a", 1, 2, 3, Some("A2"))).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    // A's copy of the delete (stamp 5, A's own notification) clears the last claim and the tombstone.
    c.apply_page(stamped("a", 2, 3, 5, None)).unwrap();
    assert_eq!(table_count(&mut c, "otter_claim"), 0);
    assert_eq!(table_count(&mut c, "otter_record"), 0);
}

/// Spec scenario 5: a record moves A -> B -> A. Each hop is a delete on the old channel and
/// an upsert on the new one, in either arrival order.
#[test]
fn move_between_channels_and_back() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("in A"))).unwrap();
    // Move to B: the app notifies both; B's upsert (stamp 3) arrives before A's delete (stamp 2).
    c.apply_page(stamped("b", 0, 1, 3, Some("in B"))).unwrap();
    c.apply_page(stamped("a", 1, 2, 2, None)).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "in B");
    assert_eq!(c.claims_of(&key()).unwrap(), vec!["b".to_string()]);
    // Move back to A: A's upsert (stamp 4) then B's delete (stamp 5).
    c.apply_page(stamped("a", 2, 3, 4, Some("back in A")))
        .unwrap();
    c.apply_page(stamped("b", 1, 2, 5, None)).unwrap();
    assert!(
        c.read(&key()).unwrap().is_none(),
        "the newest stamp is B's delete"
    );
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
    // The app's next notification on A (stamp 6) restores it.
    c.apply_page(stamped("a", 3, 4, 6, Some("back in A")))
        .unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "back in A");
    assert_eq!(c.claims_of(&key()).unwrap(), vec!["a".to_string()]);
}

/// Spec scenario 8: stamps, claims and tombstones survive close and reopen.
#[test]
fn reopen_preserves_stamps_claims_and_tombstones() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    c.apply_page(stamped("b", 0, 1, 2, Some("B"))).unwrap();
    c.apply_page(stamped("b", 1, 2, 4, None)).unwrap();
    drop(c);
    let mut c = open(&path);
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
    c.apply_page(stamped("a", 1, 2, 3, Some("stale"))).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    c.apply_page(stamped("a", 2, 3, 5, None)).unwrap();
    assert_eq!(table_count(&mut c, "otter_record"), 0);
}
