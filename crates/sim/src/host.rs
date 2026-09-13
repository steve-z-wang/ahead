//! The server's persistence, in memory. Mirrors packages/persistence-prisma/index.mts
//! closely enough that otter_server cannot tell the difference: per-client receipts,
//! per-channel heads, one invalidation row per (channel, record) carrying the latest
//! cursor and stamp, and one stamp counter per record.
use otter_core::RecordKey;
use otter_server::Host;
use serde_json::{Map, Value, json};
use std::{
    collections::BTreeMap,
    future::Future,
    pin::Pin,
    sync::Mutex,
    task::{Context, Poll, Waker},
};

#[derive(Clone)]
struct Invalidation {
    model: String,
    identity: Value,
    identity_key: String,
    cursor: u64,
    stamp: u64,
}

#[derive(Clone, Default)]
struct Tables {
    records: BTreeMap<String, Value>,
    stamps: BTreeMap<String, u64>,
    heads: BTreeMap<String, u64>,
    invalidations: BTreeMap<(String, String), Invalidation>,
}

#[derive(Default)]
struct State {
    tables: Tables,
    membership: BTreeMap<String, Vec<String>>,
    clients: BTreeMap<String, Value>,
    savepoints: Vec<Tables>,
    reject_next: Option<String>,
    fail_next: bool,
    handler_calls: usize,
    accepted: usize,
    rejected: usize,
    failed: usize,
}

pub struct MemHost(Mutex<State>);

pub fn block_on<T>(future: impl Future<Output = T>) -> T {
    let mut f = std::pin::pin!(future);
    let mut cx = Context::from_waker(Waker::noop());
    loop {
        if let Poll::Ready(result) = f.as_mut().poll(&mut cx) {
            return result;
        }
    }
}

fn encoded(key: &RecordKey) -> String {
    key.encoded().unwrap()
}

impl Default for MemHost {
    fn default() -> Self {
        Self::new()
    }
}

