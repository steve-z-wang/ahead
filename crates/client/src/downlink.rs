//! Apply a Pull page: channel order by cursor, record content by stamp.
use crate::engine::Engine;
use crate::rows::merge_identity;
use crate::store::ClientStore;
use crate::{ApplyReport, Client};
use otter_core::{PullPage, RecordChange, Result, invalid};
use serde_json::json;

impl<S: ClientStore> Engine<'_, S> {
    pub fn apply_change(
        &mut self,
        channel: &str,
        change: &RecordChange,
        report: &mut ApplyReport,
    ) -> Result<()> {
        let key = self.schema.record_key(&change.model, &change.identity)?;
        let local = self.record_stamp(&key)?;
        let is_delete = change.state.is_null();
        let incoming = if is_delete {
            None
        } else {
            Some(merge_identity(
                &key.identity,
                &self.schema.validate_state(&change.model, &change.state)?,
            ))
        };
        let newer = match change.stamp {
            None => true,
            Some(stamp) if stamp > local => true,
            Some(stamp) if stamp < local => false,
            Some(stamp) => {
                // equal stamp: idempotent when content matches, diagnostic otherwise
                let current = self.truth(&key)?;
                if current != incoming {
                    report.conflicts += 1;
                    report.diagnostics.push(json!({
                        "model": key.model, "identity": key.identity, "stamp": stamp, "channel": channel,
                        "local": current, "incoming": incoming,
                    }));
                }
                false
            }
        };
        if !newer {
            if is_delete {
                self.claim_remove(channel, &key)?;
                if self.read_row(&key)?.is_none()
                    && !self.dirty(&key)?
                    && self.claims(&key)?.is_empty()
                {
                    self.drop_record(&key)?;
                }
            } else {
                self.claim_add(channel, &key)?;
            }
            return Ok(());
        }
        if is_delete {
            match change.stamp {
                // An unstamped delete carries no order, and the server emits one both
                // for a true delete and for a record that merely left this channel.
                // It may therefore release only the delivering channel's claim; the
                // record goes when the last claim does. No stamp is written.
                None => {
                    self.claim_remove(channel, &key)?;
                    if self.claims(&key)?.is_empty() {
                        self.set_authority(&key, None)?;
                        self.drop_record(&key)?;
                    }
                }
                Some(stamp) => {
                    self.set_authority(&key, None)?;
                    self.claim_remove(channel, &key)?;
                    if self.claims(&key)?.is_empty() {
                        self.drop_record(&key)?;
                    } else {
                        self.set_record_stamp(&key, stamp)?;
                    }
                }
            }
        } else {
            self.set_authority(&key, incoming)?;
            self.claim_add(channel, &key)?;
            self.set_record_stamp(&key, change.stamp.unwrap_or(local))?;
        }
        Ok(())
    }
}

impl<S: ClientStore> Client<S> {
    /// Per-change commits; a failing change is skipped and the cursor still advances (reference behavior).
    pub fn apply_page(&mut self, page: PullPage) -> Result<ApplyReport> {
        page.validate()?;
        // A subscription row exists iff the client is subscribed. Applying a page for
        // any other channel would insert one through `set_cursor` and re-claim every
        // record it carries, so a page for an unsubscribed channel - a pull still in
        // flight when the unsubscribe committed - is dropped without writing anything.
        let Some(current) = self.view(|e| e.cursor(&page.channel))? else {
            return Ok(ApplyReport {
                stale: true,
                ..Default::default()
            });
        };
        if page.to_cursor <= current {
            return Ok(ApplyReport {
                stale: true,
                ..Default::default()
            });
        }
        if page.from_cursor > current {
            return Err(invalid("pull cursor gap"));
        }
        let mut report = ApplyReport::default();
        for change in page.changes.iter().filter(|c| c.cursor > current) {
            let channel = page.channel.clone();
            self.write(|e| {
                let expected = e.cursor(&channel)?.unwrap_or(0);
                if expected >= change.cursor {
                    return Err(invalid("cursor moved during page application"));
                }
                e.store.savepoint("change")?;
                match e.apply_change(&channel, change, &mut report) {
                    Ok(()) => {
                        e.store.release("change")?;
                        report.applied += 1;
                    }
                    Err(_) => {
                        e.store.rollback_to("change")?;
                        report.skipped += 1;
                    }
                }
                e.set_cursor(&channel, change.cursor)?;
                e.settle()
            })?;
        }
        if self.cursor(&page.channel)? < page.to_cursor {
            let channel = page.channel.clone();
            self.write(|e| {
                e.set_cursor(&channel, page.to_cursor)?;
                e.settle()
            })?;
        }
        Ok(report)
    }
}
