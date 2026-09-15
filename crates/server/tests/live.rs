//! Transition tests for the per-socket live controller
//! ([Server / Connection / Controller](../../../docs/engineering/architecture/server/connection/controller.md)).
//! Pure state: no host, no socket, no database.
use ahead_core::{PullPage, RecordChange, limits};
use ahead_server::live::{LiveAction, LiveEvent, Negotiation, Subscription, Subscriptions};
use serde_json::json;

fn negotiation(scopes: &[(&str, u64)]) -> Negotiation {
    Negotiation {
        response: r#"{"type":"subscribed","scopes":[],"rejections":[]}"#.into(),
        subscriptions: scopes
            .iter()
            .map(|(scope, from_cursor)| Subscription {
                scope: (*scope).into(),
                from_cursor: *from_cursor,
            })
            .collect(),
    }
}

/// A page for `scope` holding one change per cursor in `from + 1 ..= to`,
/// capped at the page limit; `to` beyond the cap is the page's `toCursor`.
fn page(scope: &str, from: u64, to: u64) -> String {
    let changes = (from + 1..=to)
        .take(limits::PULL_CHANGES)
        .map(|cursor| RecordChange {
            cursor,
            model: "Task".into(),
            identity: json!({"id": cursor}),
            stamp: cursor,
            state: json!(null),
        })
        .collect();
    let page = PullPage {
        channel: scope.into(),
        from_cursor: from,
        to_cursor: to,
        changes,
    };
    String::from_utf8(page.encode().unwrap()).unwrap()
}

fn pull(scope: &str, from_cursor: u64) -> LiveAction {
    LiveAction::Pull {
        scope: scope.into(),
        from_cursor,
    }
}

fn committed(scope: &str) -> LiveEvent {
    LiveEvent::Committed {
        scope: scope.into(),
    }
}

fn pulled(scope: &str, page: &str) -> LiveEvent {
    LiveEvent::Pulled {
        scope: scope.into(),
        page: page.into(),
    }
}

#[test]
fn open_registers_every_scope_before_the_acknowledgement_then_pulls_each_once_from_its_head() {
    let (subscriptions, actions) = Subscriptions::open(negotiation(&[("a", 3), ("b", 0)]));
    assert_eq!(
        actions,
        vec![
            LiveAction::Listen { scope: "a".into() },
            LiveAction::Listen { scope: "b".into() },
            LiveAction::Send {
                frame: r#"{"type":"subscribed","scopes":[],"rejections":[]}"#.into()
            },
            pull("a", 3),
            pull("b", 0),
        ]
    );
    assert!(subscriptions.scopes().iter().all(|state| state.running));
    assert!(!subscriptions.is_closed());
}

#[test]
fn a_commit_observed_during_a_pull_produces_one_more_pull_after_it() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 3)]));
    assert_eq!(subscriptions.handle(committed("a")).unwrap(), vec![]);
    let actions = subscriptions.handle(pulled("a", &page("a", 3, 4))).unwrap();
    assert_eq!(
        actions,
        vec![
            LiveAction::Send {
                frame: page("a", 3, 4)
            },
            pull("a", 4)
        ]
    );
    let actions = subscriptions.handle(pulled("a", &page("a", 4, 4))).unwrap();
    assert_eq!(actions, vec![], "a page that did not advance is not sent");
    assert!(!subscriptions.scopes()[0].running);
}

#[test]
fn two_commits_during_one_pull_produce_one_extra_pull_not_two() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 0)]));
    assert_eq!(subscriptions.handle(committed("a")).unwrap(), vec![]);
    assert_eq!(subscriptions.handle(committed("a")).unwrap(), vec![]);
    let actions = subscriptions.handle(pulled("a", &page("a", 0, 2))).unwrap();
    assert_eq!(
        actions,
        vec![
            LiveAction::Send {
                frame: page("a", 0, 2)
            },
            pull("a", 2)
        ]
    );
    let actions = subscriptions.handle(pulled("a", &page("a", 2, 2))).unwrap();
    assert_eq!(actions, vec![]);
    assert!(!subscriptions.scopes()[0].running);
    assert!(!subscriptions.scopes()[0].pending);
}

