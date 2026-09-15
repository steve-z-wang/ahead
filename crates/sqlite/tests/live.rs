//! Live session transitions: the Rust controller drives a scripted host.
//! Real sockets and HTTP are the SDK suites' job; here every event is a
//! value and every action is asserted.
mod common;
use ahead_client::*;
use ahead_sqlite::SqliteStore;
use common::*;
use serde_json::json;

const PUSH_WAKE: LiveAction = LiveAction::Wake { lane: "push" };

fn text(page: &PullPage) -> String {
    String::from_utf8(page.encode().unwrap()).unwrap()
}
fn ack(scopes: &[&str]) -> String {
    let ack = SubscriptionAck::new(scopes.iter().map(|s| s.to_string()).collect()).unwrap();
    String::from_utf8(ack.encode().unwrap()).unwrap()
}
fn empty(channel: &str, at: u64) -> PullPage {
    PullPage {
        channel: channel.into(),
        from_cursor: at,
        to_cursor: at,
        changes: vec![],
    }
}
fn full(channel: &str, from: u64) -> PullPage {
    PullPage {
        channel: channel.into(),
        from_cursor: from,
        to_cursor: from + limits::PULL_CHANGES as u64,
        changes: (1..=limits::PULL_CHANGES as u64)
            .map(|i| RecordChange {
                cursor: from + i,
                model: "Entry".into(),
                identity: json!({"id":format!("{i}")}),
                stamp: from + i,
                state: json!({"text":"bulk","note":null}),
            })
            .collect(),
    }
}
fn request(action: &LiveAction) -> (u64, String, PullRequest) {
    match action {
        LiveAction::Request {
            epoch,
            channel,
            body,
        } => (
            *epoch,
            channel.clone(),
            PullRequest::decode(body.as_bytes()).unwrap(),
        ),
        other => panic!("expected a request, got {other:?}"),
    }
}
fn open(action: &LiveAction) -> (u64, SubscribeRequest) {
    match action {
        LiveAction::Open { epoch, subscribe } => (
            *epoch,
            SubscribeRequest::decode(subscribe.as_bytes()).unwrap(),
        ),
        other => panic!("expected an open, got {other:?}"),
    }
}
fn wait(action: &LiveAction) -> u64 {
    match action {
        LiveAction::Wait { millis } => *millis,
        other => panic!("expected a wait, got {other:?}"),
    }
}

struct Lane {
    client: Client<SqliteStore>,
    live: LiveSession,
    now: u64,
}
impl Lane {
    fn new(dir: &std::path::Path) -> Self {
        let mut client = common::open(&dir.join("db"));
        seed(&mut client, "local");
        Self {
            client,
            live: LiveSession::default(),
            now: 1_000,
        }
    }
    fn send(&mut self, event: LiveEvent) -> Vec<LiveAction> {
        self.live
            .handle(&mut self.client, event, self.now, 500)
            .unwrap()
    }
    fn message(&mut self, epoch: u64, body: String) -> Vec<LiveAction> {
        self.send(LiveEvent::Message { epoch, body })
    }
    fn catch_up(&mut self, epoch: u64, page: &PullPage) -> Vec<LiveAction> {
        self.send(LiveEvent::CatchUp {
            epoch,
            body: text(page),
        })
    }
    fn cursor(&mut self, channel: &str) -> u64 {
        self.client.cursor(channel).unwrap()
    }
    fn set(&mut self, channel: &str, subscribed: bool) {
        self.client
            .transaction(|tx| tx.set_channel(channel.into(), subscribed))
            .unwrap();
    }
}

