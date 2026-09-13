use crate::{MAX_SAFE_INTEGER, Result, canonical_json, invalid};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

pub fn counter(value: u64) -> Result<u64> {
    if value <= MAX_SAFE_INTEGER {
        Ok(value)
    } else {
        Err(invalid("counter outside safe integer range"))
    }
}
pub fn read_counter(value: &Value, positive: bool) -> Result<u64> {
    let f = value
        .as_f64()
        .ok_or_else(|| invalid("counter must be a number"))?;
    if !f.is_finite()
        || f < 0.0
        || f.fract() != 0.0
        || f > MAX_SAFE_INTEGER as f64
        || (positive && f == 0.0)
    {
        return Err(invalid("invalid counter"));
    }
    Ok(f as u64)
}
#[derive(Clone, Debug)]
pub struct RawMutation {
    pub ordinal: u64,
    pub raw: Value,
}
#[derive(Clone, Debug)]
pub struct PushRequest {
    pub client_id: String,
    pub batch_sequence: u64,
    pub mutations: Vec<RawMutation>,
    pub raw: Value,
}
impl PushRequest {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let raw: Value = serde_json::from_slice(bytes)?;
        let client_id = nonblank(&raw["clientId"])?;
        let batch_sequence = read_counter(&raw["batchSequence"], true)?;
        let acts = raw["mutations"]
            .as_array()
            .ok_or_else(|| invalid("mutations must be array"))?;
        if acts.is_empty() || acts.len() > 20 {
            return Err(invalid("batch must contain 1..20 mutations"));
        }
        let mut seen = BTreeSet::new();
        let mut mutations = vec![];
        for act in acts {
            if !act.is_object() {
                return Err(invalid("mutation must be object"));
            }
            let ordinal = read_counter(&act["ordinal"], true)?;
            if !seen.insert(ordinal) {
                return Err(invalid("duplicate ordinal"));
            }
            mutations.push(RawMutation {
                ordinal,
                raw: act.clone(),
            });
        }
        Ok(Self {
            client_id,
            batch_sequence,
            mutations,
            raw,
        })
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        Ok(canonical_json(&self.raw)?.into_bytes())
    }
    pub fn semantic_hash(&self) -> Result<String> {
        Ok(format!("{:x}", Sha256::digest(self.encode()?)))
    }
}
fn nonblank(value: &Value) -> Result<String> {
    value
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .map(str::to_string)
        .ok_or_else(|| invalid("expected nonblank string"))
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelCheckpoint {
    #[serde(rename = "scope")]
    pub channel: String,
    #[serde(rename = "syncId")]
    pub cursor: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rejection {
    pub ordinal: u64,
    pub code: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushReceipt {
    #[serde(rename = "requiredCheckpoints", default)]
    pub required_checkpoints: Vec<ChannelCheckpoint>,
    #[serde(rename = "requiredScope")]
    pub required_channel: String,
    #[serde(rename = "requiredSyncId")]
    pub required_cursor: u64,
    pub rejections: Vec<Rejection>,
}
impl PushReceipt {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let value: Value = serde_json::from_slice(bytes)?;
        let missing = value.get("requiredCheckpoints").is_none();
        let mut result: Self = serde_json::from_value(value)?;
        if missing {
            result.required_checkpoints.push(ChannelCheckpoint {
                channel: result.required_channel.clone(),
                cursor: result.required_cursor,
            });
        }
        result.validate()?;
        Ok(result)
    }
    fn validate(&self) -> Result<()> {
        counter(self.required_cursor)?;
        if self.required_checkpoints.is_empty() && self.rejections.is_empty() {
            return Err(invalid("empty checkpoint set"));
        }
        let mut channels = BTreeSet::new();
        for cp in &self.required_checkpoints {
            counter(cp.cursor)?;
            if !channels.insert(&cp.channel) {
                return Err(invalid("duplicate checkpoint channel"));
            }
        }
        let mut seen = BTreeSet::new();
        for r in &self.rejections {
            counter(r.ordinal)?;
            if r.ordinal == 0 || r.code.trim().is_empty() || !seen.insert(r.ordinal) {
                return Err(invalid("invalid rejection"));
            }
        }
        Ok(())
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        Ok(canonical_json(&serde_json::to_value(self)?)?.into_bytes())
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PullRequest {
    #[serde(rename = "clientId")]
    pub client_id: String,
    #[serde(rename = "scope")]
    pub channel: String,
    #[serde(rename = "fromCursor")]
    pub from_cursor: u64,
}
impl PullRequest {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let v: Value = serde_json::from_slice(bytes)?;
        Ok(Self {
            client_id: nonblank(&v["clientId"])?,
            channel: v["scope"]
                .as_str()
                .ok_or_else(|| invalid("scope must be string"))?
                .into(),
            from_cursor: read_counter(&v["fromCursor"], false)?,
        })
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        counter(self.from_cursor)?;
        Ok(canonical_json(&serde_json::to_value(self)?)?.into_bytes())
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecordChange {
    #[serde(rename = "syncId")]
    pub cursor: u64,
    pub model: String,
    pub identity: Value,
    pub stamp: u64,
    pub state: Value,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PullPage {
    #[serde(rename = "scope")]
    pub channel: String,
    #[serde(rename = "fromCursor")]
    pub from_cursor: u64,
    #[serde(rename = "toCursor")]
    pub to_cursor: u64,
    pub changes: Vec<RecordChange>,
}
impl PullPage {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let value: Value = serde_json::from_slice(bytes)?;
        if let Some(changes) = value["changes"].as_array() {
            for change in changes {
                if change.get("state").is_none() {
                    return Err(invalid("change state missing"));
                }
                if change.get("stamp").is_none() {
                    return Err(invalid("change stamp missing"));
                }
            }
        }
        let p: Self = serde_json::from_value(value)?;
        p.validate()?;
        Ok(p)
    }
    pub fn validate(&self) -> Result<()> {
        counter(self.from_cursor)?;
        counter(self.to_cursor)?;
        if self.to_cursor < self.from_cursor {
            return Err(invalid("page moves backwards"));
        }
        let mut previous = self.from_cursor;
        for change in &self.changes {
            counter(change.cursor)?;
            if change.stamp == 0 || counter(change.stamp).is_err() {
                return Err(invalid("change stamp must be a positive counter"));
            }
            if change.model.is_empty()
                || change.cursor <= previous
                || change.cursor > self.to_cursor
                || !change.identity.is_object()
                || (!change.state.is_null() && !change.state.is_object())
            {
                return Err(invalid("invalid change"));
            }
            previous = change.cursor;
        }
        Ok(())
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        Ok(canonical_json(&serde_json::to_value(self)?)?.into_bytes())
    }
}
