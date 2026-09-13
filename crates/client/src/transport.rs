//! Runtime transport scheduling. Hosts execute bytes and return bytes; no SDK settlement logic.
use crate::*;
#[derive(Clone, Debug, Serialize)]
pub struct TransportAction {
    pub kind: String,
    pub body: String,
}
#[derive(Default)]
pub struct SyncCycle {
    completed: BTreeSet<String>,
    active: Option<TransportAction>,
}
impl SyncCycle {
    pub fn restart(&mut self) {
        self.completed.clear();
        self.active = None;
    }
    pub fn next<S: LegacyClientStore>(
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
        let mut channels = client.desired_channels();
        for batch in &client.snapshot().batches {
            if let Some(receipt) = &batch.receipt {
                for cp in &receipt.required_checkpoints {
                    channels.insert(cp.channel.clone());
                }
            }
        }
        if let Some(channel) = channels.iter().find(|c| !self.completed.contains(*c)) {
            let request = PullRequest {
                client_id: client.client_id().into(),
                channel: channel.clone(),
                from_cursor: client.cursor(channel),
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
    pub fn complete<S: LegacyClientStore>(
        &mut self,
        client: &mut Client<S>,
        bytes: &[u8],
    ) -> Result<()> {
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
