//! Per-record stamp, channel claims and subscriptions.
use crate::engine::{Engine, as_u64};
use crate::store::ClientStore;
use savoia_core::{RecordKey, Result};
use serde_json::{Value, json};

impl<S: ClientStore> Engine<'_, S> {
    pub fn record_stamp(&mut self, key: &RecordKey) -> Result<u64> {
        match self.scalar(
            "SELECT stamp FROM ahead_record WHERE model=? AND identity=?",
            &[json!(key.model), json!(key.encoded_identity()?)],
        )? {
            Some(v) => as_u64(&v),
            None => Ok(0),
        }
    }
    pub fn set_record_stamp(&mut self, key: &RecordKey, stamp: u64) -> Result<()> {
        self.exec("ahead_record", "INSERT INTO ahead_record (model, identity, stamp) VALUES (?,?,?) ON CONFLICT(model, identity) DO UPDATE SET stamp=excluded.stamp", &[json!(key.model), json!(key.encoded_identity()?), json!(stamp)])?;
        Ok(())
    }
    pub fn drop_record(&mut self, key: &RecordKey) -> Result<()> {
        self.exec(
            "ahead_record",
            "DELETE FROM ahead_record WHERE model=? AND identity=?",
            &[json!(key.model), json!(key.encoded_identity()?)],
        )?;
        Ok(())
    }
    pub fn claim_add(&mut self, channel: &str, key: &RecordKey) -> Result<()> {
        self.exec(
            "ahead_claim",
            "INSERT OR IGNORE INTO ahead_claim (channel, model, identity) VALUES (?,?,?)",
            &[
                json!(channel),
                json!(key.model),
                json!(key.encoded_identity()?),
            ],
        )?;
        Ok(())
    }
    pub fn claim_remove(&mut self, channel: &str, key: &RecordKey) -> Result<()> {
        self.exec(
            "ahead_claim",
            "DELETE FROM ahead_claim WHERE channel=? AND model=? AND identity=?",
            &[
                json!(channel),
                json!(key.model),
                json!(key.encoded_identity()?),
            ],
        )?;
        Ok(())
    }
    pub fn claims(&mut self, key: &RecordKey) -> Result<Vec<String>> {
        let rows = self.rows(
            "SELECT channel FROM ahead_claim WHERE model=? AND identity=? ORDER BY channel",
            &[json!(key.model), json!(key.encoded_identity()?)],
        )?;
        Ok(rows
            .rows
            .into_iter()
            .filter_map(|r| r[0].as_str().map(str::to_owned))
            .collect())
    }
    pub fn claims_remove_all(&mut self, key: &RecordKey) -> Result<()> {
        self.exec(
            "ahead_claim",
            "DELETE FROM ahead_claim WHERE model=? AND identity=?",
            &[json!(key.model), json!(key.encoded_identity()?)],
        )?;
        Ok(())
    }
    pub fn claimed_by(&mut self, channel: &str) -> Result<Vec<RecordKey>> {
        let rows = self.rows(
            "SELECT model, identity FROM ahead_claim WHERE channel=? ORDER BY model, identity",
            &[json!(channel)],
        )?;
        rows.rows
            .into_iter()
            .map(|r| {
                let identity: Value = serde_json::from_str(r[1].as_str().unwrap_or("null"))?;
                self.schema
                    .record_key(r[0].as_str().unwrap_or(""), &identity)
            })
            .collect()
    }
    pub fn cursor(&mut self, channel: &str) -> Result<Option<u64>> {
        self.scalar(
            "SELECT cursor FROM ahead_subscription WHERE channel=?",
            &[json!(channel)],
        )?
        .map(|v| as_u64(&v))
        .transpose()
    }
    pub fn set_cursor(&mut self, channel: &str, cursor: u64) -> Result<()> {
        self.exec("ahead_subscription", "INSERT INTO ahead_subscription (channel, cursor) VALUES (?,?) ON CONFLICT(channel) DO UPDATE SET cursor=excluded.cursor", &[json!(channel), json!(cursor)])?;
        Ok(())
    }
    pub fn delete_subscription(&mut self, channel: &str) -> Result<()> {
        self.exec(
            "ahead_subscription",
            "DELETE FROM ahead_subscription WHERE channel=?",
            &[json!(channel)],
        )?;
        Ok(())
    }
    pub fn subscriptions(&mut self) -> Result<Vec<(String, u64)>> {
        let rows = self.rows(
            "SELECT channel, cursor FROM ahead_subscription ORDER BY channel",
            &[],
        )?;
        rows.rows
            .into_iter()
            .map(|r| Ok((r[0].as_str().unwrap_or("").to_string(), as_u64(&r[1])?)))
            .collect()
    }
}