impl MemHost {
    pub fn new() -> Self {
        Self(Mutex::new(State::default()))
    }
    pub fn set_membership(&self, key: &RecordKey, channels: &[&str]) {
        self.0.lock().unwrap().membership.insert(
            encoded(key),
            channels.iter().map(|c| c.to_string()).collect(),
        );
    }
    pub fn membership(&self, key: &RecordKey) -> Vec<String> {
        self.0
            .lock()
            .unwrap()
            .membership
            .get(&encoded(key))
            .cloned()
            .unwrap_or_default()
    }
    /// Whether membership was ever explicitly set for `key`, even to no channels at
    /// all - distinct from `membership` being empty because nothing was set yet.
    pub fn has_membership(&self, key: &RecordKey) -> bool {
        self.0
            .lock()
            .unwrap()
            .membership
            .contains_key(&encoded(key))
    }
    pub fn notify(&self, key: &RecordKey, channels: &[&str]) {
        let mut s = self.0.lock().unwrap();
        for c in channels {
            publish_one(&mut s.tables, c, key);
        }
    }
    pub fn set_state(&self, key: &RecordKey, state: Option<Value>) {
        let mut s = self.0.lock().unwrap();
        match state {
            Some(v) => s.tables.records.insert(encoded(key), v),
            None => s.tables.records.remove(&encoded(key)),
        };
    }
    pub fn reject_next(&self, code: &str) {
        self.0.lock().unwrap().reject_next = Some(code.into());
    }
    pub fn fail_next(&self) {
        self.0.lock().unwrap().fail_next = true;
    }
    pub fn state(&self, key: &RecordKey) -> Option<Value> {
        self.0
            .lock()
            .unwrap()
            .tables
            .records
            .get(&encoded(key))
            .cloned()
    }
    pub fn records(&self) -> BTreeMap<String, Value> {
        self.0.lock().unwrap().tables.records.clone()
    }
    pub fn stamp(&self, key: &RecordKey) -> u64 {
        self.0
            .lock()
            .unwrap()
            .tables
            .stamps
            .get(&encoded(key))
            .copied()
            .unwrap_or(0)
    }
    pub fn head(&self, channel: &str) -> u64 {
        self.0
            .lock()
            .unwrap()
            .tables
            .heads
            .get(channel)
            .copied()
            .unwrap_or(0)
    }
    pub fn handler_calls(&self) -> usize {
        self.0.lock().unwrap().handler_calls
    }
    pub fn accepted(&self) -> usize {
        self.0.lock().unwrap().accepted
    }
    pub fn rejected(&self) -> usize {
        self.0.lock().unwrap().rejected
    }
    pub fn failed(&self) -> usize {
        self.0.lock().unwrap().failed
    }
    pub fn stamped_keys(&self) -> Vec<RecordKey> {
        let s = self.0.lock().unwrap();
        let mut by_encoded: BTreeMap<String, RecordKey> = BTreeMap::new();
        for row in s.tables.invalidations.values() {
            let key = key_of(&row.model, &row.identity);
            by_encoded.insert(key.encoded().unwrap(), key);
        }
        by_encoded.into_values().collect()
    }
    pub fn channel_records(&self, channel: &str) -> Vec<RecordKey> {
        let s = self.0.lock().unwrap();
        s.tables
            .invalidations
            .iter()
            .filter(|((c, _), _)| c == channel)
            .map(|(_, row)| key_of(&row.model, &row.identity))
            .collect()
    }
    pub fn receipt(&self, client_id: &str, sequence: u64) -> Option<String> {
        let s = self.0.lock().unwrap();
        let row = s.clients.get(client_id)?;
        if row["sequence"].as_u64() == Some(sequence) {
            row["receipt"].as_str().map(str::to_string)
        } else {
            None
        }
    }
    pub fn push(&self, owner: &str, bytes: &[u8]) -> Result<String, String> {
        let (before, depth) = {
            let s = self.0.lock().unwrap();
            (s.tables.clone(), s.savepoints.len())
        };
        let result = block_on(otter_server::process_push(
            &crate::schema::config(),
            owner,
            bytes,
            self,
        ));
        if result.is_err() {
            // An aborted batch is a rolled-back transaction: nothing it did survives.
            // A `handle` error short-circuits process_push after `savepoint` but before
            // the matching `release`, so the savepoint stack must also be restored to
            // its pre-call depth here — this is the same invariant a successful push
            // already leaves it at (every `savepoint` is paired with a `release`).
            let mut s = self.0.lock().unwrap();
            s.tables = before;
            s.savepoints.truncate(depth);
        }
        result
    }
    pub fn savepoint_depth(&self) -> usize {
        self.0.lock().unwrap().savepoints.len()
    }
    pub fn pull(&self, owner: &str, bytes: &[u8]) -> Result<String, String> {
        block_on(otter_server::process_pull(
            &crate::schema::config(),
            owner,
            bytes,
            self,
        ))
    }
}

fn publish_one(t: &mut Tables, channel: &str, key: &RecordKey) -> (u64, u64) {
    let k = encoded(key);
    let stamp = t.stamps.entry(k.clone()).or_insert(0);
    *stamp += 1;
    let stamp = *stamp;
    let head = t.heads.entry(channel.to_string()).or_insert(0);
    *head += 1;
    let cursor = *head;
    t.invalidations.insert(
        (channel.to_string(), k),
        Invalidation {
            model: key.model.clone(),
            identity: key.identity.clone(),
            identity_key: key.encoded_identity().unwrap(),
            cursor,
            stamp,
        },
    );
    (cursor, stamp)
}

fn key_of(model: &str, identity: &Value) -> RecordKey {
    crate::schema::schema().record_key(model, identity).unwrap()
}