#[test]
fn a_session_subscribes_catches_up_after_the_acknowledgement_and_then_streams() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.send(LiveEvent::Start);
    assert_eq!(
        lane.send(LiveEvent::Next),
        vec![],
        "no channels: the lane stays idle until a subscribe wakes it"
    );
    lane.set("a", true);
    let actions = lane.send(LiveEvent::Wake);
    let (epoch, subscribe) = open(&actions[0]);
    assert_eq!(subscribe.scopes, ["a"]);
    assert_eq!(actions.len(), 1);
    // A streamed page before the acknowledgement is a protocol violation.
    let early = lane.message(epoch, text(&page("a", 5, 6, Some("early"))));
    assert_eq!(
        early[0],
        LiveAction::Close {
            epoch,
            reason: Some("live page before acknowledgement".into())
        }
    );
    let backoff = wait(&early[1]);
    assert!((200..=300).contains(&backoff), "{backoff}");
    lane.now += backoff;
    let actions = lane.send(LiveEvent::Next);
    let (epoch, _) = open(&actions[0]);
    assert_eq!(epoch, 2, "each session has its own epoch");
    // The acknowledgement starts the catch-up from the durable cursor.
    let actions = lane.message(epoch, ack(&["a"]));
    let (e, channel, pull) = request(&actions[0]);
    assert_eq!((e, channel.as_str(), pull.from_cursor), (epoch, "a", 0));
    assert_eq!(actions.len(), 1);
    // Pages streamed while the channel catches up wait for the round to end,
    // then pass the cursor gate: one is covered by the catch-up, the one
    // beyond its head is a gap that starts another round.
    assert_eq!(
        lane.message(epoch, text(&page("a", 3, 4, Some("streamed")))),
        vec![]
    );
    assert_eq!(
        lane.message(epoch, text(&page("a", 5, 6, Some("beyond")))),
        vec![]
    );
    let actions = lane.catch_up(epoch, &page("a", 0, 4, Some("caught up")));
    assert_eq!(actions[0], PUSH_WAKE, "an applied page wakes the push lane");
    let (_, _, again) = request(&actions[1]);
    assert_eq!(
        again.from_cursor, 4,
        "the held gap recovers from the durable cursor"
    );
    assert_eq!(actions.len(), 2, "the covered page did nothing");
    assert_eq!(lane.cursor("a"), 4);
    assert_eq!(
        lane.client.read(&key()).unwrap().unwrap()["text"],
        "caught up"
    );
    assert_eq!(
        lane.catch_up(epoch, &page("a", 4, 6, Some("recovered gap"))),
        vec![PUSH_WAKE]
    );
    assert_eq!(lane.cursor("a"), 6);
    // Streaming: applied pages wake the push lane, covered pages do nothing.
    assert_eq!(
        lane.message(epoch, text(&page("a", 6, 7, Some("live")))),
        vec![PUSH_WAKE]
    );
    assert_eq!(
        lane.message(epoch, text(&page("a", 6, 7, Some("dup")))),
        vec![]
    );
    assert_eq!(lane.client.read(&key()).unwrap().unwrap()["text"], "live");
    // A gap recovers the affected channel from the durable cursor.
    let actions = lane.message(epoch, text(&page("a", 9, 10, Some("gap"))));
    let (_, _, recover) = request(&actions[0]);
    assert_eq!(recover.from_cursor, 7);
    assert_eq!(
        lane.catch_up(epoch, &page("a", 7, 10, Some("recovered"))),
        vec![PUSH_WAKE]
    );
    assert_eq!(lane.cursor("a"), 10);
    assert_eq!(
        lane.client.read(&key()).unwrap().unwrap()["text"],
        "recovered"
    );
}

#[test]
fn catch_up_runs_one_channel_at_a_time_and_a_full_page_continues() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("b", true);
    lane.set("a", true);
    let actions = lane.send(LiveEvent::Start);
    let (epoch, subscribe) = open(&actions[0]);
    assert_eq!(
        subscribe.scopes,
        ["a", "b"],
        "the frame carries the normalized set"
    );
    let actions = lane.message(epoch, ack(&["b", "a"]));
    let (_, channel, _) = request(&actions[0]);
    assert_eq!(channel, "a");
    assert_eq!(actions.len(), 1, "one request in flight at a time");
    let actions = lane.catch_up(epoch, &full("a", 0));
    assert_eq!(actions[0], PUSH_WAKE);
    let (_, channel, next) = request(&actions[1]);
    assert_eq!(
        (channel.as_str(), next.from_cursor),
        ("a", 50),
        "a full page continues"
    );
    let actions = lane.catch_up(epoch, &empty("a", 50));
    let (_, channel, next) = request(&actions[0]);
    assert_eq!(
        (channel.as_str(), next.from_cursor),
        ("b", 0),
        "then the next channel"
    );
    assert_eq!(lane.catch_up(epoch, &empty("b", 0)), vec![]);
}

