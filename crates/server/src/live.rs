//! The live subscription controller: negotiation, page validation, and the
//! per-socket drain policy ([`Subscriptions`]). The host owns the socket, the
//! commit hub and the database; it feeds [`LiveEvent`]s and executes the
//! [`LiveAction`]s it gets back, keeping no sync decision of its own.
use crate::{Error, Host, Result, code, head, principal, process_pull};
use ahead_core::{PullPage, SubscribeRequest, SubscriptionAck};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscription {
    pub scope: String,
    pub from_cursor: u64,
}

#[derive(Debug, Serialize)]
pub struct Negotiation {
    pub response: String,
    pub subscriptions: Vec<Subscription>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageProgress {
    pub page: String,
    pub to_cursor: u64,
    pub continues: bool,
}

/// The subscribe frame's shape and scope normalization are protocol rules
/// ([`SubscribeRequest`]); this maps their refusal to the request code.
pub fn decode_subscribe(bytes: &[u8]) -> Result<Vec<String>> {
    SubscribeRequest::decode(bytes)
        .map(|request| request.scopes)
        .map_err(|e| Error::new(code::REQUEST_INVALID, e.to_string()))
}

pub async fn negotiate(owner: &str, bytes: &[u8], host: &impl Host) -> Result<Negotiation> {
    principal(owner)?;
    let scopes = decode_subscribe(bytes)?;
    let mut accepted = vec![];
    for scope in scopes {
        let from_cursor = head(host, &scope).await?;
        accepted.push(Subscription { scope, from_cursor });
    }
    let ack = SubscriptionAck::new(accepted.iter().map(|entry| entry.scope.clone()).collect())
        .and_then(|ack| ack.encode())
        .map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
    let response =
        String::from_utf8(ack).map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
    Ok(Negotiation {
        response,
        subscriptions: accepted,
    })
}

pub fn page_progress(
    page: &str,
    expected_scope: &str,
    expected_cursor: u64,
) -> Result<PageProgress> {
    let invalid = |m: String| Error::new(code::LIVE_INVALID_PAGE, m);
    let decoded = PullPage::decode(page.as_bytes())
        .map_err(|e| invalid(format!("invalid live page: {e}")))?;
    if decoded.channel != expected_scope {
        return Err(invalid("invalid live page scope".into()));
    }
    if decoded.from_cursor != expected_cursor {
        return Err(invalid("invalid live page progression".into()));
    }
    Ok(PageProgress {
        page: page.into(),
        to_cursor: decoded.to_cursor,
        continues: decoded.continues(),
    })
}

pub async fn pull(
    config: &crate::Config,
    owner: &str,
    scope: &str,
    from_cursor: u64,
    host: &impl Host,
) -> Result<PageProgress> {
    let request =
        serde_json::to_vec(&json!({"clientId":"live","scope":scope,"fromCursor":from_cursor}))
            .map_err(|error| Error::new(code::INTERNAL, error.to_string()))?;
    let page = process_pull(config, owner, &request, host).await?;
    page_progress(&page, scope, from_cursor)
}

/// What the host reports to a socket's [`Subscriptions`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum LiveEvent {
    /// A transaction that touched `scope` committed (from the host's commit hub).
    Committed { scope: String },
    /// The host finished the pull a [`LiveAction::Pull`] asked for; `page` is
    /// the page text `pull` returned.
    Pulled { scope: String, page: String },
    /// The socket closed or failed; nothing more will be sent.
    Closed,
}

/// What the host executes, in order, for one event.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum LiveAction {
    /// Register a commit listener for `scope`; the host reports each commit as
    /// [`LiveEvent::Committed`]. Issued before anything is sent.
    Listen { scope: String },
    /// Send this frame on the socket (the acknowledgement or a page).
    Send { frame: String },
    /// Run `pull(owner, scope, from_cursor)` in a transaction and report the
    /// page as [`LiveEvent::Pulled`]. At most one pull per scope is outstanding.
    Pull { scope: String, from_cursor: u64 },
}

/// One accepted scope: the cursor streamed so far, whether a commit arrived
/// while a pull was outstanding, and whether a pull is outstanding.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScopeState {
    pub scope: String,
    pub cursor: u64,
    pub pending: bool,
    pub running: bool,
}

