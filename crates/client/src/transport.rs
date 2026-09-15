//! Runtime transport scheduling. Hosts execute bytes and return bytes; no SDK settlement logic.
use crate::*;
#[derive(Clone, Debug, Serialize)]
pub struct TransportAction {
    pub kind: String,
    pub body: String,
}
#[derive(Default)]
pub struct SyncCycle {
    push_only: bool,
    completed: BTreeSet<String>,
    active: Option<TransportAction>,
}
impl SyncCycle {
    pub fn restart(&mut self) {
        self.completed.clear();
        self.active = None;
        self.push_only = false;
    }
    /// Use HTTP only for queued writes; authoritative pages arrive through the live stream.
    pub fn restart_push_only(&mut self) {
        self.restart();
        self.push_only = true;
    }
    pub fn next<S: ClientStore>(
        &mut self,
        client: &mut Client<S>,
    ) -> Result<Option<TransportAction>> {
        if let Some(action) = &self.active {
            return Ok(Some(action.clone()));
        }
        if let Some(bytes) = client.freeze()? {
            let action = TransportAction {
                kind: "push".into(),
                body: String::from_utf8(bytes).map_err(|_| invalid("utf8"))?,
            };
            self.active = Some(action.clone());
            return Ok(Some(action));
        }
        if self.push_only {
            return Ok(None);
        }
        // Subscribed channels only: a pull on any other channel would be discarded by
        // `apply_page`, and a checkpoint the client cannot await settles on arrival.
        let channels = client.desired_channels()?;
        if let Some(channel) = channels.iter().find(|c| !self.completed.contains(*c)) {
            let action = TransportAction {
                kind: "pull".into(),
                body: client.downlink_request(channel)?,
            };
            self.active = Some(action.clone());
            return Ok(Some(action));
        }
        Ok(None)
    }
    pub fn complete<S: ClientStore>(&mut self, client: &mut Client<S>, bytes: &[u8]) -> Result<()> {
        let action = self
            .active
            .clone()
            .ok_or_else(|| invalid("no transport action"))?;
        if action.kind == "push" {
            let request = PushRequest::decode(action.body.as_bytes())?;
            client.acknowledge(request.batch_sequence, PushReceipt::decode(bytes)?)?;
            self.completed.clear();
        } else {
            let request = PullRequest::decode(action.body.as_bytes())?;
            let page = PullPage::decode(bytes)?;
            if page.channel != request.channel || page.from_cursor != request.from_cursor {
                return Err(invalid("response does not match pull request"));
            }
            let end = !page.continues();
            client.apply_page(page)?;
            if end {
                self.completed.insert(request.channel);
            }
        }
        self.active = None;
        Ok(())
    }
}

impl<S: ClientStore> Client<S> {
    /// The downlink never borrows the mutation cycle: HTTP writes can progress independently.
    pub fn downlink_request(&mut self, channel: &str) -> Result<String> {
        if !self.desired_channels()?.iter().any(|c| c == channel) {
            return Err(invalid("channel is not subscribed"));
        }
        let from_cursor = self.cursor(channel)?;
        let request = PullRequest {
            client_id: self.client_id().into(),
            channel: channel.into(),
            from_cursor,
            models: self.declared_models(),
        };
        self.pulls.issue(channel, from_cursor);
        String::from_utf8(request.encode()?).map_err(|_| invalid("utf8"))
    }

    /// Whether a page answers a pull this client issued under an earlier
    /// subscription of its channel. Such a page is stale: the resubscribe reset
    /// the cursor and a fresh pull from it delivers everything.
    pub(crate) fn stale_subscription_page(&mut self, page: &PullPage) -> bool {
        self.pulls.stale(&page.channel, page.from_cursor)
    }

    /// One incoming path for HTTP catch-up and WebSocket pages. Optional request
    /// metadata only validates HTTP response identity; cursor policy is shared.
    pub fn receive_downlink(
        &mut self,
        page: PullPage,
        request: Option<PullRequest>,
    ) -> Result<DownlinkProgress> {
        page.validate()?;
        if let Some(request) = request
            && (page.channel != request.channel || page.from_cursor != request.from_cursor)
        {
            return Err(invalid("response does not match pull request"));
        }
        let continues = page.continues();
        let cursor = self.cursor(&page.channel)?;
        let disposition = if self.stale_subscription_page(&page)
            || !self.desired_channels()?.contains(&page.channel)
            || page.to_cursor <= cursor
        {
            "covered"
        } else if page.from_cursor > cursor {
            "recover"
        } else {
            // The page passed the epoch check above; the cursor gate below filters
            // changes already covered by the durable cursor.
            self.apply_current_page(page)?;
            "applied"
        };
        Ok(DownlinkProgress {
            disposition,
            continues,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct DownlinkProgress {
    pub disposition: &'static str,
    pub continues: bool,
}
