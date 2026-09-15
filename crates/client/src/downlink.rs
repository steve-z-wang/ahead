//! Apply a Pull page: channel order by cursor, record content by stamp.
use crate::authority::Disposition;
use crate::engine::Engine;
use crate::store::ClientStore;
use crate::{ApplyReport, Client};
use ahead_core::{AuthorityRecord, PullPage, RecordChange, Result, invalid};
use serde_json::json;

impl<S: ClientStore> Engine<'_, S> {
    /// Apply one channel change through the common applier. The channel only
    /// names the diagnostic; content is ordered by stamp.
    pub fn apply_change(
        &mut self,
        channel: &str,
        change: &RecordChange,
        report: &mut ApplyReport,
    ) -> Result<()> {
        let record: AuthorityRecord = change.clone().into();
        if let Disposition::Conflict { local, incoming } = self.apply_authority(&record)? {
            report.conflicts += 1;
            report.diagnostics.push(json!({
                "model": record.model, "identity": record.identity, "stamp": record.stamp, "channel": channel,
                "local": local, "incoming": incoming,
            }));
        }
        Ok(())
    }
}

impl<S: ClientStore> Client<S> {
    /// Per-change commits; a failing change is skipped and the cursor still advances (reference behavior).
    pub fn apply_page(&mut self, page: PullPage) -> Result<ApplyReport> {
        page.validate()?;
        // A page answering a pull issued before the channel was unsubscribed and
        // subscribed again was built against a cursor this subscription no longer
        // has; it is stale, not a gap, and the next pull from the reset cursor
        // delivers everything.
        if self.stale_subscription_page(&page) {
            return Ok(ApplyReport {
                stale: true,
                ..Default::default()
            });
        }
        self.apply_current_page(page)
    }
    /// `apply_page` after the subscription-epoch check; the check consumes the
    /// matching request, so each incoming page runs it exactly once.
    pub(crate) fn apply_current_page(&mut self, page: PullPage) -> Result<ApplyReport> {
        // A subscription row exists iff the client is subscribed. Applying a page for
        // any other channel would insert one through `set_cursor`, so a page for an
        // unsubscribed channel - a pull still in flight when the unsubscribe
        // committed - is dropped without writing anything.
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
                e.set_cursor(&channel, change.cursor)
            })?;
        }
        if self.cursor(&page.channel)? < page.to_cursor {
            let channel = page.channel.clone();
            self.write(|e| e.set_cursor(&channel, page.to_cursor))?;
        }
        Ok(report)
    }
}