/// The per-socket state machine. Registration precedes the acknowledgement,
/// and every scope is drained once from its negotiated head, so a commit
/// landing between negotiation and registration is caught by that first
/// drain. Within a scope pulls are sequential: a commit observed during a
/// pull queues exactly one more, a full page continues from its end, and a
/// short page ends the drain.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Subscriptions {
    scopes: Vec<ScopeState>,
    closed: bool,
}

impl Subscriptions {
    /// Starts the session for a negotiation: `[Listen …, Send ack, Pull …]`,
    /// one `Listen` and one `Pull` per accepted scope in acknowledgement order.
    pub fn open(negotiation: Negotiation) -> (Self, Vec<LiveAction>) {
        let scopes: Vec<ScopeState> = negotiation
            .subscriptions
            .into_iter()
            .map(|subscription| ScopeState {
                scope: subscription.scope,
                cursor: subscription.from_cursor,
                pending: false,
                running: true,
            })
            .collect();
        let mut actions: Vec<LiveAction> = scopes
            .iter()
            .map(|state| LiveAction::Listen {
                scope: state.scope.clone(),
            })
            .collect();
        actions.push(LiveAction::Send {
            frame: negotiation.response,
        });
        actions.extend(scopes.iter().map(|state| LiveAction::Pull {
            scope: state.scope.clone(),
            from_cursor: state.cursor,
        }));
        (
            Self {
                scopes,
                closed: false,
            },
            actions,
        )
    }

    /// Applies one event and answers the actions it calls for. An event the
    /// session cannot accept (an unknown scope, or a `Pulled` no pull is
    /// outstanding for) is a host defect reported as `live.invalid_event`; an
    /// invalid page progression is `live.invalid_page`. The host reports either
    /// and closes the socket.
    pub fn handle(&mut self, event: LiveEvent) -> Result<Vec<LiveAction>> {
        match event {
            LiveEvent::Committed { scope } => {
                let closed = self.closed;
                let state = self.scope_mut(&scope)?;
                if closed {
                    return Ok(vec![]);
                }
                state.pending = true;
                if state.running {
                    return Ok(vec![]);
                }
                state.running = true;
                state.pending = false;
                Ok(vec![LiveAction::Pull {
                    scope,
                    from_cursor: state.cursor,
                }])
            }
            LiveEvent::Pulled { scope, page } => {
                let closed = self.closed;
                let state = self.scope_mut(&scope)?;
                if !state.running {
                    return Err(Error::new(
                        code::LIVE_INVALID_EVENT,
                        format!("no pull is outstanding for scope {scope}"),
                    ));
                }
                if closed {
                    state.running = false;
                    return Ok(vec![]);
                }
                let progress = page_progress(&page, &scope, state.cursor)?;
                let mut actions = vec![];
                if progress.to_cursor > state.cursor {
                    actions.push(LiveAction::Send {
                        frame: progress.page,
                    });
                }
                state.cursor = progress.to_cursor;
                if progress.continues {
                    actions.push(LiveAction::Pull {
                        scope,
                        from_cursor: state.cursor,
                    });
                } else if state.pending {
                    state.pending = false;
                    actions.push(LiveAction::Pull {
                        scope,
                        from_cursor: state.cursor,
                    });
                } else {
                    state.running = false;
                }
                Ok(actions)
            }
            LiveEvent::Closed => {
                self.closed = true;
                for state in &mut self.scopes {
                    state.pending = false;
                }
                Ok(vec![])
            }
        }
    }

    /// The accepted scopes in acknowledgement order, with their drain state.
    pub fn scopes(&self) -> &[ScopeState] {
        &self.scopes
    }

    /// Whether `Closed` was observed; nothing is sent afterwards.
    pub fn is_closed(&self) -> bool {
        self.closed
    }

    fn scope_mut(&mut self, scope: &str) -> Result<&mut ScopeState> {
        self.scopes
            .iter_mut()
            .find(|state| state.scope == scope)
            .ok_or_else(|| {
                Error::new(
                    code::LIVE_INVALID_EVENT,
                    format!("scope {scope} is not subscribed"),
                )
            })
    }
}
