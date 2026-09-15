//! The live session: subscribe over WebSocket, catch up over HTTP from the
//! durable cursor, stream pages, recover from gaps, overflow and subscription
//! changes. Rust decides; the host owns sockets, HTTP, timers, its frame
//! buffer and credential refresh, and reports what happened as events.
use crate::*;
use std::collections::VecDeque;

/// What the host tells the session. `now` and `entropy` travel beside the
/// event ([`LiveSession::handle`]); `epoch` names the session an I/O event
/// belongs to, so whatever an abandoned socket or request still delivers is
/// ignored.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(tag = "event", rename_all = "camelCase")]
pub enum LiveEvent {
    /// The lane starts; the first session begins on the next `next`.
    Start,
    /// The lane stops for good: the session ends and nothing is scheduled.
    Stop,
    /// The session ends without backoff; nothing runs until `resume`.
    Pause,
    Resume,
    /// Something changed that may need a session (a subscription committed).
    Wake,
    /// The host's timer fired, or it wants the next decision.
    Next,
    /// A frame arrived on the socket of this epoch.
    Message {
        epoch: u64,
        body: String,
    },
    /// The response to a `request` action of this epoch.
    CatchUp {
        epoch: u64,
        body: String,
    },
    /// The host's frame buffer for this epoch overflowed and frames were dropped.
    Overflow {
        epoch: u64,
    },
    /// The socket of this epoch closed, or a request of it failed. The host has
    /// already reported the error and refreshed credentials if it chose to.
    Closed {
        epoch: u64,
    },
}

/// What the host does next, in order.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LiveAction {
    /// Open the socket and send `subscribe` once it is open. Frames it delivers
    /// are `message` events of this epoch; its end is `closed`.
    Open { epoch: u64, subscribe: String },
    /// `POST /sync/pull` with `body`; the response is a `catchUp` event of this
    /// epoch, a failure is `closed`.
    Request {
        epoch: u64,
        channel: String,
        body: String,
    },
    /// Close the socket of this epoch and abandon its request, if any. A
    /// `reason` is a protocol violation the host reports as an error.
    Close { epoch: u64, reason: Option<String> },
    /// A page applied and may have settled a batch: wake the push lane.
    Wake { lane: &'static str },
    /// Nothing to do for `millis`; then report `next`.
    Wait { millis: u64 },
}

struct Request {
    channel: String,
    request: PullRequest,
}
impl Session {
    fn catching_up(&self, channel: &str) -> bool {
        self.active
            .as_ref()
            .is_some_and(|active| active.channel == channel)
            || self.queue.iter().any(|c| c == channel)
    }
}

struct Session {
    epoch: u64,
    /// The subscription generation the channels were snapshotted under.
    generation: u64,
    channels: Vec<String>,
    subscribe: SubscribeRequest,
    acknowledged: bool,
    /// Channels waiting for a catch-up round, in order; no duplicates.
    queue: VecDeque<String>,
    /// The one HTTP request in flight.
    active: Option<Request>,
    /// Channels that need another round once their current round ends.
    again: BTreeSet<String>,
    /// Streamed pages of channels still catching up. They pass the cursor gate
    /// once their channel's round ends; until then the catch-up is the truth.
    deferred: VecDeque<PullPage>,
}

/// Pages held for channels still catching up. Beyond this the held pages are
/// dropped and their channels recover from the durable cursor, like a host
/// buffer overflow; the host's own bound only governs delivery backpressure.
pub const DEFERRED_PAGES: usize = 64;

/// One live lane: [`ConnectionDriver`] scheduling around one session at a time.
#[derive(Default)]
pub struct LiveSession {
    driver: ConnectionDriver,
    epoch: u64,
    session: Option<Session>,
}

impl LiveSession {
    fn current(&self, epoch: u64) -> bool {
        self.session.as_ref().is_some_and(|s| s.epoch == epoch)
    }

    /// End the session; the host closes its socket and abandons its request.
    fn end(&mut self, reason: Option<String>, actions: &mut Vec<LiveAction>) {
        if let Some(session) = self.session.take() {
            actions.push(LiveAction::Close {
                epoch: session.epoch,
                reason,
            });
        }
    }

    /// A protocol violation or a transport failure: the session ends and the
    /// lane retries with backoff.
    fn fail(
        &mut self,
        reason: Option<String>,
        now: u64,
        entropy: u64,
        actions: &mut Vec<LiveAction>,
    ) {
        self.end(reason, actions);
        self.driver.complete(false, now, entropy);
    }

