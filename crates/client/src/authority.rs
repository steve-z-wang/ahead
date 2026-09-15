//! One applier for authoritative records, whichever path delivered them: a
//! push receipt or a channel page. Content is ordered by record stamp alone;
//! channels and cursors never enter here
//! ([Settlement](../../../docs/engineering/architecture/client/engine/settlement.md)).
use crate::engine::Engine;
use crate::rows::merge_identity;
use crate::store::ClientStore;
use ahead_core::{AuthorityRecord, RecordKey, Result};
use serde_json::Value;
use std::collections::BTreeMap;

/// How one authoritative record compared with what the client already held.
#[derive(Debug, PartialEq)]
pub enum Disposition {
    /// A newer stamp: the content was staged and the stamp stored.
    Applied,
    /// An older stamp: nothing changed.
    Older,
    /// The same stamp with the same content: nothing to rewrite.
    Same,
    /// The same stamp with different content: reported, never applied.
    Conflict {
        local: Option<Value>,
        incoming: Option<Value>,
    },
}

/// Keys whose staged base must be replayed once the caller has finished its
/// own queue changes. A key is held while it has pending operations; its
/// authority lands in the before image and the visible row is rebuilt from
/// there, so a base staged before a completed operation is removed still
/// carries the right content afterwards.
pub type Held = BTreeMap<String, RecordKey>;

impl<S: ClientStore> Engine<'_, S> {
    /// Stage one authoritative record by stamp. A newer stamp stores its
    /// content beneath the pending operations (collected in `held`) or in the
    /// visible row of a clean record, and stores the stamp, deletions included:
    /// the stamp is what keeps older content from resurrecting the record. A
    /// deletion also stages the deletion of every declared cascade descendant,
    /// without touching the descendants' own stamp evidence.
    pub fn stage_authority(
        &mut self,
        record: &AuthorityRecord,
        held: &mut Held,
    ) -> Result<Disposition> {
        let key = self.schema.record_key(&record.model, &record.identity)?;
        let incoming = if record.state.is_null() {
            None
        } else {
            Some(merge_identity(
                &key.identity,
                &self.schema.validate_state(&record.model, &record.state)?,
            ))
        };
        let local = self.record_stamp(&key)?;
        if record.stamp < local {
            return Ok(Disposition::Older);
        }
        if record.stamp == local {
            // The held base is the last authority this client applied; the
            // visible row may carry optimism on top of it.
            let current = self.truth(&key)?;
            return Ok(if current == incoming {
                Disposition::Same
            } else {
                Disposition::Conflict {
                    local: current,
                    incoming,
                }
            });
        }
        self.stage_one(&key, incoming.as_ref(), held)?;
        if incoming.is_none() {
            for child in self.descendants(&key)? {
                self.stage_one(&child, None, held)?;
            }
        }
        self.set_record_stamp(&key, record.stamp)?;
        Ok(Disposition::Applied)
    }
    fn stage_one(&mut self, key: &RecordKey, value: Option<&Value>, held: &mut Held) -> Result<()> {
        if self.dirty(key)? {
            self.before_set(key, value)?;
            held.insert(key.encoded()?, key.clone());
        } else {
            self.main_set(key, value)?;
        }
        Ok(())
    }
    /// Replay the remaining operations of every held key over its staged base
    /// and extend queued deletes to descendants that appeared. Called once,
    /// after the caller's queue changes, so each key is rebuilt from the final
    /// queue state.
    pub fn rebuild_held(&mut self, held: &Held) -> Result<()> {
        for key in held.values() {
            self.rebuild(key)?;
        }
        self.refresh_pending()
    }
    /// Apply one authoritative record whose queue state will not change:
    /// stage it and rebuild at once.
    pub fn apply_authority(&mut self, record: &AuthorityRecord) -> Result<Disposition> {
        let mut held = Held::new();
        let disposition = self.stage_authority(record, &mut held)?;
        if disposition == Disposition::Applied {
            self.rebuild_held(&held)?;
        }
        Ok(disposition)
    }
}