#[test]
fn overflow_recovers_every_channel_without_abandoning_the_request_in_flight() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("a", true);
    lane.set("b", true);
    let (epoch, _) = open(&lane.send(LiveEvent::Start)[0]);
    let actions = lane.message(epoch, ack(&["a", "b"]));
    assert_eq!(request(&actions[0]).1, "a");
    assert_eq!(
        lane.send(LiveEvent::Overflow { epoch }),
        vec![],
        "the request keeps going"
    );
    // a finishes its round, then b runs its first round, then a runs again.
    let actions = lane.catch_up(epoch, &empty("a", 0));
    assert_eq!(request(&actions[0]).1, "b");
    let actions = lane.catch_up(epoch, &empty("b", 0));
    assert_eq!(request(&actions[0]).1, "a");
    assert_eq!(lane.catch_up(epoch, &empty("a", 0)), vec![]);
    // While streaming, an overflow starts a round for every channel, one at a time.
    let actions = lane.send(LiveEvent::Overflow { epoch });
    assert_eq!(request(&actions[0]).1, "a");
    assert_eq!(actions.len(), 1);
    // A second overflow during that round adds nothing to what is already queued.
    assert_eq!(lane.send(LiveEvent::Overflow { epoch }), vec![]);
    let actions = lane.catch_up(epoch, &empty("a", 0));
    assert_eq!(request(&actions[0]).1, "b");
    let actions = lane.catch_up(epoch, &empty("b", 0));
    assert_eq!(
        request(&actions[0]).1,
        "a",
        "a's own round was pending again"
    );
    assert_eq!(
        lane.catch_up(epoch, &empty("a", 0)),
        vec![],
        "b was queued once"
    );
}

#[test]
fn a_subscription_change_ends_the_session_and_the_next_one_uses_the_new_set() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("a", true);
    let (first, _) = open(&lane.send(LiveEvent::Start)[0]);
    let actions = lane.message(first, ack(&["a"]));
    let (_, _, pending) = request(&actions[0]);
    lane.set("b", true);
    // Whatever event comes next observes the committed change: the old session
    // closes without backoff and a new one opens with both channels.
    let actions = lane.send(LiveEvent::Wake);
    assert_eq!(
        actions[0],
        LiveAction::Close {
            epoch: first,
            reason: None
        }
    );
    let (second, subscribe) = open(&actions[1]);
    assert_eq!(subscribe.scopes, ["a", "b"]);
    assert_eq!(actions.len(), 2);
    // The old session's late responses and frames are ignored.
    assert_eq!(
        lane.catch_up(first, &page("a", pending.from_cursor, 3, Some("late"))),
        vec![]
    );
    assert_eq!(
        lane.message(first, text(&page("a", 0, 1, Some("old socket")))),
        vec![]
    );
    assert_eq!(lane.send(LiveEvent::Closed { epoch: first }), vec![]);
    assert_eq!(lane.cursor("a"), 0);
    // Unsubscribing everything ends the session and leaves the lane idle.
    lane.message(second, ack(&["a", "b"]));
    lane.set("a", false);
    lane.set("b", false);
    assert_eq!(
        lane.send(LiveEvent::Next),
        vec![LiveAction::Close {
            epoch: second,
            reason: None
        }]
    );
    assert_eq!(lane.send(LiveEvent::Next), vec![]);
}

#[test]
fn a_dropped_socket_reconnects_with_backoff_and_resubscribes() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("a", true);
    let (first, _) = open(&lane.send(LiveEvent::Start)[0]);
    lane.message(first, ack(&["a"]));
    lane.catch_up(first, &page("a", 0, 3, Some("before")));
    let actions = lane.send(LiveEvent::Closed { epoch: first });
    assert_eq!(
        actions[0],
        LiveAction::Close {
            epoch: first,
            reason: None
        },
        "the host closes whatever is left of the session"
    );
    let backoff = wait(&actions[1]);
    assert!((200..=300).contains(&backoff), "{backoff}");
    assert_eq!(
        lane.send(LiveEvent::Next),
        vec![LiveAction::Wait { millis: backoff }]
    );
    lane.now += backoff;
    let actions = lane.send(LiveEvent::Next);
    let (second, subscribe) = open(&actions[0]);
    assert_eq!(
        subscribe.scopes,
        ["a"],
        "resubscribes without an application event"
    );
    let actions = lane.message(second, ack(&["a"]));
    assert_eq!(
        request(&actions[0]).2.from_cursor,
        3,
        "catch-up resumes from the durable cursor"
    );
    // A second failure doubles the wait; a success resets it.
    let actions = lane.send(LiveEvent::Closed { epoch: second });
    assert!(wait(&actions[1]) > backoff);
}