    pub fn handle<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
        event: LiveEvent,
        now: u64,
        entropy: u64,
    ) -> Result<Vec<LiveAction>> {
        let mut actions = vec![];
        // A committed subscribe or unsubscribe invalidates the session: the
        // lane starts over with the new channel set, without backoff.
        if self
            .session
            .as_ref()
            .is_some_and(|s| s.generation != client.subscription_generation())
        {
            self.end(None, &mut actions);
            self.driver.complete(true, now, 0);
            self.driver.wake();
        }
        match event {
            LiveEvent::Start => self.driver.start(now),
            LiveEvent::Stop => {
                self.end(None, &mut actions);
                self.driver.stop();
            }
            LiveEvent::Pause => {
                if self.session.is_some() {
                    self.end(None, &mut actions);
                    self.driver.complete(true, now, 0);
                }
                self.driver.pause();
            }
            LiveEvent::Resume => self.driver.resume(now),
            LiveEvent::Wake => self.driver.wake(),
            LiveEvent::Next => {}
            LiveEvent::Message { epoch, body } => {
                if self.current(epoch) {
                    self.message(client, &body, now, entropy, &mut actions)?;
                }
            }
            LiveEvent::CatchUp { epoch, body } => {
                if self.current(epoch) {
                    self.catch_up(client, &body, now, entropy, &mut actions)?;
                }
            }
            LiveEvent::Overflow { epoch } => {
                if self.current(epoch) {
                    self.overflow(client, &mut actions)?;
                }
            }
            LiveEvent::Closed { epoch } => {
                if self.current(epoch) {
                    self.fail(None, now, entropy, &mut actions);
                }
            }
        }
        if self.session.is_none() {
            match self.driver.next(now) {
                ConnectionAction::Sync => self.begin(client, now, &mut actions)?,
                ConnectionAction::Wait { millis } => actions.push(LiveAction::Wait { millis }),
                ConnectionAction::Idle => {}
            }
        }
        Ok(actions)
    }

    /// Snapshot the channels and the generation; with no channels the session
    /// ends successfully and the lane stays idle until a subscribe wakes it.
    fn begin<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
        now: u64,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        let channels: Vec<String> = client.desired_channels()?.into_iter().collect();
        if channels.is_empty() {
            self.driver.complete(true, now, 0);
            return Ok(());
        }
        let subscribe = SubscribeRequest::new(channels.clone(), client.declared_models())?;
        let frame = String::from_utf8(subscribe.encode()?).map_err(|_| invalid("utf8"))?;
        self.epoch += 1;
        self.session = Some(Session {
            epoch: self.epoch,
            generation: client.subscription_generation(),
            channels,
            subscribe,
            acknowledged: false,
            queue: VecDeque::new(),
            active: None,
            again: BTreeSet::new(),
            deferred: VecDeque::new(),
        });
        actions.push(LiveAction::Open {
            epoch: self.epoch,
            subscribe: frame,
        });
        Ok(())
    }

    fn message<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
        body: &str,
        now: u64,
        entropy: u64,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        let session = self.session.as_mut().expect("current session");
        let decoded = match LiveMessage::decode(body.as_bytes()) {
            Ok(decoded) => decoded,
            Err(e) => {
                self.fail(Some(e.to_string()), now, entropy, actions);
                return Ok(());
            }
        };
        match decoded {
            LiveMessage::Acknowledged(ack) => {
                if session.acknowledged || !ack.confirms(&session.subscribe) {
                    self.fail(
                        Some("invalid live subscription acknowledgement".into()),
                        now,
                        entropy,
                        actions,
                    );
                    return Ok(());
                }
                // Catch up every channel from its durable cursor before the
                // stream is trusted: streamed pages start at the server's head.
                session.acknowledged = true;
                session.queue = session.channels.iter().cloned().collect();
                self.advance(client, actions)
            }
            LiveMessage::Page(page) => {
                if !session.acknowledged {
                    self.fail(
                        Some("live page before acknowledgement".into()),
                        now,
                        entropy,
                        actions,
                    );
                    return Ok(());
                }
                if session.catching_up(&page.channel) {
                    self.defer(page);
                    return Ok(());
                }
                let channel = page.channel.clone();
                let progress = client.receive_downlink(page, None)?;
                self.settle(&channel, &progress, client, actions)
            }
        }
    }

    /// Hold a streamed page until its channel's catch-up round ends.
    fn defer(&mut self, page: PullPage) {
        let session = self.session.as_mut().expect("current session");
        if session.deferred.len() < DEFERRED_PAGES {
            session.deferred.push_back(page);
            return;
        }
        let mut lost: BTreeSet<String> = session.deferred.drain(..).map(|p| p.channel).collect();
        lost.insert(page.channel);
        for channel in lost {
            self.recover(&channel);
        }
    }

    /// The channel's round ended: its held pages go through the cursor gate in
    /// order. A gap among them starts another round and keeps the rest held.
    fn flush<S: ClientStore>(
        &mut self,
        channel: &str,
        client: &mut Client<S>,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        let session = self.session.as_mut().expect("current session");
        let (mine, rest): (Vec<_>, Vec<_>) = session
            .deferred
            .drain(..)
            .partition(|page| page.channel == channel);
        session.deferred = rest.into();
        let mut held = mine.into_iter();
        for page in held.by_ref() {
            let progress = client.receive_downlink(page, None)?;
            self.settle(channel, &progress, client, actions)?;
            if progress.disposition == "recover" {
                break;
            }
        }
        let session = self.session.as_mut().expect("current session");
        session.deferred.extend(held);
        Ok(())
    }

    /// After a page went through the cursor gate: an applied page may have
    /// settled a batch, a gap means the channel catches up again.
    fn settle<S: ClientStore>(
        &mut self,
        channel: &str,
        progress: &DownlinkProgress,
        client: &mut Client<S>,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        match progress.disposition {
            "applied" => actions.push(LiveAction::Wake { lane: "push" }),
            "recover" => {
                self.recover(channel);
                self.advance(client, actions)?;
            }
            _ => {}
        }
        Ok(())
    }

    /// The channel needs a catch-up round from the durable cursor: after the
    /// round in flight if that is its own, otherwise as soon as its turn comes.
    fn recover(&mut self, channel: &str) {
        let session = self.session.as_mut().expect("current session");
        if !session.acknowledged {
            return;
        }
        if session
            .active
            .as_ref()
            .is_some_and(|active| active.channel == channel)
        {
            session.again.insert(channel.to_string());
        } else if !session.queue.iter().any(|c| c == channel) {
            session.queue.push_back(channel.to_string());
        }
    }

    /// Frames were lost; which channels they belonged to is unknown, so every
    /// channel recovers. The request in flight keeps its progress.
    fn overflow<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        let channels = self
            .session
            .as_ref()
            .expect("current session")
            .channels
            .clone();
        for channel in &channels {
            self.recover(channel);
        }
        self.advance(client, actions)
    }

    /// Issue the next catch-up request when none is in flight.
    fn advance<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        let session = self.session.as_mut().expect("current session");
        if session.active.is_some() {
            return Ok(());
        }
        let Some(channel) = session.queue.pop_front() else {
            return Ok(());
        };
        let body = client.downlink_request(&channel)?;
        let request = PullRequest::decode(body.as_bytes())?;
        session.active = Some(Request {
            channel: channel.clone(),
            request,
        });
        actions.push(LiveAction::Request {
            epoch: session.epoch,
            channel,
            body,
        });
        Ok(())
    }

    fn catch_up<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
        body: &str,
        now: u64,
        entropy: u64,
        actions: &mut Vec<LiveAction>,
    ) -> Result<()> {
        let session = self.session.as_mut().expect("current session");
        let Some(active) = session.active.take() else {
            return Err(invalid("catch-up response without a request"));
        };
        let page = match PullPage::decode(body.as_bytes()) {
            Ok(page) => page,
            Err(e) => {
                self.fail(
                    Some(format!("invalid pull response: {e}")),
                    now,
                    entropy,
                    actions,
                );
                return Ok(());
            }
        };
        let progress = match client.receive_downlink(page, Some(active.request)) {
            Ok(progress) => progress,
            Err(e) if e.to_string() == "response does not match pull request" => {
                self.fail(Some(e.to_string()), now, entropy, actions);
                return Ok(());
            }
            Err(e) => return Err(e),
        };
        if progress.disposition == "applied" {
            actions.push(LiveAction::Wake { lane: "push" });
        }
        let session = self.session.as_mut().expect("current session");
        if progress.continues || progress.disposition == "recover" {
            // The round goes on from the durable cursor until a page is not full.
            session.queue.push_front(active.channel);
        } else if session.again.remove(&active.channel) {
            session.queue.push_back(active.channel);
        } else {
            self.flush(&active.channel, client, actions)?;
        }
        self.advance(client, actions)
    }
}
