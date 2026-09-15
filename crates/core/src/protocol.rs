use crate::{MAX_SAFE_INTEGER, Result, canonical_json, invalid};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// Limits both sides enforce without negotiating them on the wire. Every
/// consumer reads them from here; making them configurable is
/// [#11](https://github.com/zanminwang/ahead/issues/11). Host resource
/// limits (HTTP body and WebSocket frame sizes, page buffers) are not
/// protocol rules and stay with each transport.
pub mod limits {
    /// A push batch carries between one and this many mutations.
    pub const PUSH_MUTATIONS: usize = 20;
    /// The client freezes a batch only while its canonical bytes stay under this.
    pub const PUSH_BYTES: usize = 256 * 1024;
    /// A pull page carries at most this many changes. A page holding exactly
    /// this many continues: the channel may hold more beyond `toCursor`.
    pub const PULL_CHANGES: usize = 50;
}

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
        if acts.is_empty() || acts.len() > limits::PUSH_MUTATIONS {
            return Err(invalid(format!(
                "batch must contain 1..{} mutations",
                limits::PUSH_MUTATIONS
            )));
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
    /// The read contracts this client expects: every model of its schema
    /// with the version it reads ([#91](https://github.com/zanminwang/ahead/issues/91)).
    /// Required; the server serves each model at the declared version and
    /// never guesses one.
    pub models: BTreeMap<String, u64>,
}
/// `{"Task":2,"Note":1}`: one positive version per model, nothing else.
pub fn read_models(value: &Value) -> Result<BTreeMap<String, u64>> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid("models must declare a version per model"))?;
    if object.is_empty() {
        return Err(invalid("models must declare at least one model"));
    }
    object
        .iter()
        .map(|(name, version)| {
            if name.is_empty() {
                return Err(invalid("model name must not be empty"));
            }
            Ok((name.clone(), read_counter(version, true)?))
        })
        .collect()
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
            models: read_models(&v["models"])?,
        })
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        counter(self.from_cursor)?;
        read_models(&serde_json::to_value(&self.models)?)?;
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
    /// Whether the channel may hold changes beyond `toCursor`: a full page
    /// ends at its last change, a shorter one reaches the channel head
    /// ([Protocol / Pull](../../../docs/engineering/architecture/protocol/pull.md)).
    pub fn continues(&self) -> bool {
        self.changes.len() == limits::PULL_CHANGES
    }
    pub fn validate(&self) -> Result<()> {
        counter(self.from_cursor)?;
        counter(self.to_cursor)?;
        if self.to_cursor < self.from_cursor {
            return Err(invalid("page moves backwards"));
        }
        if self.changes.len() > limits::PULL_CHANGES {
            return Err(invalid(format!(
                "page exceeds {} changes",
                limits::PULL_CHANGES
            )));
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

/// The one client frame of a live session:
/// `{"type":"subscribe","scopes":[…],"models":{…}}`. Scopes are normalized on
/// decode and on construction: deduplicated and sorted by UTF-16 code units,
/// the order the acknowledgement echoes. `models` declares the read contracts
/// every page of the session is served at, as in [`PullRequest::models`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubscribeRequest {
    pub scopes: Vec<String>,
    pub models: BTreeMap<String, u64>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SubscribeWire {
    #[serde(rename = "type")]
    kind: String,
    scopes: Vec<String>,
    #[serde(default)]
    models: Value,
}
fn normalize_scopes(scopes: Vec<String>) -> Result<Vec<String>> {
    if scopes.is_empty() {
        return Err(invalid("subscribe requires at least one scope"));
    }
    if scopes.iter().any(String::is_empty) {
        return Err(invalid("scope must not be empty"));
    }
    let mut scopes: Vec<_> = scopes
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    scopes.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
    Ok(scopes)
}
impl SubscribeRequest {
    pub fn new(scopes: Vec<String>, models: BTreeMap<String, u64>) -> Result<Self> {
        Ok(Self {
            scopes: normalize_scopes(scopes)?,
            models: read_models(&serde_json::to_value(&models)?)?,
        })
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let wire: SubscribeWire = serde_json::from_slice(bytes)?;
        if wire.kind != "subscribe" {
            return Err(invalid("expected one subscribe frame with scopes"));
        }
        Self::new(wire.scopes, read_models(&wire.models)?)
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        Ok(canonical_json(
            &serde_json::json!({"type":"subscribe","scopes":self.scopes,"models":self.models}),
        )?
        .into_bytes())
    }
}

/// The server's answer to a subscribe frame. `rejections` is vestigial and
/// must be an empty array ([#63](https://github.com/zanminwang/ahead/issues/63));
/// unknown fields are ignored so a newer server can extend the frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubscriptionAck {
    pub scopes: Vec<String>,
}
#[derive(Deserialize)]
struct AckWire {
    #[serde(rename = "type")]
    kind: String,
    scopes: Vec<String>,
    rejections: Vec<Value>,
}
impl SubscriptionAck {
    pub fn new(scopes: Vec<String>) -> Result<Self> {
        Ok(Self {
            scopes: normalize_scopes(scopes)?,
        })
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let wire: AckWire = serde_json::from_slice(bytes)
            .map_err(|_| invalid("invalid live subscription acknowledgement"))?;
        if wire.kind != "subscribed" || !wire.rejections.is_empty() {
            return Err(invalid("invalid live subscription acknowledgement"));
        }
        Self::new(wire.scopes)
    }
    /// Whether the server acknowledged exactly the requested channel set.
    pub fn confirms(&self, request: &SubscribeRequest) -> bool {
        self.scopes == request.scopes
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        Ok(canonical_json(
            &serde_json::json!({"type":"subscribed","scopes":self.scopes,"rejections":[]}),
        )?
        .into_bytes())
    }
}

/// A frame the server sends on a live socket: the acknowledgement carries a
/// `type`, a page never does ([Protocol / Subscriptions](../../../docs/engineering/architecture/protocol/subscriptions.md)).
#[derive(Clone, Debug, PartialEq)]
pub enum LiveMessage {
    Acknowledged(SubscriptionAck),
    Page(PullPage),
}
impl LiveMessage {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let value: Value = serde_json::from_slice(bytes)?;
        if !value.is_object() {
            return Err(invalid("invalid live frame"));
        }
        if value.get("type").is_some() {
            return Ok(Self::Acknowledged(SubscriptionAck::decode(bytes)?));
        }
        PullPage::decode(bytes)
            .map(Self::Page)
            .map_err(|e| invalid(format!("invalid live page: {e}")))
    }
}