/// Apply one decoded handler argument to the business tables and collect the records
/// that changed, in the order they changed. Delete cascades to Comments of an Entry.
fn apply_business(t: &mut Tables, name: &str, arguments: &Value) -> Vec<RecordKey> {
    let (model, slot) = match name {
        "CreateEntry" | "Edit" | "DeleteEntry" => ("Entry", "entry"),
        "CreateComment" | "EditComment" | "DeleteComment" => ("Comment", "comment"),
        other => panic!("unknown mutation {other}"),
    };
    let arg = &arguments[slot];
    let key = key_of(model, &arg["identity"]);
    let k = encoded(&key);
    let mut changed = vec![];
    match name {
        "CreateEntry" | "CreateComment" => {
            let mut state = arg["data"].as_object().cloned().unwrap_or_default();
            for (f, v) in arg["identity"].as_object().unwrap() {
                state.insert(f.clone(), v.clone());
            }
            t.records.insert(k, Value::Object(state));
            changed.push(key);
        }
        "Edit" | "EditComment" => {
            if let Some(Value::Object(state)) = t.records.get_mut(&k) {
                for (f, v) in arg["patch"].as_object().unwrap() {
                    state.insert(f.clone(), v.clone());
                }
            }
            changed.push(key);
        }
        _ => {
            t.records.remove(&k);
            if model == "Entry" {
                let id = arg["identity"]["id"].clone();
                let children: Vec<String> = t
                    .records
                    .iter()
                    .filter(|(ck, v)| ck.starts_with("[\"Comment\"") && v["entryId"] == id)
                    .map(|(ck, _)| ck.clone())
                    .collect();
                for ck in children {
                    let v = t.records.remove(&ck).unwrap();
                    changed.push(key_of("Comment", &json!({"id": v["id"]})));
                }
            }
            changed.push(key);
        }
    }
    changed
}

