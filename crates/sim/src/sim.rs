//! The arena. Holds the clients, the host, the network and the RNG; applies actions;
//! records the trace. Invariants live in invariants.rs; random stepping in step.rs.
use crate::{
    host::MemHost,
    net::{Message, Network},
    rng::Rng,
    schema,
};
use ahead_client::{Client, Operation, OperationKind};
use ahead_core::{PullPage, PullRequest, PushReceipt, PushRequest, RecordKey};
use ahead_sqlite::SqliteStore;
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MutationSpec {
    CreateEntry {
        id: String,
        text: String,
    },
    Edit {
        id: String,
        text: String,
    },
    DeleteEntry {
        id: String,
    },
    CreateComment {
        id: String,
        entry: String,
        text: String,
    },
    EditComment {
        id: String,
        text: String,
    },
    DeleteComment {
        id: String,
    },
}

impl MutationSpec {
    pub fn key(&self) -> RecordKey {
        match self {
            MutationSpec::CreateEntry { id, .. }
            | MutationSpec::Edit { id, .. }
            | MutationSpec::DeleteEntry { id } => schema::entry_key(id),
            MutationSpec::CreateComment { id, .. }
            | MutationSpec::EditComment { id, .. }
            | MutationSpec::DeleteComment { id } => schema::comment_key(id),
        }
    }
    pub fn build(&self) -> ahead_client::Mutation {
        match self {
            MutationSpec::CreateEntry { id, text } => schema::create_entry(id, text),
            MutationSpec::Edit { id, text } => schema::edit(id, text),
            MutationSpec::DeleteEntry { id } => schema::delete_entry(id),
            MutationSpec::CreateComment { id, entry, text } => {
                schema::create_comment(id, entry, text)
            }
            MutationSpec::EditComment { id, text } => schema::edit_comment(id, text),
            MutationSpec::DeleteComment { id } => schema::delete_comment(id),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Enqueue {
        client: usize,
        mutation: MutationSpec,
    },
    Direct {
        client: usize,
        key: String,
        text: String,
    },
    Subscribe {
        client: usize,
        channel: String,
    },
    Unsubscribe {
        client: usize,
        channel: String,
    },
    Freeze {
        client: usize,
    },
    Pull {
        client: usize,
        channel: String,
    },
    Deliver,
    Drop,
    Duplicate,
    Hold,
    Swap {
        i: usize,
        j: usize,
    },
    Crash {
        client: usize,
    },
    Restart {
        client: usize,
    },
    ServerChange {
        key: String,
        text: Option<String>,
        channels: Vec<String>,
    },
    /// A record's real membership legitimately moves to `channels`: the new members
    /// and the ones it leaves both get notified (the ones it leaves load `null`, the
    /// application-correct "moved away" delete per the record-stamp spec's "Delete
    /// applies across channels").
    MoveMembership {
        key: String,
        channels: Vec<String>,
    },
    RejectNext {
        code: String,
    },
    FailNext,
}

pub struct Slot {
    pub path: PathBuf,
    pub client: Option<Client<SqliteStore>>,
    pub enqueued: Vec<u64>,
    pub receipts: BTreeMap<u64, PushReceipt>,
}

pub struct Sim {
    pub host: MemHost,
    pub net: Network,
    pub rng: Rng,
    pub trace: Vec<Action>,
    pub clients: Vec<Slot>,
    pub seen_stamps: BTreeMap<(usize, String), u64>,
    pub seen_cursors: BTreeMap<(usize, String), u64>,
    pub known_entries: Vec<String>,
    pub known_comments: Vec<String>,
    pub(crate) next_id: u64,
    /// (client, encoded key) pairs that received a direct write since the last
    /// authoritative content for that key landed on that client. A direct write
    /// diverges from the server by design (N4/L4); `no_pending_means_converged`
    /// exempts exactly these pairs rather than the whole client or channel.
    pub direct_writes: BTreeSet<(usize, String)>,
    /// Whether the random stepper (`step.rs::choose`) may generate `Action::Direct`.
    /// Defaults to true; tests/invariants.rs runs the R2 runner both ways.
    pub generate_direct: bool,
    /// Whether `Action::ServerChange` (`step.rs::choose`) may notify a channel outside
    /// a record's real, explicitly-set membership *without* also notifying every
    /// channel that currently provides the record. Defaults to false: per
    /// `docs/superpowers/specs/2026-09-12-record-stamp-design.md`, "Delete applies
    /// across channels" - "Hiding a record on one channel is a change to that record,
    /// so the rule above applies: the handler notifies every channel that provides
    /// it" - a notify that skips a real member channel is an application-rule
    /// violation, not an engine defect. When this flag is set, the unrelated
    /// channel's own load-refused-content (null) invalidation correctly outranks the
    /// member channel's stale content by stamp once notified: the client applying it
    /// as a delete is the engine doing exactly what a genuine cross-channel delete
    /// requires, given an application that broke the rule. Off by default so the R2
    /// runner does not fuzz an application bug the engine was never meant to defend
    /// against; a test that wants to exercise this sets it directly.
    pub generate_membership_faults: bool,
    /// Count of actual (client, key) content comparisons `no_pending_means_converged`
    /// has made across the run - the checks it skips (not at head, exempted by a
    /// direct write, membership or content-stamp gate) do not count. The R2 runner
    /// asserts a floor on the sum across seeds so this coverage cannot silently drop.
    pub comparisons: usize,
    _dir: tempfile::TempDir,
}

pub const OWNER: &str = "u";

/// (client index, pending mutation count, subscriptions) used to detect convergence
/// in `Sim::settle`.
type SimSnapshot = (usize, u64, Vec<(String, u64)>);

fn open(path: &PathBuf) -> Client<SqliteStore> {
    Client::open(SqliteStore::open(path).unwrap(), schema::schema()).unwrap()
}

pub fn parse_key(s: &str) -> RecordKey {
    let (model, id) = s.split_once(':').expect("key as Model:id");
    match model {
        "Entry" => schema::entry_key(id),
        "Comment" => schema::comment_key(id),
        other => panic!("unknown model {other}"),
    }
}

impl Sim {
    pub fn new(seed: u64, clients: usize) -> Sim {
        let dir = tempfile::tempdir().unwrap();
        let clients = (0..clients)
            .map(|i| {
                let path = dir.path().join(format!("client-{i}.sqlite"));
                Slot {
                    client: Some(open(&path)),
                    path,
                    enqueued: vec![],
                    receipts: BTreeMap::new(),
                }
            })
            .collect();
        Sim {
            host: MemHost::new(),
            net: Network::new(),
            rng: Rng::new(seed),
            trace: vec![],
            clients,
            seen_stamps: BTreeMap::new(),
            seen_cursors: BTreeMap::new(),
            known_entries: vec![],
            known_comments: vec![],
            next_id: 0,
            direct_writes: BTreeSet::new(),
            generate_direct: true,
            generate_membership_faults: false,
            comparisons: 0,
            _dir: dir,
        }
    }
    pub fn check(&mut self) -> Result<(), String> {
        crate::invariants::check(self)
    }
    pub fn client(&mut self, i: usize) -> &mut Client<SqliteStore> {
        self.clients[i].client.as_mut().expect("client is crashed")
    }
    pub fn is_up(&self, i: usize) -> bool {
        self.clients[i].client.is_some()
    }
    pub fn read_text(&mut self, client: usize, key: &RecordKey) -> Option<String> {
        self.client(client)
            .read(key)
            .unwrap()
            .and_then(|v| v["text"].as_str().map(str::to_string))
    }
    fn ensure_membership(&mut self, spec: &MutationSpec) {
        let key = spec.key();
        if self.host.has_membership(&key) {
            return;
        }
        let channels = match spec {
            MutationSpec::CreateComment { entry, .. } => {
                let parent = self.host.membership(&schema::entry_key(entry));
                if parent.is_empty() {
                    vec!["a".to_string()]
                } else {
                    parent
                }
            }
            _ => vec!["a".to_string()],
        };
        let refs: Vec<&str> = channels.iter().map(String::as_str).collect();
        self.host.set_membership(&key, &refs);
    }
    /// Move `key`'s real membership to exactly `channels`, then notify every new
    /// member and every channel it just left - the left ones now load `null` for it
    /// (membership already excludes them), the legitimate "moved away" delete.
    fn move_membership(&mut self, key: &RecordKey, channels: &[String]) {
        let old = self.host.membership(key);
        let refs: Vec<&str> = channels.iter().map(String::as_str).collect();
        self.host.set_membership(key, &refs);
        // Content is compared by absolute stamp, not delivery order (D2): whichever
        // publish gets the higher stamp wins once a client sees it, regardless of
        // which page arrives first. So the channels this record just left must be
        // published *before* every real member, not after - otherwise the "moved
        // away" delete could carry a higher stamp than the record's real content and
        // wrongly outrank it once a client applies both, exactly the ordering D4's
        // own move test uses (the vacated channel's delete is published with a lower
        // stamp than the destination's upsert).
        let removed: Vec<&str> = old
            .iter()
            .filter(|c| !channels.contains(c))
            .map(String::as_str)
            .collect();
        if !removed.is_empty() {
            self.host.notify(key, &removed);
        }
        // Then republish every real member so its stamp is unambiguously the newest.
        // Content is unchanged, but the stamp must be, so a client that later applies
        // the vacated channel's now-stale delete cannot regress this.
        self.host.notify(key, &refs);
    }
    pub fn apply(&mut self, action: Action) -> Result<(), String> {
        self.trace.push(action.clone());
        match action {
            Action::Enqueue { client, mutation } => {
                self.ensure_membership(&mutation);
                let m = mutation.build();
                let ordinal = self
                    .client(client)
                    .transaction(|tx| tx.enqueue(m))
                    .map_err(|e| e.to_string())?;
                self.clients[client].enqueued.push(ordinal);
            }
            Action::Direct { client, key, text } => {
                let key = parse_key(&key);
                let op = Operation {
                    model: key.model.clone(),
                    op: OperationKind::Update,
                    identity: key.identity.clone(),
                    values: Some(json!({ "text": text })),
                };
                self.client(client)
                    .transaction(|tx| tx.direct(op))
                    .map_err(|e| e.to_string())?;
                self.direct_writes.insert((client, key.encoded().unwrap()));
            }
            Action::Subscribe { client, channel } => {
                self.client(client)
                    .transaction(|tx| tx.set_channel(channel, true))
                    .map_err(|e| e.to_string())?;
            }
            Action::Unsubscribe { client, channel } => {
                self.client(client)
                    .transaction(|tx| tx.set_channel(channel, false))
                    .map_err(|e| e.to_string())?;
            }
            Action::Freeze { client } => {
                if let Some(bytes) = self.client(client).freeze().map_err(|e| e.to_string())? {
                    self.net.send(Message::Push { client, bytes });
                }
            }
            Action::Pull { client, channel } => {
                let c = self.client(client);
                if !c
                    .desired_channels()
                    .map_err(|e| e.to_string())?
                    .contains(&channel)
                {
                    return Ok(());
                }
                let from_cursor = c.cursor(&channel).map_err(|e| e.to_string())?;
                let bytes = PullRequest {
                    channel: channel.clone(),
                    client_id: c.client_id().to_string(),
                    from_cursor,
                }
                .encode()
                .map_err(|e| e.to_string())?;
                self.net.send(Message::Pull {
                    client,
                    channel,
                    bytes,
                });
            }
            Action::Deliver => self.deliver()?,
            Action::Drop => {
                self.net.drop_front();
            }
            Action::Duplicate => {
                self.net.duplicate_front();
            }
            Action::Hold => {
                self.net.hold_front();
            }
            Action::Swap { i, j } => {
                self.net.swap(i, j);
            }
            Action::Crash { client } => {
                self.clients[client].client = None;
            }
            Action::Restart { client } => {
                if self.clients[client].client.is_none() {
                    let path = self.clients[client].path.clone();
                    self.clients[client].client = Some(open(&path));
                }
            }
            Action::ServerChange {
                key,
                text,
                channels,
            } => {
                let k = parse_key(&key);
                let id = k.identity["id"].clone();
                let state = text.map(|t| {
                    if k.model == "Entry" {
                        json!({"id": id, "text": t, "note": null})
                    } else {
                        json!({"id": id, "entryId": "e1", "text": t})
                    }
                });
                // A real DeleteEntry mutation cascades: the client-side engine drops a
                // Comment locally the moment it learns its parent Entry's authority
                // went to None (`set_authority` in mutate.rs walks `descendants`).
                // Nulling an Entry here without also removing its Comments would leave
                // the server holding a Comment the client is bound to cascade-drop, a
                // state the real handler never produces - so mirror the cascade,
                // notifying each dropped Comment on its own real channels.
                if state.is_none() && k.model == "Entry" {
                    for (encoded_key, value) in self.host.records() {
                        if !encoded_key.starts_with("[\"Comment\"") || value["entryId"] != id {
                            continue;
                        }
                        let Some(comment_id) = value["id"].as_str() else {
                            continue;
                        };
                        let child_key = schema::comment_key(comment_id);
                        self.host.set_state(&child_key, None);
                        let membership = self.host.membership(&child_key);
                        let child_refs: Vec<&str> = if membership.is_empty() {
                            channels.iter().map(String::as_str).collect()
                        } else {
                            membership.iter().map(String::as_str).collect()
                        };
                        self.host.notify(&child_key, &child_refs);
                    }
                }
                self.host.set_state(&k, state);
                let refs: Vec<&str> = channels.iter().map(String::as_str).collect();
                self.host.notify(&k, &refs);
            }
            Action::MoveMembership { key, channels } => {
                let k = parse_key(&key);
                self.move_membership(&k, &channels);
                // A real client cascade-drops a Comment locally the instant its
                // parent Entry's authority goes to null on a channel it's watching
                // (`set_authority` in mutate.rs walks descendants) - it cannot tell
                // "parent moved to another channel" from "parent deleted" (see the
                // record-stamp spec's "Delete applies across channels"). So a moved
                // Entry must take its Comments with it, exactly like D4 describes
                // ("a record can move to another channel entirely... including child
                // records whose membership follows the parent"), or a comment whose
                // own membership never changed would be wrongly cascade-dropped by a
                // client that still holds it through the very channel this move
                // leaves.
                if k.model == "Entry" {
                    let id = k.identity["id"].clone();
                    let child_ids: Vec<String> = self
                        .host
                        .records()
                        .into_iter()
                        .filter(|(ek, v)| ek.starts_with("[\"Comment\"") && v["entryId"] == id)
                        .filter_map(|(_, v)| v["id"].as_str().map(str::to_string))
                        .collect();
                    for comment_id in child_ids {
                        self.move_membership(&schema::comment_key(&comment_id), &channels);
                    }
                }
            }
            Action::RejectNext { code } => self.host.reject_next(&code),
            Action::FailNext => self.host.fail_next(),
        }
        Ok(())
    }
    fn deliver(&mut self) -> Result<(), String> {
        let Some(message) = self.net.pop() else {
            return Ok(());
        };
        let client = message.client();
        match message {
            Message::Push { bytes, .. } => {
                let sequence = PushRequest::decode(&bytes)
                    .map_err(|e| e.to_string())?
                    .batch_sequence;
                match self.host.push(OWNER, &bytes) {
                    Ok(receipt) => self.net.send(Message::Receipt {
                        client,
                        sequence,
                        bytes: receipt.into_bytes(),
                    }),
                    Err(error) => self.net.send(Message::PushFailed {
                        client,
                        sequence,
                        error,
                    }),
                }
            }
            Message::Receipt {
                sequence, bytes, ..
            } => {
                if !self.is_up(client) {
                    self.net.send(Message::Receipt {
                        client,
                        sequence,
                        bytes,
                    });
                    return Ok(());
                }
                let receipt = PushReceipt::decode(&bytes).map_err(|e| e.to_string())?;
                match self.client(client).acknowledge(sequence, receipt.clone()) {
                    Ok(()) => {
                        self.clients[client].receipts.insert(sequence, receipt);
                    }
                    Err(e) if e.to_string().contains("unknown batch") => {}
                    Err(e) => return Err(e.to_string()),
                }
            }
            Message::Pull { bytes, .. } => {
                let page = self.host.pull(OWNER, &bytes)?;
                self.net.send(Message::Page {
                    client,
                    bytes: page.into_bytes(),
                });
            }
            Message::Page { bytes, .. } => {
                if !self.is_up(client) {
                    self.net.send(Message::Page { client, bytes });
                    return Ok(());
                }
                let page = PullPage::decode(&bytes).map_err(|e| e.to_string())?;
                // A key this page carries a newer authoritative change for is no
                // longer shadowed by an earlier direct write on this client. Newer
                // is the client's own rule (D2): the change's stamp beats the
                // record's local stamp. A stale copy of a page the client already
                // applied (a duplicate, a late retry) leaves the direct write in
                // place, so it must keep the exemption too.
                let mut touched = vec![];
                for change in &page.changes {
                    let Ok(key) = schema::schema().record_key(&change.model, &change.identity)
                    else {
                        continue;
                    };
                    let local = self
                        .client(client)
                        .read_sql(
                            "SELECT stamp FROM ahead_record WHERE model = ? AND identity = ?",
                            &[json!(key.model), json!(key.encoded_identity().unwrap())],
                        )
                        .map_err(|e| e.to_string())?
                        .first()
                        .and_then(|r| r["stamp"].as_u64())
                        .unwrap_or(0);
                    if change.stamp > local {
                        touched.push(key.encoded().unwrap());
                    }
                }
                self.client(client)
                    .apply_page(page)
                    .map_err(|e| e.to_string())?;
                for key in touched {
                    self.direct_writes.remove(&(client, key));
                }
            }
            Message::PushFailed { .. } => {}
        }
        Ok(())
    }
    /// Deliver every queued message in order, with no faults. Messages re-queued for a
    /// crashed client stop the drain, otherwise it would spin.
    pub fn drain(&mut self) {
        let mut budget = self.net.len() * 4 + 16;
        while !self.net.is_empty() && budget > 0 {
            budget -= 1;
            self.apply(Action::Deliver).unwrap();
        }
    }
    /// Push and pull everything for every running client until nothing changes.
    pub fn settle(&mut self) {
        for _ in 0..16 {
            let before = self.snapshot();
            for i in 0..self.clients.len() {
                if !self.is_up(i) {
                    continue;
                }
                self.apply(Action::Freeze { client: i }).unwrap();
                let channels: Vec<String> = self
                    .client(i)
                    .desired_channels()
                    .unwrap()
                    .into_iter()
                    .collect();
                for channel in channels {
                    self.apply(Action::Pull { client: i, channel }).unwrap();
                }
            }
            self.drain();
            if self.snapshot() == before {
                return;
            }
        }
        panic!("settle did not converge in 16 rounds");
    }
    fn snapshot(&mut self) -> Vec<SimSnapshot> {
        let mut out = vec![];
        for i in 0..self.clients.len() {
            if !self.is_up(i) {
                continue;
            }
            let c = self.client(i);
            out.push((
                i,
                c.pending_count().unwrap() as u64,
                c.subscriptions().unwrap(),
            ));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::entry_key;

    #[test]
    fn one_client_round_trip_through_the_network() {
        let mut sim = Sim::new(1, 1);
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        sim.apply(Action::Enqueue {
            client: 0,
            mutation: MutationSpec::CreateEntry {
                id: "e1".into(),
                text: "hi".into(),
            },
        })
        .unwrap();
        assert_eq!(sim.read_text(0, &entry_key("e1")), Some("hi".into()));
        assert_eq!(sim.client(0).pending_count().unwrap(), 1);
        sim.apply(Action::Freeze { client: 0 }).unwrap();
        assert_eq!(sim.net.len(), 1);
        sim.apply(Action::Deliver).unwrap(); // push reaches the server, receipt queued
        assert_eq!(sim.host.handler_calls(), 1);
        sim.apply(Action::Deliver).unwrap(); // receipt reaches the client
        assert_eq!(
            sim.client(0).pending_count().unwrap(),
            1,
            "ACK alone does not settle"
        );
        sim.apply(Action::Pull {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        sim.apply(Action::Deliver).unwrap(); // pull reaches server, page queued
        sim.apply(Action::Deliver).unwrap(); // page reaches client
        assert_eq!(sim.client(0).pending_count().unwrap(), 0);
        assert_eq!(sim.read_text(0, &entry_key("e1")), Some("hi".into()));
        assert_eq!(sim.trace.len(), 8);
    }

    #[test]
    fn crash_and_restart_keep_the_frozen_batch_and_settle_resolves_everything() {
        let mut sim = Sim::new(2, 1);
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        sim.apply(Action::Enqueue {
            client: 0,
            mutation: MutationSpec::CreateEntry {
                id: "e1".into(),
                text: "hi".into(),
            },
        })
        .unwrap();
        sim.apply(Action::Freeze { client: 0 }).unwrap();
        sim.apply(Action::Crash { client: 0 }).unwrap();
        sim.apply(Action::Drop).unwrap(); // the push is lost
        sim.apply(Action::Restart { client: 0 }).unwrap();
        sim.settle();
        assert_eq!(sim.host.handler_calls(), 1);
        assert_eq!(sim.client(0).pending_count().unwrap(), 0);
        assert_eq!(sim.host.state(&entry_key("e1")).unwrap()["text"], "hi");
    }
}