#[test]
fn a_full_page_continues_from_its_end_and_a_short_page_ends_the_drain() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 0)]));
    let full = limits::PULL_CHANGES as u64;
    let actions = subscriptions
        .handle(pulled("a", &page("a", 0, full)))
        .unwrap();
    assert_eq!(
        actions,
        vec![
            LiveAction::Send {
                frame: page("a", 0, full)
            },
            pull("a", full)
        ]
    );
    let actions = subscriptions
        .handle(pulled("a", &page("a", full, full + 1)))
        .unwrap();
    assert_eq!(
        actions,
        vec![LiveAction::Send {
            frame: page("a", full, full + 1)
        }]
    );
    let state = &subscriptions.scopes()[0];
    assert!(!state.running);
    assert_eq!(state.cursor, full + 1);
    assert_eq!(
        subscriptions.handle(committed("a")).unwrap(),
        vec![pull("a", full + 1)],
        "the next commit pulls again from the streamed cursor"
    );
}

#[test]
fn scopes_drain_independently() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 0), ("b", 0)]));
    let actions = subscriptions.handle(pulled("b", &page("b", 0, 0))).unwrap();
    assert_eq!(actions, vec![]);
    assert_eq!(
        subscriptions.handle(committed("b")).unwrap(),
        vec![pull("b", 0)]
    );
    assert_eq!(
        subscriptions.handle(committed("a")).unwrap(),
        vec![],
        "a's first pull is still outstanding"
    );
}

#[test]
fn after_closed_no_event_produces_an_action_and_a_late_page_is_not_sent() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 0), ("b", 0)]));
    assert_eq!(subscriptions.handle(committed("a")).unwrap(), vec![]);
    assert_eq!(subscriptions.handle(LiveEvent::Closed).unwrap(), vec![]);
    assert!(subscriptions.is_closed());
    assert!(subscriptions.scopes().iter().all(|state| !state.pending));
    assert_eq!(
        subscriptions.handle(pulled("a", &page("a", 0, 5))).unwrap(),
        vec![]
    );
    assert!(!subscriptions.scopes()[0].running);
    assert_eq!(subscriptions.handle(committed("a")).unwrap(), vec![]);
    assert_eq!(subscriptions.handle(committed("b")).unwrap(), vec![]);
    assert_eq!(subscriptions.handle(LiveEvent::Closed).unwrap(), vec![]);
}

#[test]
fn invalid_page_progression_is_an_error() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 3)]));
    let wrong_cursor = subscriptions
        .handle(pulled("a", &page("a", 4, 5)))
        .unwrap_err();
    assert_eq!(wrong_cursor.code, ahead_server::code::LIVE_INVALID_PAGE);
    let wrong_scope = subscriptions
        .handle(pulled("a", &page("b", 3, 5)))
        .unwrap_err();
    assert_eq!(wrong_scope.code, ahead_server::code::LIVE_INVALID_PAGE);
    let malformed = subscriptions.handle(pulled("a", "{")).unwrap_err();
    assert_eq!(malformed.code, ahead_server::code::LIVE_INVALID_PAGE);
}

#[test]
fn an_unknown_scope_or_an_unrequested_page_is_a_host_defect() {
    let (mut subscriptions, _) = Subscriptions::open(negotiation(&[("a", 0)]));
    let unknown = subscriptions.handle(committed("zzz")).unwrap_err();
    assert_eq!(unknown.code, ahead_server::code::LIVE_INVALID_EVENT);
    let unknown = subscriptions
        .handle(pulled("zzz", &page("zzz", 0, 0)))
        .unwrap_err();
    assert_eq!(unknown.code, ahead_server::code::LIVE_INVALID_EVENT);
    subscriptions.handle(pulled("a", &page("a", 0, 0))).unwrap();
    let unrequested = subscriptions
        .handle(pulled("a", &page("a", 0, 0)))
        .unwrap_err();
    assert_eq!(unrequested.code, ahead_server::code::LIVE_INVALID_EVENT);
}

#[test]
fn events_and_actions_cross_the_boundary_as_tagged_json() {
    let event: LiveEvent =
        serde_json::from_str(r#"{"type":"pulled","scope":"a","page":"{}"}"#).unwrap();
    assert_eq!(event, pulled("a", "{}"));
    let closed: LiveEvent = serde_json::from_str(r#"{"type":"closed"}"#).unwrap();
    assert_eq!(closed, LiveEvent::Closed);
    assert_eq!(
        serde_json::to_value(pull("a", 7)).unwrap(),
        json!({"type":"pull","scope":"a","fromCursor":7})
    );
    assert_eq!(
        serde_json::to_value(LiveAction::Listen { scope: "a".into() }).unwrap(),
        json!({"type":"listen","scope":"a"})
    );
}
