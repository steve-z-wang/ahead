//! Server protocol orchestration. Host calls run in the application's outer transaction.
pub mod live;
use otter_core::{
    ChannelCheckpoint, PullPage, PullRequest, PushReceipt, PushRequest, RecordChange, Rejection,
    Schema, read_counter,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    future::Future,
    pin::Pin,
};
pub type Result<T> = std::result::Result<T, String>;
pub trait Host: Send + Sync {
    fn call(&self, request: Value) -> Pin<Box<dyn Future<Output = Result<Value>> + Send + '_>>;
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Config {
    pub schema: Schema,
    pub mutations: Vec<Mutation>,
    pub loaders: Vec<String>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Mutation {
    pub name: String,
    pub version: u64,
    pub slots: Vec<Slot>,
    #[serde(default)]
    pub input: Option<Schema>,
    #[serde(default, rename = "knownFields")]
    pub known_fields: BTreeMap<String, Vec<String>>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Slot {
    pub name: String,
    pub model: String,
    pub operation: String,
    pub cardinality: String,
    #[serde(default)]
    pub allowed_patch_fields: Vec<String>,
    #[serde(default)]
    pub bindings: Vec<Binding>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Binding {
    pub fields: Vec<String>,
    pub slot: String,
}
impl Config {
    pub fn decode(value: Value) -> Result<Self> {
        let c: Self = serde_json::from_value(value).map_err(err)?;
        c.schema.validate().map_err(err)?;
        let mut versions = BTreeSet::new();
        for m in &c.mutations {
            if m.name.is_empty()
                || read_counter(&json!(m.version), true).is_err()
                || !versions.insert((&m.name, m.version))
            {
                return Err("invalid mutation descriptor".into());
            }
            let mut slots = BTreeSet::new();
            let schema = m.input.as_ref().unwrap_or(&c.schema);
            schema.validate().map_err(err)?;
            for s in &m.slots {
                let model = schema.model(&s.model).map_err(err)?;
                let mut capabilities = BTreeSet::new();
                if s.operation != "update" && !s.allowed_patch_fields.is_empty() {
                    return Err("patch capabilities require update operation".into());
                }
                for field in &s.allowed_patch_fields {
                    if !capabilities.insert(field)
                        || model.identity.contains(field)
                        || !model.fields.iter().any(|f| f.name == *field)
                    {
                        return Err("invalid patch capability".into());
                    }
                }

                if !slots.insert(&s.name)
                    || !["single", "optional", "list"].contains(&s.cardinality.as_str())
                    || !["create", "update", "delete"].contains(&s.operation.as_str())
                {
                    return Err("invalid slot descriptor".into());
                }
            }
        }
        for m in &c.mutations {
            let schema = m.input.as_ref().unwrap_or(&c.schema);
            for slot in &m.slots {
                for binding in &slot.bindings {
                    let parent = m
                        .slots
                        .iter()
                        .find(|s| s.name == binding.slot)
                        .ok_or("binding target missing")?;
                    let parent_model = schema.model(&parent.model).map_err(err)?;
                    let child = schema.model(&slot.model).map_err(err)?;
                    if parent.cardinality != "single"
                        || binding.fields.len() != parent_model.identity.len()
                        || binding
                            .fields
                            .iter()
                            .any(|n| !child.fields.iter().any(|f| f.name == *n))
                    {
                        return Err("invalid binding descriptor".into());
                    }
                }
            }
        }
        for loader in &c.loaders {
            c.schema.model(loader).map_err(err)?;
        }
        Ok(c)
    }
    fn descriptor(&self, body: &Value) -> Result<&Mutation> {
        let name = body["name"].as_str().ok_or("mutation.invalid")?;
        let version = version(body).ok_or("mutation.invalid")?;
        self.mutations
            .iter()
            .find(|m| m.name == name && m.version == version)
            .ok_or("mutation.invalid".into())
    }
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn version(body: &Value) -> Option<u64> {
    read_counter(body.get("version").unwrap_or(&json!(1)), true).ok()
}
fn invalid<T>(r: otter_core::Result<T>) -> Result<T> {
    r.map_err(|_| "mutation.invalid".into())
}
pub fn decode_arguments(config: &Value, body: &Value) -> Result<Value> {
    decode(&Config::decode(config.clone())?, body)
}
fn decode(c: &Config, body: &Value) -> Result<Value> {
    let d = c.descriptor(body)?;
    let schema = d.input.as_ref().unwrap_or(&c.schema);
    let ops = body["operations"].as_array().ok_or("mutation.invalid")?;
    let mut at = 0;
    let mut args = Map::new();
    for slot in &d.slots {
        let mut values = vec![];
        while at < ops.len() && ops[at]["model"] == slot.model && ops[at]["op"] == slot.operation {
            let op = &ops[at];
            let model = invalid(schema.model(&slot.model))?;
            let source = op["identity"].as_object().ok_or("mutation.invalid")?;
            let identity = Value::Object(
                source
                    .iter()
                    .filter(|(k, _)| model.identity.contains(k))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect(),
            );
            let key = invalid(schema.record_key(&slot.model, &identity))?;
            let mut argument = json!({"identity":key.identity});
            if slot.operation != "delete" {
                let source = op["values"].as_object().ok_or("mutation.invalid")?;
                let mut data = Map::new();
                if slot.operation == "create" {
                    for field in model
                        .fields
                        .iter()
                        .filter(|f| !model.identity.contains(&f.name))
                    {
                        let v = source
                            .get(&field.name)
                            .or({
                                if field.nullable {
                                    Some(&Value::Null)
                                } else {
                                    None
                                }
                            })
                            .ok_or("mutation.invalid")?;
                        data.insert(
                            field.name.clone(),
                            invalid(schema.normalize_value(field, v))?,
                        );
                    }
                    argument["data"] = Value::Object(data);
                } else {
                    for (name, v) in source {
                        let known = d
                            .known_fields
                            .get(&slot.model)
                            .map(|names| names.contains(name))
                            .unwrap_or_else(|| model.fields.iter().any(|f| f.name == *name));
                        if known && !slot.allowed_patch_fields.contains(name) {
                            return Err(format!("{}.not_allowed", machine_name(&d.name)));
                        }
                        if let Some(field) = model.fields.iter().find(|f| f.name == *name) {
                            if !slot.allowed_patch_fields.contains(name) {
                                return Err(format!("{}.not_allowed", machine_name(&d.name)));
                            }
                            data.insert(name.clone(), invalid(schema.normalize_value(field, v))?);
                        }
                    }
                    if data.is_empty() {
                        return Err("mutation.invalid".into());
                    }
                    argument["patch"] = Value::Object(data);
                }
            }
            values.push(argument);
            at += 1;
            if slot.cardinality != "list" {
                break;
            }
        }
        let value = if slot.cardinality == "list" {
            Value::Array(values)
        } else if values.len() == 1 {
            values.remove(0)
        } else if slot.cardinality == "optional" {
            Value::Null
        } else {
            return Err("mutation.invalid".into());
        };
        args.insert(slot.name.clone(), value);
    }
    if at != ops.len() {
        return Err("mutation.invalid".into());
    }
    for slot in d.slots.iter().filter(|s| s.operation == "create") {
        for binding in &slot.bindings {
            let parent = d
                .slots
                .iter()
                .find(|s| s.name == binding.slot)
                .ok_or("binding target missing")?;
            let parent_model = schema.model(&parent.model).map_err(err)?;
            let rows = if slot.cardinality == "list" {
                args[&slot.name]
                    .as_array()
                    .ok_or("invalid binding rows")?
                    .clone()
            } else if args[&slot.name].is_null() {
                vec![]
            } else {
                vec![args[&slot.name].clone()]
            };
            for row in rows {
                for (field, id) in binding.fields.iter().zip(&parent_model.identity) {
                    let actual = row["identity"].get(field).unwrap_or(&row["data"][field]);
                    if actual != &args[&parent.name]["identity"][id] {
                        return Err(format!("{}.invalid", machine_name(&d.name)));
                    }
                }
            }
        }
    }
    Ok(Value::Object(args))
}
fn machine_name(name: &str) -> String {
    let mut s = String::new();
    for ch in name.chars() {
        if ch.is_ascii_uppercase() {
            if !s.is_empty() {
                s.push('_')
            }
            s.push(ch.to_ascii_lowercase())
        } else {
            s.push(ch)
        }
    }
    s
}
fn valid_code(s: &str) -> bool {
    let mut parts = s.split(['.', '_', '-']);
    let first = parts.next().unwrap_or("");
    first.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && first
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        && parts.all(|p| {
            !p.is_empty()
                && p.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}
fn principal(owner: &str) -> Result<()> {
    if owner.trim().is_empty() {
        Err("invalid principal".into())
    } else {
        Ok(())
    }
}
async fn head(host: &impl Host, channel: &str) -> Result<u64> {
    let v = host.call(json!({"op":"head","channel":channel})).await?;
    read_counter(&v, false).map_err(err)
}
pub async fn process_push(
    config: &Config,
    owner: &str,
    channel: &str,
    bytes: &[u8],
    host: &impl Host,
) -> Result<String> {
    principal(owner)?;
    let request = PushRequest::decode(bytes).map_err(|e| format!("request.invalid:{e}"))?;
    let hash = request.semantic_hash().map_err(err)?;
    let locked = host
        .call(json!({"op":"claim","owner":owner,"clientId":request.client_id}))
        .await?;
    if locked["clientId"] != request.client_id {
        return Err("storage client mismatch".into());
    }
    if locked["owner"] != owner {
        return Err("owner_mismatch".into());
    }
    let last = read_counter(&locked["sequence"], false).map_err(err)?;
    if request.batch_sequence == last {
        if locked["hash"] != hash {
            return Err("request_conflict".into());
        }
        return locked["receipt"]
            .as_str()
            .map(str::to_owned)
            .ok_or("request_conflict".into());
    }
    if request.batch_sequence < last {
        return Err("overlap".into());
    }
    if request.batch_sequence != last + 1 {
        return Err("gap".into());
    }
    for m in &request.mutations {
        if let (Some(name), Some(v)) = (m.raw["name"].as_str(), version(&m.raw))
            && config.mutations.iter().any(|d| d.name == name)
            && !config
                .mutations
                .iter()
                .any(|d| d.name == name && d.version == v)
        {
            return Err(format!(
                "mutation_version_unsupported:{}:{name}:{v}",
                m.ordinal
            ));
        }
    }
    let mut rejections = vec![];
    let mut channels = BTreeSet::new();
    for m in &request.mutations {
        let args = match decode(config, &m.raw) {
            Ok(a) => a,
            Err(code) => {
                rejections.push(Rejection {
                    ordinal: m.ordinal,
                    code,
                });
                continue;
            }
        };
        host.call(json!({"op":"savepoint","ordinal":m.ordinal}))
            .await?;
        // Host returns only explicit refusal as data; every thrown error aborts the outer transaction.
        let result=host.call(json!({"op":"handle","name":m.raw["name"],"version":version(&m.raw),"arguments":args,"owner":owner,"ordinal":m.ordinal})).await?;
        if let Some(code) = result.get("rejection") {
            let code = code
                .as_str()
                .filter(|s| valid_code(s))
                .ok_or("invalid rejection code")?;
            host.call(json!({"op":"rollback","ordinal":m.ordinal}))
                .await?;
            rejections.push(Rejection {
                ordinal: m.ordinal,
                code: code.into(),
            });
        } else {
            let selected = if result.is_null() {
                channel
            } else {
                result["channel"]
                    .as_str()
                    .ok_or("invalid handler settlement")?
            };
            channels.insert(selected.to_string());
        }
        host.call(json!({"op":"release","ordinal":m.ordinal}))
            .await?;
    }
    if channels.is_empty() {
        channels.insert(channel.into());
    }
    let mut checkpoints = vec![];
    for ch in channels {
        checkpoints.push(ChannelCheckpoint {
            cursor: head(host, &ch).await?,
            channel: ch,
        });
    }
    checkpoints.sort_by(|a, b| a.channel.encode_utf16().cmp(b.channel.encode_utf16()));
    let legacy = match checkpoints.iter().find(|cp| cp.channel == channel) {
        Some(cp) => cp.cursor,
        None => head(host, channel).await?,
    };
    let receipt = PushReceipt {
        required_checkpoints: checkpoints,
        required_channel: channel.into(),
        required_cursor: legacy,
        rejections,
    };
    let text = String::from_utf8(receipt.encode().map_err(err)?).map_err(err)?;
    host.call(json!({"op":"saveReceipt","owner":owner,"clientId":request.client_id,"sequence":request.batch_sequence,"hash":hash,"receipt":text})).await?;
    Ok(text)
}
pub async fn process_pull(
    config: &Config,
    owner: &str,
    bytes: &[u8],
    host: &impl Host,
) -> Result<String> {
    principal(owner)?;
    let request = PullRequest::decode(bytes).map_err(|e| format!("request.invalid:{e}"))?;
    if host
        .call(json!({"op":"authorize","owner":owner,"channel":request.channel}))
        .await?
        != true
    {
        return Err("channel_forbidden".into());
    }
    let maximum = head(host, &request.channel).await?;
    if request.from_cursor > maximum {
        return Err("request.invalid:cursor ahead of head".into());
    }
    let raw = host
        .call(json!({"op":"scan","channel":request.channel,"after":request.from_cursor,"limit":50}))
        .await?;
    let rows = raw.as_array().ok_or("invalid scan")?;
    if rows.len() > 50 {
        return Err("invalid scan size".into());
    }
    let mut previous = request.from_cursor;
    let mut changes = vec![];
    let mut groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for row in rows {
        let cursor = read_counter(&row["cursor"], true).map_err(err)?;
        if row["channel"] != request.channel || cursor <= previous || cursor > maximum {
            return Err("invalid invalidation order".into());
        }
        previous = cursor;
        let model = row["model"].as_str().ok_or("invalid model")?;
        if !config.loaders.iter().any(|m| m == model) {
            return Err("unregistered loader".into());
        }
        let key = config
            .schema
            .record_key(model, &row["identity"])
            .map_err(err)?;
        if row["identityKey"] != key.encoded_identity().map_err(err)? {
            return Err("noncanonical identity".into());
        }
        groups.entry(model.into()).or_default().push(changes.len());
        changes.push(RecordChange {
            cursor,
            model: model.into(),
            identity: key.identity,
            state: Value::Null,
        });
    }
    for (model, indexes) in groups {
        let identities: Vec<_> = indexes
            .iter()
            .map(|i| changes[*i].identity.clone())
            .collect();
        let loaded=host.call(json!({"op":"load","model":model,"identities":identities,"owner":owner,"channel":request.channel})).await?;
        let values = loaded
            .as_array()
            .filter(|a| a.len() == indexes.len())
            .ok_or("misaligned loader result")?;
        for (i, state) in indexes.iter().zip(values) {
            changes[*i].state = if state.is_null() {
                Value::Null
            } else {
                config.schema.normalize_state(&model, state).map_err(err)?
            };
        }
    }
    let page = PullPage {
        channel: request.channel,
        from_cursor: request.from_cursor,
        to_cursor: if rows.len() == 50 { previous } else { maximum },
        changes,
    };
    String::from_utf8(page.encode().map_err(err)?).map_err(err)
}
pub async fn publish(
    config: &Config,
    changes: &Value,
    channels: &Value,
    host: &impl Host,
) -> Result<Value> {
    let changes = changes.as_array().ok_or("changes must be array")?;
    let channels = channels.as_array().ok_or("channels must be array")?;
    let mut selected = BTreeSet::new();
    for channel in channels {
        selected.insert(channel.as_str().ok_or("channel must be string")?);
    }
    let mut keys = BTreeMap::new();
    for change in changes {
        let model = change["model"].as_str().ok_or("model required")?;
        if !config.loaders.iter().any(|m| m == model) {
            return Err("unregistered loader".into());
        }
        let key = config
            .schema
            .record_key(model, &change["identity"])
            .map_err(err)?;
        keys.insert(key.encoded().map_err(err)?, key);
    }
    let mut result = vec![];
    for channel in selected {
        for key in keys.values() {
            let cursor=host.call(json!({"op":"publish","channel":channel,"model":key.model,"identity":key.identity,"identityKey":key.encoded_identity().map_err(err)?})).await?;
            read_counter(&cursor, true).map_err(err)?;
        }
        result.push(json!({"scope":channel,"syncId":head(host,channel).await?}));
    }
    Ok(Value::Array(result))
}