#[test]
fn protocol_violations_close_with_a_reason_and_retry() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("a", true);
    let mut actions = lane.send(LiveEvent::Start);
    for (frame, reason) in [
        (
            ack(&["a", "b"]),
            "invalid live subscription acknowledgement",
        ),
        (
            r#"{"type":"subscribed","scopes":["a"],"rejections":[{"scope":"a"}]}"#.into(),
            "invalid live subscription acknowledgement",
        ),
        (
            r#"{"scope":"a","fromCursor":2,"toCursor":1,"changes":[]}"#.into(),
            "invalid live page: page moves backwards",
        ),
    ] {
        let (epoch, _) = open(&actions[0]);
        let closed = lane.message(epoch, frame);
        assert_eq!(
            closed[0],
            LiveAction::Close {
                epoch,
                reason: Some(reason.into())
            }
        );
        lane.now += wait(&closed[1]);
        actions = lane.send(LiveEvent::Next);
    }
    let (epoch, _) = open(&actions[0]);
    let actions = lane.message(epoch, ack(&["a"]));
    request(&actions[0]);
    let actions = lane.message(epoch, ack(&["a"]));
    assert_eq!(
        actions[0],
        LiveAction::Close {
            epoch,
            reason: Some("invalid live subscription acknowledgement".into())
        },
        "a second acknowledgement is a violation"
    );
    lane.now += wait(&actions[1]);
    // A catch-up response that does not answer the request ends the session too.
    let (epoch, _) = open(&lane.send(LiveEvent::Next)[0]);
    lane.message(epoch, ack(&["a"]));
    let actions = lane.catch_up(epoch, &empty("other", 0));
    assert_eq!(
        actions[0],
        LiveAction::Close {
            epoch,
            reason: Some("response does not match pull request".into())
        }
    );
}

#[test]
fn pause_ends_the_session_without_backoff_resume_reopens_and_stop_is_final() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("a", true);
    let (first, _) = open(&lane.send(LiveEvent::Start)[0]);
    lane.message(first, ack(&["a"]));
    assert_eq!(
        lane.send(LiveEvent::Pause),
        vec![LiveAction::Close {
            epoch: first,
            reason: None
        }]
    );
    assert_eq!(
        lane.send(LiveEvent::Wake),
        vec![],
        "paused: a wake schedules nothing"
    );
    assert_eq!(lane.send(LiveEvent::Closed { epoch: first }), vec![]);
    let actions = lane.send(LiveEvent::Resume);
    let (second, _) = open(&actions[0]);
    assert!(second > first);
    assert_eq!(
        lane.send(LiveEvent::Stop),
        vec![LiveAction::Close {
            epoch: second,
            reason: None
        }]
    );
    assert_eq!(lane.send(LiveEvent::Next), vec![]);
    assert_eq!(lane.send(LiveEvent::Wake), vec![]);
    assert_eq!(lane.send(LiveEvent::Resume), vec![]);
}

#[test]
fn a_page_from_a_previous_subscription_is_stale_not_a_gap_through_the_session() {
    let dir = tempfile::tempdir().unwrap();
    let mut lane = Lane::new(dir.path());
    lane.set("a", true);
    let (first, _) = open(&lane.send(LiveEvent::Start)[0]);
    let actions = lane.message(first, ack(&["a"]));
    let (_, _, issued) = request(&actions[0]);
    // Unsubscribe and resubscribe while the request is in flight.
    lane.set("a", false);
    lane.set("a", true);
    let actions = lane.send(LiveEvent::Next);
    assert_eq!(
        actions[0],
        LiveAction::Close {
            epoch: first,
            reason: None
        }
    );
    let (second, _) = open(&actions[1]);
    let actions = lane.message(second, ack(&["a"]));
    let (_, _, fresh) = request(&actions[0]);
    assert_eq!(fresh.from_cursor, 0);
    // The old answer cannot reach the new session (epoch), and even through
    // the engine's own gate it is stale rather than a gap.
    assert_eq!(
        lane.catch_up(first, &page("a", issued.from_cursor, 9, Some("obsolete"))),
        vec![]
    );
    assert_eq!(
        lane.catch_up(second, &page("a", 0, 1, Some("fresh"))),
        vec![PUSH_WAKE]
    );
    assert_eq!(lane.client.read(&key()).unwrap().unwrap()["text"], "fresh");
}