impl Host for MemHost {
    fn call(
        &self,
        r: Value,
    ) -> Pin<Box<dyn Future<Output = otter_server::Result<Value>> + Send + '_>> {
        Box::pin(async move {
            let mut s = self.0.lock().unwrap();
            let op = r["op"].as_str().unwrap_or("");
            Ok(match op {
                "claim" => {
                    let id = r["clientId"].as_str().unwrap().to_string();
                    s.clients
                        .entry(id)
                        .or_insert_with(|| json!({"clientId":r["clientId"],"owner":r["owner"],"sequence":0,"receipt":null}))
                        .clone()
                }
                "saveReceipt" => {
                    let id = r["clientId"].as_str().unwrap().to_string();
                    s.clients.insert(
                        id,
                        json!({"clientId":r["clientId"],"owner":r["owner"],"sequence":r["sequence"],"receipt":r["receipt"]}),
                    );
                    Value::Null
                }
                "head" => json!(
                    s.tables
                        .heads
                        .get(r["channel"].as_str().unwrap())
                        .copied()
                        .unwrap_or(0)
                ),
                "savepoint" => {
                    let snap = s.tables.clone();
                    s.savepoints.push(snap);
                    Value::Null
                }
                "rollback" => {
                    // Mirrors SQL ROLLBACK TO SAVEPOINT: restores the snapshot but leaves
                    // it on the stack. The server always follows with a `release`, which
                    // is the one that pops it (mirroring RELEASE SAVEPOINT).
                    let snap = s
                        .savepoints
                        .last()
                        .cloned()
                        .expect("rollback without savepoint");
                    s.tables = snap;
                    Value::Null
                }
                "release" => {
                    s.savepoints.pop().expect("release without savepoint");
                    Value::Null
                }
                "handle" => {
                    s.handler_calls += 1;
                    if s.fail_next {
                        s.fail_next = false;
                        s.failed += 1;
                        return Err("injected failure".into());
                    }
                    if let Some(code) = s.reject_next.take() {
                        s.rejected += 1;
                        return Ok(json!({ "rejection": code }));
                    }
                    let name = r["name"].as_str().unwrap();
                    let changed = apply_business(&mut s.tables, name, &r["arguments"]);
                    let mut selected: Option<String> = None;
                    for key in &changed {
                        let channels = s.membership.get(&encoded(key)).cloned().unwrap_or_default();
                        for c in &channels {
                            publish_one(&mut s.tables, c, key);
                        }
                        if selected.is_none() {
                            selected = channels.first().cloned();
                        }
                    }
                    s.accepted += 1;
                    match selected {
                        Some(c) => json!({ "channel": c }),
                        None => json!({}),
                    }
                }
                "publish" => {
                    let key = key_of(r["model"].as_str().unwrap(), &r["identity"]);
                    let (cursor, stamp) =
                        publish_one(&mut s.tables, r["channel"].as_str().unwrap(), &key);
                    json!({ "cursor": cursor, "stamp": stamp })
                }
                "scan" => {
                    let channel = r["channel"].as_str().unwrap();
                    let after = r["after"].as_u64().unwrap();
                    let limit = r["limit"].as_u64().unwrap() as usize;
                    let mut rows: Vec<&Invalidation> = s
                        .tables
                        .invalidations
                        .iter()
                        .filter(|((c, _), row)| c == channel && row.cursor > after)
                        .map(|(_, row)| row)
                        .collect();
                    rows.sort_by_key(|row| row.cursor);
                    Value::Array(
                        rows.into_iter()
                            .take(limit)
                            .map(|row| {
                                json!({"channel":channel,"cursor":row.cursor,"model":row.model,"identity":row.identity,"identityKey":row.identity_key,"stamp":row.stamp})
                            })
                            .collect(),
                    )
                }
                "load" => {
                    let model = r["model"].as_str().unwrap();
                    Value::Array(
                        r["identities"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|identity| {
                                let key = key_of(model, identity);
                                match s.tables.records.get(&encoded(&key)) {
                                    Some(v) => {
                                        let mut m: Map<String, Value> =
                                            v.as_object().unwrap().clone();
                                        if model == "Entry" {
                                            m.entry("note").or_insert(Value::Null);
                                        }
                                        Value::Object(m)
                                    }
                                    None => Value::Null,
                                }
                            })
                            .collect(),
                    )
                }
                other => return Err(format!("unsupported host op {other}")),
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{self, entry_key};
    use otter_core::{PullPage, PullRequest, PushReceipt};

    fn push_bytes(client_id: &str, sequence: u64, mutation: &otter_client::Mutation) -> Vec<u8> {
        let m = serde_json::to_value(mutation).unwrap();
        let ops = &m["operations"];
        let body = json!({"clientId":client_id,"batchSequence":sequence,"mutations":[{"ordinal":1,"name":mutation.name,"version":1,"operations":ops}]});
        otter_core::PushRequest::decode(otter_core::canonical_json(&body).unwrap().as_bytes())
            .unwrap()
            .encode()
            .unwrap()
    }

    #[test]
    fn push_allocates_stamps_and_pull_delivers_them() {
        let host = MemHost::new();
        host.set_membership(&entry_key("e1"), &["a", "b"]);
        let receipt = host
            .push("u", &push_bytes("c1", 1, &schema::create_entry("e1", "hi")))
            .unwrap();
        let receipt = PushReceipt::decode(receipt.as_bytes()).unwrap();
        assert_eq!(receipt.rejections.len(), 0);
        assert_eq!(receipt.required_checkpoints.len(), 1);
        assert_eq!(receipt.required_checkpoints[0].channel, "a");
        assert_eq!(receipt.required_checkpoints[0].cursor, 1);
        assert_eq!(host.head("a"), 1);
        assert_eq!(host.head("b"), 1);
        assert_eq!(
            host.stamp(&entry_key("e1")),
            2,
            "one stamp per (channel, record) publish"
        );
        assert_eq!(host.handler_calls(), 1);
        // Duplicate push returns the stored receipt without a handler call.
        let again = host
            .push("u", &push_bytes("c1", 1, &schema::create_entry("e1", "hi")))
            .unwrap();
        assert_eq!(PushReceipt::decode(again.as_bytes()).unwrap(), receipt);
        assert_eq!(host.handler_calls(), 1);
        // A gap is refused.
        assert_eq!(
            host.push("u", &push_bytes("c1", 3, &schema::edit("e1", "x")))
                .unwrap_err(),
            "gap"
        );
        // Pull on b sees the record with the stamp the b row holds.
        let req = PullRequest {
            channel: "b".into(),
            client_id: "c1".into(),
            from_cursor: 0,
        }
        .encode()
        .unwrap();
        let page = PullPage::decode(host.pull("u", &req).unwrap().as_bytes()).unwrap();
        assert_eq!(page.changes.len(), 1);
        assert_eq!(page.changes[0].stamp, 2);
        assert_eq!(page.changes[0].state["text"], "hi");
        assert_eq!(page.to_cursor, 1);
    }

    #[test]
    fn rejection_rolls_back_one_mutation_and_failure_aborts_the_batch() {
        let host = MemHost::new();
        host.set_membership(&entry_key("e1"), &["a"]);
        host.push("u", &push_bytes("c1", 1, &schema::create_entry("e1", "hi")))
            .unwrap();
        host.reject_next("entry.denied");
        let r = PushReceipt::decode(
            host.push("u", &push_bytes("c1", 2, &schema::edit("e1", "no")))
                .unwrap()
                .as_bytes(),
        )
        .unwrap();
        assert_eq!(r.rejections.len(), 1);
        assert_eq!(r.rejections[0].code, "entry.denied");
        assert_eq!(host.state(&entry_key("e1")).unwrap()["text"], "hi");
        assert_eq!(host.head("a"), 1);
        host.fail_next();
        assert!(
            host.push("u", &push_bytes("c1", 3, &schema::edit("e1", "boom")))
                .is_err()
        );
        assert_eq!(host.state(&entry_key("e1")).unwrap()["text"], "hi");
        assert_eq!(host.head("a"), 1);
        assert_eq!(
            host.savepoint_depth(),
            0,
            "the failed batch's savepoint must not leak"
        );
        // The failed batch left no receipt, so sequence 3 is still next.
        let ok = host
            .push("u", &push_bytes("c1", 3, &schema::edit("e1", "yes")))
            .unwrap();
        assert_eq!(
            PushReceipt::decode(ok.as_bytes()).unwrap().rejections.len(),
            0
        );
        assert_eq!(host.state(&entry_key("e1")).unwrap()["text"], "yes");
    }

    #[test]
    fn deleting_an_entry_cascades_to_its_comments_and_notifies_each() {
        let host = MemHost::new();
        host.set_membership(&entry_key("e1"), &["a"]);
        host.set_membership(&schema::comment_key("c1"), &["a"]);
        host.push("u", &push_bytes("c1", 1, &schema::create_entry("e1", "hi")))
            .unwrap();
        host.push(
            "u",
            &push_bytes("c1", 2, &schema::create_comment("c1", "e1", "yo")),
        )
        .unwrap();
        host.push("u", &push_bytes("c1", 3, &schema::delete_entry("e1")))
            .unwrap();
        assert!(host.state(&entry_key("e1")).is_none());
        assert!(host.state(&schema::comment_key("c1")).is_none());
        assert_eq!(host.head("a"), 4);
        let req = PullRequest {
            channel: "a".into(),
            client_id: "c1".into(),
            from_cursor: 2,
        }
        .encode()
        .unwrap();
        let page = PullPage::decode(host.pull("u", &req).unwrap().as_bytes()).unwrap();
        assert_eq!(page.changes.len(), 2);
        assert!(page.changes.iter().all(|c| c.state.is_null()));
    }
}
