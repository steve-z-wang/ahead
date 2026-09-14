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
            let request = PullRequest {
                client_id: client.client_id().into(),
                channel: channel.clone(),
                from_cursor: client.cursor(channel)?,
            };
            let action = TransportAction {
                kind: "pull".into(),
                body: String::from_utf8(request.encode()?).map_err(|_| invalid("utf8"))?,
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
            let end = page.changes.len() < 50;
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
        let request = PullRequest {
            client_id: self.client_id().into(),
            channel: channel.into(),
            from_cursor: self.cursor(channel)?,
        };
        String::from_utf8(request.encode()?).map_err(|_| invalid("utf8"))
    }

    pub fn complete_downlink(&mut self, request: PullRequest, page: PullPage) -> Result<bool> {
        if page.channel != request.channel || page.from_cursor != request.from_cursor {
            return Err(invalid("response does not match pull request"));
        }
        let continues = page.changes.len() == 50;
        if continues && page.to_cursor <= page.from_cursor {
            return Err(invalid("pull page did not advance"));
        }
        self.apply_page(page)?;
        Ok(continues)
    }

    /// Live pages may duplicate or overlap HTTP catch-up. Recover unseen noncontiguous
    /// data via HTTP from the persisted cursor; never advance past a missing change.
    pub fn apply_downlink_live(&mut self, page: PullPage) -> Result<&'static str> {
        if !self.desired_channels()?.contains(&page.channel) {
            return Ok("covered");
        }
        let cursor = self.cursor(&page.channel)?;
        if page.to_cursor <= cursor {
            return Ok("covered");
        }
        if page.from_cursor != cursor {
            return Ok("recover");
        }
        self.apply_page(page)?;
        Ok("applied")
    }
}
