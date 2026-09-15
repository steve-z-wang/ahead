//! The server's persistence, in memory. Mirrors packages/persistence-prisma/index.mts
//! closely enough that ahead_server cannot tell the difference: per-client receipts,
//! per-channel heads, one invalidation row per (channel, record) carrying the latest
//! cursor and stamp, and one stamp counter per record.
use ahead_core::{PushRequest, RecordKey};
use ahead_server::{
    Host,
    host::{
        Acknowledged, Claimed, Handled, Head, HostRequest, Invalidation as ContractInvalidation,
        Loaded, Published, Scanned,
    },
};
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
    /// Per key, the smallest stamp allocated by the publishes that followed its most
    /// recent *content* change (see `publish_many`). Distinct from `stamps` (the
    /// ever-growing per-key counter every channel's publish draws from): a single
    /// change notified to two member channels in the same call allocates them
    /// consecutive stamps even though both carry identical content, so comparing a
    /// channel's own last stamp against the raw counter would call the first of the
    /// two "behind" forever. Comparing against this instead treats every channel a
    /// change actually reached as caught up with it.
    content_stamps: BTreeMap<String, u64>,
    heads: BTreeMap<String, u64>,
    invalidations: BTreeMap<(String, String), Invalidation>,
}

#[derive(Default)]
struct State {
    tables: Tables,
    membership: BTreeMap<String, Vec<String>>,
    clients: BTreeMap<String, Claimed>,
    savepoints: Vec<Tables>,
    reject_next: Option<String>,
    fail_next: bool,
    handler_calls: usize,
    accepted: usize,
    rejected: usize,
    failed: usize,
    /// The (clientId, batchSequence) of the push currently being processed, decoded
    /// from the raw request bytes in `push()` - the `handle` op itself carries only
    /// `ordinal` (see `crates/server/src/lib.rs::process_push`), and the server's wire
    /// contract with its host is not otherwise touched by this bookkeeping.
    current_push: Option<(String, u64)>,
    /// (clientId, batchSequence, ordinal) for every `handle` call, in call order.
    /// `no_mutation_executes_twice` asserts these are pairwise distinct: a retry that
    /// reached the handler again (rather than being short-circuited by the stored
    /// receipt) would duplicate one.
    handler_invocations: Vec<(String, u64, u64)>,
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
        publish_many(&mut s.tables, channels, key);
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
    /// The smallest stamp allocated by the publishes that followed `key`'s most
    /// recent content change - see `Tables::content_stamps`. A bare `set_state` with
    /// no accompanying `notify`/`publish_many` call (used to simulate a change no
    /// channel is ever told about) deliberately leaves this untouched, so that fault
    /// is still caught as a divergence rather than masked as "behind."
    pub fn content_stamp(&self, key: &RecordKey) -> u64 {
        self.0
            .lock()
            .unwrap()
            .tables
            .content_stamps
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
    /// (clientId, batchSequence, ordinal) for every `handle` call the host has made,
    /// in call order. See `no_mutation_executes_twice` in invariants.rs.
    pub fn handler_invocations(&self) -> Vec<(String, u64, u64)> {
        self.0.lock().unwrap().handler_invocations.clone()
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
    /// The stamp a (channel, key) invalidation was published with, if the channel has
    /// ever been notified of `key`. `ServerChange` can notify a subset of channels
    /// that excludes one of a record's real member channels, in which case that
    /// member channel's own last-known stamp falls behind `stamp(key)` (the shared
    /// per-key counter every channel's publish draws from) until it is next notified.
    pub fn channel_stamp(&self, channel: &str, key: &RecordKey) -> Option<u64> {
        self.0
            .lock()
            .unwrap()
            .tables
            .invalidations
            .get(&(channel.to_string(), encoded(key)))
            .map(|row| row.stamp)
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
        if row.sequence == sequence {
            row.receipt.clone()
        } else {
            None
        }
    }
    pub fn push(&self, owner: &str, bytes: &[u8]) -> Result<String, String> {
        // The `handle` op carries only `ordinal`, not `clientId` or `batchSequence`
        // (see `process_push` in crates/server) - decode the raw request here, at the
        // one place that already has the bytes, rather than growing the wire protocol
        // between the server and its host just for this bookkeeping.
        if let Ok(request) = PushRequest::decode(bytes) {
            self.0.lock().unwrap().current_push = Some((request.client_id, request.batch_sequence));
        }
        let (before, depth, invocations) = {
            let s = self.0.lock().unwrap();
            (
                s.tables.clone(),
                s.savepoints.len(),
                s.handler_invocations.len(),
            )
        };
        let result = block_on(ahead_server::process_push(
            &crate::schema::config(),
            owner,
            bytes,
            self,
        ))
        .map_err(|e| e.to_string());
        if result.is_err() {
            // An aborted batch is a rolled-back transaction: nothing it did survives.
            // A `handle` error short-circuits process_push after `savepoint` but before
            // the matching `release`, so the savepoint stack must also be restored to
            // its pre-call depth here — this is the same invariant a successful push
            // already leaves it at (every `savepoint` is paired with a `release`).
            //
            // The client legitimately retries the same bytes after this (P6), and that
            // retry will call `handle` again for the same ordinals - that is correct,
            // not a double execution, because nothing from this attempt was ever
            // durably accepted. So `handler_invocations` rolls back with the tables:
            // only a triple recorded by a push that actually committed counts toward
            // `no_mutation_executes_twice`.
            let mut s = self.0.lock().unwrap();
            s.tables = before;
            s.savepoints.truncate(depth);
            s.handler_invocations.truncate(invocations);
        }
        result
    }
    pub fn savepoint_depth(&self) -> usize {
        self.0.lock().unwrap().savepoints.len()
    }
    pub fn pull(&self, owner: &str, bytes: &[u8]) -> Result<String, String> {
        block_on(ahead_server::process_pull(
            &crate::schema::config(),
            owner,
            bytes,
            self,
        ))
        .map_err(|e| e.to_string())
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

/// Publish `key` to every channel in `channels`, all stemming from one logical
/// content change, then record that change's `content_stamp` as the smallest stamp
/// this batch allocates - the first one, computed before any of this batch's
/// `publish_one` calls run. Every channel here ends up with a stamp `>=` that value,
/// so all of them, not just the one that happened to publish last, compare as
/// caught up with this change (see `Tables::content_stamps`). A change published to
/// no channels (empty membership) leaves `content_stamps` untouched: nothing was
/// told, so there is nothing to be "caught up" with yet.
fn publish_many(t: &mut Tables, channels: &[&str], key: &RecordKey) {
    if channels.is_empty() {
        return;
    }
    let start = t.stamps.get(&encoded(key)).copied().unwrap_or(0) + 1;
    for c in channels {
        publish_one(t, c, key);
    }
    t.content_stamps.insert(encoded(key), start);
}

fn key_of(model: &str, identity: &Value) -> RecordKey {
    crate::schema::schema().record_key(model, identity).unwrap()
}

/// Apply one decoded handler argument to the business tables and collect the records
/// that changed, in the order they changed. Delete cascades to Comments of an Entry.
/// `Err` is a rejection code: the mutation is refused, nothing it did survives (the
/// caller never publishes for an `Err`), and the caller counts it as `rejected`
/// rather than `accepted` - the same outcome a real per-mutation rejection produces,
/// so the client processes it through the ordinary rejection/rollback path instead of
/// being left with a push that neither settles nor ever gets a channel checkpoint.
fn apply_business(
    t: &mut Tables,
    name: &str,
    arguments: &Value,
) -> Result<Vec<RecordKey>, &'static str> {
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
            // The schema declares Comment.entryId as a real relation to Entry with
            // onDelete: delete (see schema.rs) - a real FK-backed store would refuse
            // an insert whose parent row is missing. Two clients racing a delete of
            // the parent against a create of the child (both accepted independently
            // by the mutation queue, which never checks against remote state) is
            // exactly the case that constraint exists to catch: without it, the
            // comment lands as a permanent orphan no future delete will ever cascade
            // into, because that delete already happened.
            if name == "CreateComment" {
                let entry_id = arg["data"]["entryId"].clone();
                let entry_key = encoded(&key_of("Entry", &json!({ "id": entry_id })));
                if !t.records.contains_key(&entry_key) {
                    return Err("comment.entry_missing");
                }
            }
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
    Ok(changed)
}

/// The sim answers with the contract's own response types, so a drift between
/// `crates/server/src/host.rs` and this host is a Rust compile error.
macro_rules! response {
    ($value:expr) => {
        serde_json::to_value($value).expect("host responses encode")
    };
}

impl Host for MemHost {
    fn call(
        &self,
        request: Value,
    ) -> Pin<Box<dyn Future<Output = ahead_server::HostResult<Value>> + Send + '_>> {
        Box::pin(async move {
            let request: HostRequest = serde_json::from_value(request)
                .map_err(|error| format!("unsupported host request: {error}"))?;
            let mut s = self.0.lock().unwrap();
            Ok(match request {
                HostRequest::Claim { owner, client_id } => {
                    let claimed = s
                        .clients
                        .entry(client_id.clone())
                        .or_insert_with(|| Claimed {
                            client_id,
                            owner,
                            sequence: 0,
                            receipt: None,
                        })
                        .clone();
                    response!(claimed)
                }
                HostRequest::SaveReceipt {
                    owner,
                    client_id,
                    sequence,
                    receipt,
                } => {
                    s.clients.insert(
                        client_id.clone(),
                        Claimed {
                            client_id,
                            owner,
                            sequence,
                            receipt: Some(receipt),
                        },
                    );
                    response!(Acknowledged)
                }
                HostRequest::Head { channel } => {
                    response!(Head(s.tables.heads.get(&channel).copied().unwrap_or(0)))
                }
                HostRequest::Savepoint { .. } => {
                    let snap = s.tables.clone();
                    s.savepoints.push(snap);
                    response!(Acknowledged)
                }
                HostRequest::Rollback { .. } => {
                    // Mirrors SQL ROLLBACK TO SAVEPOINT: restores the snapshot but leaves
                    // it on the stack. The server always follows with a `release`, which
                    // is the one that pops it (mirroring RELEASE SAVEPOINT).
                    let snap = s
                        .savepoints
                        .last()
                        .cloned()
                        .expect("rollback without savepoint");
                    s.tables = snap;
                    response!(Acknowledged)
                }
                HostRequest::Release { .. } => {
                    s.savepoints.pop().expect("release without savepoint");
                    response!(Acknowledged)
                }
                HostRequest::Handle {
                    name,
                    arguments,
                    ordinal,
                    ..
                } => {
                    s.handler_calls += 1;
                    if let Some((client_id, batch_sequence)) = s.current_push.clone() {
                        s.handler_invocations
                            .push((client_id, batch_sequence, ordinal));
                    }
                    if s.fail_next {
                        s.fail_next = false;
                        s.failed += 1;
                        return Err("injected failure".into());
                    }
                    if let Some(code) = s.reject_next.take() {
                        s.rejected += 1;
                        return Ok(response!(Handled::Rejected { rejection: code }));
                    }
                    match apply_business(&mut s.tables, &name, &arguments) {
                        Ok(changed) => {
                            let mut selected: Option<String> = None;
                            for key in &changed {
                                let channels =
                                    s.membership.get(&encoded(key)).cloned().unwrap_or_default();
                                let refs: Vec<&str> = channels.iter().map(String::as_str).collect();
                                publish_many(&mut s.tables, &refs, key);
                                if selected.is_none() {
                                    selected = channels.first().cloned();
                                }
                            }
                            s.accepted += 1;
                            match selected {
                                Some(channel) => response!(Handled::Settled { channel }),
                                // No channel claims anything the handler changed, so
                                // there is no settlement to report. `Handled` cannot
                                // express that, and the engine refuses the empty object
                                // with `handler.invalid` - which is the outcome this
                                // host has always produced here.
                                None => json!({}),
                            }
                        }
                        Err(code) => {
                            s.rejected += 1;
                            response!(Handled::Rejected {
                                rejection: code.to_string(),
                            })
                        }
                    }
                }
                HostRequest::Publish {
                    channel,
                    model,
                    identity,
                    ..
                } => {
                    let key = key_of(&model, &identity);
                    let (cursor, stamp) = publish_one(&mut s.tables, &channel, &key);
                    response!(Published { cursor, stamp })
                }
                HostRequest::Scan {
                    channel,
                    after,
                    limit,
                } => {
                    let mut rows: Vec<&Invalidation> = s
                        .tables
                        .invalidations
                        .iter()
                        .filter(|((c, _), row)| *c == channel && row.cursor > after)
                        .map(|(_, row)| row)
                        .collect();
                    rows.sort_by_key(|row| row.cursor);
                    let scanned: Scanned = rows
                        .into_iter()
                        .take(limit as usize)
                        .map(|row| ContractInvalidation {
                            channel: channel.clone(),
                            cursor: row.cursor,
                            model: row.model.clone(),
                            identity: row.identity.clone(),
                            identity_key: row.identity_key.clone(),
                            stamp: row.stamp,
                        })
                        .collect();
                    response!(scanned)
                }
                HostRequest::Load {
                    model,
                    identities,
                    channel,
                    ..
                } => {
                    let loaded: Loaded = identities
                        .iter()
                        .map(|identity| {
                            let key = key_of(&model, identity);
                            let k = encoded(&key);
                            // A channel-blind load would let a stale request from a
                            // channel that no longer claims this record see another
                            // channel's newer content. Membership set explicitly
                            // (even if the requesting channel isn't in it) is
                            // authoritative for that channel's view; membership
                            // never set at all keeps the old, channel-blind lookup.
                            if let Some(members) = s.membership.get(&k)
                                && !members.contains(&channel)
                            {
                                return None;
                            }
                            s.tables.records.get(&k).map(|v| {
                                let mut m: Map<String, Value> = v.as_object().unwrap().clone();
                                if model == "Entry" {
                                    m.entry("note").or_insert(Value::Null);
                                }
                                Value::Object(m)
                            })
                        })
                        .collect();
                    response!(loaded)
                }
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{self, entry_key};
    use ahead_core::{PullPage, PullRequest, PushReceipt};

    fn push_bytes(client_id: &str, sequence: u64, mutation: &ahead_client::Mutation) -> Vec<u8> {
        let m = serde_json::to_value(mutation).unwrap();
        let ops = &m["operations"];
        let body = json!({"clientId":client_id,"batchSequence":sequence,"mutations":[{"ordinal":1,"name":mutation.name,"version":1,"operations":ops}]});
        ahead_core::PushRequest::decode(ahead_core::canonical_json(&body).unwrap().as_bytes())
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
            models: schema::declared_models(),
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
            models: schema::declared_models(),
        }
        .encode()
        .unwrap();
        let page = PullPage::decode(host.pull("u", &req).unwrap().as_bytes()).unwrap();
        assert_eq!(page.changes.len(), 2);
        assert!(page.changes.iter().all(|c| c.state.is_null()));
    }

    #[test]
    fn create_comment_against_a_missing_entry_is_deterministically_rejected() {
        let host = MemHost::new();
        host.set_membership(&schema::comment_key("c1"), &["a"]);
        // No Entry e1 was ever created: the schema's onDelete: delete relation means
        // a real FK-backed store would refuse this insert outright.
        let r = PushReceipt::decode(
            host.push(
                "u",
                &push_bytes("c1", 1, &schema::create_comment("c1", "e1", "hi")),
            )
            .unwrap()
            .as_bytes(),
        )
        .unwrap();
        assert_eq!(r.rejections.len(), 1);
        assert_eq!(r.rejections[0].code, "comment.entry_missing");
        assert!(host.state(&schema::comment_key("c1")).is_none());
        assert_eq!(host.rejected(), 1);
        assert_eq!(host.accepted(), 0);
        assert_eq!(
            host.handler_calls(),
            host.accepted() + host.rejected() + host.failed(),
            "no_mutation_executes_twice must hold for a rejection too"
        );
    }

    #[test]
    fn load_is_channel_aware_once_membership_is_set() {
        let host = MemHost::new();
        host.set_membership(&entry_key("e1"), &["b"]);
        host.set_state(
            &entry_key("e1"),
            Some(json!({"id":"e1","text":"in b","note":null})),
        );
        // Notify both channels directly (as ServerChange does in the sim): only
        // channel b is in e1's membership, so a's page must see nothing.
        host.notify(&entry_key("e1"), &["a", "b"]);
        let req_a = PullRequest {
            channel: "a".into(),
            client_id: "c1".into(),
            from_cursor: 0,
            models: schema::declared_models(),
        }
        .encode()
        .unwrap();
        let page_a = PullPage::decode(host.pull("u", &req_a).unwrap().as_bytes()).unwrap();
        assert_eq!(page_a.changes.len(), 1);
        assert!(
            page_a.changes[0].state.is_null(),
            "a is not in e1's membership"
        );
        let req_b = PullRequest {
            channel: "b".into(),
            client_id: "c1".into(),
            from_cursor: 0,
            models: schema::declared_models(),
        }
        .encode()
        .unwrap();
        let page_b = PullPage::decode(host.pull("u", &req_b).unwrap().as_bytes()).unwrap();
        assert_eq!(page_b.changes.len(), 1);
        assert_eq!(page_b.changes[0].state["text"], "in b");
    }
}
