//! What must be true after every step. Each check reads the clients and the host;
//! none of them mutates anything except the high-water marks on Sim.
use crate::Sim;
use ahead_core::PushReceipt;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

type Check = fn(&mut Sim) -> Result<(), String>;

const CHECKS: &[(&str, Check)] = &[
    ("stamps never decrease", stamps_never_decrease),
    ("cursors never decrease", cursors_never_decrease),
    ("no mutation executes twice", no_mutation_executes_twice),
    ("no pending means converged", no_pending_means_converged),
    (
        "claims belong to subscriptions",
        claims_belong_to_subscriptions,
    ),
    ("record rows have a claim", record_rows_have_a_claim),
    ("receipts match server", receipts_match_server),
    (
        "batches wait for their checkpoints",
        batches_wait_for_their_checkpoints,
    ),
    (
        "batches settle in sequence order",
        batches_settle_in_sequence_order,
    ),
];

pub fn check(sim: &mut Sim) -> Result<(), String> {
    let mut failures = vec![];
    for (name, f) in CHECKS {
        if let Err(e) = f(sim) {
            failures.push(format!("{name}: {e}"));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("\n"))
    }
}

fn up(sim: &Sim) -> Vec<usize> {
    (0..sim.clients.len()).filter(|&i| sim.is_up(i)).collect()
}

fn stamps_never_decrease(sim: &mut Sim) -> Result<(), String> {
    let keys = sim.host.stamped_keys();
    for i in up(sim) {
        for key in &keys {
            let rows = sim
                .client(i)
                .read_sql(
                    "SELECT stamp FROM ahead_record WHERE model = ? AND identity = ?",
                    &[json!(key.model), json!(key.encoded_identity().unwrap())],
                )
                .map_err(|e| e.to_string())?;
            // A client with no local row for this key (never synced it, or dropped it
            // after unsubscribing / a delete) has nothing to compare: its absence is
            // not a stamp of 0. Purge the high-water mark rather than keep it around
            // for a row that is gone - the same reason `seen_cursors` is purged on
            // unsubscribe below: a lingering high mark for a row this client no
            // longer holds must not outlive the row, and would wrongly gate the mark
            // the row picks up if it reappears with a lower legitimate stamp (e.g.
            // after unsubscribe/resubscribe resets state).
            let Some(now) = rows.first().and_then(|r| r["stamp"].as_u64()) else {
                sim.seen_stamps.remove(&(i, key.encoded().unwrap()));
                continue;
            };
            let slot = sim
                .seen_stamps
                .entry((i, key.encoded().unwrap()))
                .or_insert(0);
            if now < *slot {
                return Err(format!(
                    "client {i} {} stamp {now} < {}",
                    key.encoded().unwrap(),
                    *slot
                ));
            }
            *slot = now;
        }
    }
    Ok(())
}

fn cursors_never_decrease(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        let subs = sim.client(i).subscriptions().map_err(|e| e.to_string())?;
        // Unsubscribing and resubscribing intentionally restarts a channel's cursor at
        // 0 (the claims were dropped, so the next sync is a fresh one): forget the
        // high-water mark for any channel the client is not currently subscribed to,
        // so that legitimate reset is not mistaken for a regression.
        let subscribed: BTreeSet<String> = subs.iter().map(|(c, _)| c.clone()).collect();
        sim.seen_cursors
            .retain(|(ci, channel), _| *ci != i || subscribed.contains(channel));
        for (channel, cursor) in subs {
            let slot = sim.seen_cursors.entry((i, channel.clone())).or_insert(0);
            if cursor < *slot {
                return Err(format!(
                    "client {i} channel {channel} cursor {cursor} < {}",
                    *slot
                ));
            }
            *slot = cursor;
        }
    }
    Ok(())
}

/// No mutation executes twice: the (clientId, batchSequence, ordinal) triples the
/// host recorded for every `handle` call are pairwise distinct across the whole run.
/// A retry that reached the handler again (instead of being answered from the stored
/// receipt) would duplicate one of these triples.
fn no_mutation_executes_twice(sim: &mut Sim) -> Result<(), String> {
    let mut seen = BTreeSet::new();
    for triple in sim.host.handler_invocations() {
        if !seen.insert(triple.clone()) {
            return Err(format!(
                "handler invoked twice for client {} batch {} ordinal {}",
                triple.0, triple.1, triple.2
            ));
        }
    }
    Ok(())
}

fn normalized(state: Option<Value>, model: &str) -> Option<Value> {
    state.map(|v| {
        let mut m = v.as_object().cloned().unwrap_or_default();
        if model == "Entry" {
            m.entry("note").or_insert(Value::Null);
        }
        Value::Object(m)
    })
}

fn no_pending_means_converged(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        if sim.client(i).pending_count().map_err(|e| e.to_string())? != 0 {
            continue;
        }
        for (channel, cursor) in sim.client(i).subscriptions().map_err(|e| e.to_string())? {
            if cursor != sim.host.head(&channel) {
                continue;
            }
            for key in sim.host.channel_records(&channel) {
                // A direct write shadows this (client, key) pair on purpose (N4/L4):
                // it never reaches the server, so no channel's invalidation stream
                // can ever agree with it. Exempt exactly this pair, not the whole
                // client or channel.
                if sim.direct_writes.contains(&(i, key.encoded().unwrap())) {
                    continue;
                }
                // A record's invalidation history on this channel can outlive its
                // membership (ServerChange can notify a channel outside a record's
                // real membership, and a record can move to another channel
                // entirely). Once `channel` is no longer among the record's real
                // members, being at its head proves nothing about this record - its
                // current content, if the client has any, may be supplied by another
                // channel the client is also subscribed to.
                if sim.host.has_membership(&key)
                    && !sim.host.membership(&key).iter().any(|m| m == &channel)
                {
                    continue;
                }
                // This channel's own invalidation for `key` can be behind the *last
                // content change's* stamp when a change was notified to a different
                // channel only (a `ServerChange` fault). Compare against
                // `content_stamp`, not the ever-growing shared per-key `stamp`
                // counter: a single change published to two member channels in the
                // same call allocates them consecutive stamps even though both carry
                // identical content, so gating on the raw counter would skip the
                // first of the two indefinitely. `content_stamp` is pinned to the
                // smallest stamp any one change's publishes produced, so every
                // channel that change actually reached compares as caught up.
                if sim
                    .host
                    .channel_stamp(&channel, &key)
                    .is_some_and(|stamp| stamp < sim.host.content_stamp(&key))
                {
                    continue;
                }
                let local = sim.client(i).read(&key).map_err(|e| e.to_string())?;
                let server = normalized(sim.host.state(&key), &key.model);
                sim.comparisons += 1;
                if local != server {
                    return Err(format!(
                        "client {i} at head of {channel} but {} is {local:?}, server has {server:?} (not converged)",
                        key.encoded().unwrap()
                    ));
                }
            }
        }
    }
    Ok(())
}

fn claims_belong_to_subscriptions(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        let subscribed: BTreeSet<String> = sim
            .client(i)
            .subscriptions()
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|(c, _)| c)
            .collect();
        let rows = sim
            .client(i)
            .read_sql("SELECT DISTINCT channel FROM ahead_claim", &[])
            .map_err(|e| e.to_string())?;
        for r in rows {
            let c = r["channel"].as_str().unwrap_or("").to_string();
            if !subscribed.contains(&c) {
                return Err(format!(
                    "client {i} has a claim on unsubscribed channel {c}"
                ));
            }
        }
    }
    Ok(())
}

fn record_rows_have_a_claim(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        for model in ["Entry", "Comment"] {
            let sql = format!(
                "SELECT r.id AS id FROM \"{model}\" r WHERE NOT EXISTS \
                 (SELECT 1 FROM ahead_claim c WHERE c.model = '{model}' \
                 AND c.identity = json_object('id', r.id)) \
                 AND NOT EXISTS (SELECT 1 FROM ahead_mutation_operation o \
                 WHERE o.model = '{model}' AND o.identity = json_object('id', r.id))"
            );
            let rows = sim
                .client(i)
                .read_sql(&sql, &[])
                .map_err(|e| e.to_string())?;
            if let Some(r) = rows.first() {
                return Err(format!(
                    "client {i} {model} {} has no claim and no pending mutation",
                    r["id"]
                ));
            }
        }
    }
    Ok(())
}

fn receipts_match_server(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        let id = sim.client(i).client_id().to_string();
        for (sequence, receipt) in sim.clients[i].receipts.clone() {
            if let Some(stored) = sim.host.receipt(&id, sequence) {
                let server = PushReceipt::decode(stored.as_bytes()).map_err(|e| e.to_string())?;
                if server != receipt {
                    return Err(format!(
                        "client {i} receipt {sequence} differs from the server's"
                    ));
                }
            }
        }
    }
    Ok(())
}

/// The sequences of the batches still in this client's queue.
fn queued_pushes(sim: &mut Sim, i: usize) -> Result<BTreeSet<u64>, String> {
    Ok(sim
        .client(i)
        .read_sql(
            "SELECT DISTINCT push FROM ahead_mutation WHERE push IS NOT NULL",
            &[],
        )
        .map_err(|e| e.to_string())?
        .iter()
        .filter_map(|r| r["push"].as_u64())
        .collect())
}

/// Whether the receipt for `sequence` rejected every mutation the batch carried.
/// Such a batch leaves the queue through `remove_rejected`, not settlement, so the
/// ordering and checkpoint rules do not apply to it.
fn fully_rejected(sim: &Sim, i: usize, sequence: u64) -> bool {
    let Some(ordinals) = sim.clients[i].pushes.get(&sequence) else {
        return false;
    };
    let Some(receipt) = sim.clients[i].receipts.get(&sequence) else {
        return false;
    };
    ordinals
        .iter()
        .all(|o| receipt.rejections.iter().any(|r| r.ordinal == *o))
}

/// A3: accepted optimism is removed only once every checkpoint the client could
/// await has been reached. A frozen batch that is no longer queued must have a
/// receipt, and for every checkpoint that receipt named on a channel the client was
/// subscribed to (and still is, in the same subscription generation) the local
/// cursor must have reached it. Checkpoints on channels the client was not
/// subscribed to when the receipt arrived are not awaited (A3's second sentence);
/// an unsubscribe settles what waited on that channel (D6), so a channel whose
/// generation changed since is exempt.
fn batches_wait_for_their_checkpoints(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        let queued = queued_pushes(sim, i)?;
        let subscriptions: BTreeMap<String, u64> = sim
            .client(i)
            .subscriptions()
            .map_err(|e| e.to_string())?
            .into_iter()
            .collect();
        for sequence in sim.clients[i].pushes.keys().copied().collect::<Vec<_>>() {
            if queued.contains(&sequence) || fully_rejected(sim, i, sequence) {
                continue;
            }
            if !sim.clients[i].receipts.contains_key(&sequence) {
                return Err(format!(
                    "client {i} batch {sequence} left the queue without a receipt"
                ));
            }
            let awaited = sim.clients[i]
                .awaited
                .get(&sequence)
                .cloned()
                .unwrap_or_default();
            for (channel, cursor, generation) in awaited {
                let current = sim.clients[i]
                    .generations
                    .get(&channel)
                    .copied()
                    .unwrap_or(0);
                let Some(local) = subscriptions.get(&channel) else {
                    continue;
                };
                if current == generation && *local < cursor {
                    return Err(format!(
                        "client {i} batch {sequence} settled while {channel} is at cursor {local}, checkpoint {cursor}"
                    ));
                }
            }
        }
    }
    Ok(())
}

/// A5: batches settle in sequence order. While any batch is still queued, no batch
/// with a higher sequence may have settled; the only way a later batch leaves the
/// queue first is by having every mutation rejected.
fn batches_settle_in_sequence_order(sim: &mut Sim) -> Result<(), String> {
    for i in up(sim) {
        let queued = queued_pushes(sim, i)?;
        let Some(earliest) = queued.iter().next().copied() else {
            continue;
        };
        for sequence in sim.clients[i].pushes.keys().copied().collect::<Vec<_>>() {
            if sequence <= earliest || queued.contains(&sequence) {
                continue;
            }
            if !fully_rejected(sim, i, sequence) {
                return Err(format!(
                    "client {i} batch {sequence} settled while batch {earliest} is still pending"
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::{Action, MutationSpec, Sim};

    #[test]
    fn invariants_hold_through_a_plain_round_trip() {
        let mut sim = Sim::new(3, 2);
        for i in 0..2 {
            sim.apply(Action::Subscribe {
                client: i,
                channel: "a".into(),
            })
            .unwrap();
        }
        sim.check().unwrap();
        sim.apply(Action::Enqueue {
            client: 0,
            mutation: MutationSpec::CreateEntry {
                id: "e1".into(),
                text: "hi".into(),
            },
        })
        .unwrap();
        sim.check().unwrap();
        sim.settle();
        sim.check().unwrap();
        assert_eq!(
            sim.read_text(1, &crate::schema::entry_key("e1")),
            Some("hi".into())
        );
    }

    #[test]
    fn a_violated_invariant_is_reported() {
        let mut sim = Sim::new(4, 1);
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
        sim.settle();
        // Corrupt the server behind the client's back: content differs at head.
        sim.host.set_state(
            &crate::schema::entry_key("e1"),
            Some(serde_json::json!({"id":"e1","text":"other","note":null})),
        );
        let err = sim.check().unwrap_err();
        assert!(err.contains("converged"), "{err}");
    }

    /// Run `sql` against a crashed client's file behind the engine's back, then
    /// restart it: the way these tests forge a state the engine never produces.
    fn corrupt(sim: &mut Sim, client: usize, sql: &str) {
        use ahead_client::store::ClientStore;
        sim.apply(Action::Crash { client }).unwrap();
        let mut store = ahead_sqlite::SqliteStore::open(&sim.clients[client].path).unwrap();
        store.execute(sql, &[]).unwrap();
        drop(store);
        sim.apply(Action::Restart { client }).unwrap();
    }

    fn frozen_batch(sim: &mut Sim, id: &str) {
        sim.apply(Action::Enqueue {
            client: 0,
            mutation: MutationSpec::CreateEntry {
                id: id.into(),
                text: "hi".into(),
            },
        })
        .unwrap();
        sim.apply(Action::Freeze { client: 0 }).unwrap();
    }

    #[test]
    fn a_batch_settled_before_its_checkpoint_is_reported() {
        let mut sim = Sim::new(5, 1);
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        frozen_batch(&mut sim, "e1");
        sim.apply(Action::Deliver).unwrap(); // push reaches the server
        sim.apply(Action::Deliver).unwrap(); // receipt names a checkpoint on `a`
        sim.check().unwrap();
        assert_eq!(
            sim.clients[0].awaited[&1].len(),
            1,
            "the receipt named channel a"
        );
        // Forge an early settlement: the mutation is gone but a's cursor is still 0.
        corrupt(&mut sim, 0, "DELETE FROM ahead_mutation");
        let err = sim.check().unwrap_err();
        assert!(
            err.contains("batches wait for their checkpoints")
                && err.contains("batch 1 settled while a is at cursor 0"),
            "{err}"
        );
    }

    #[test]
    fn a_batch_gone_without_a_receipt_is_reported() {
        let mut sim = Sim::new(6, 1);
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        frozen_batch(&mut sim, "e1");
        sim.check().unwrap();
        corrupt(&mut sim, 0, "DELETE FROM ahead_mutation");
        let err = sim.check().unwrap_err();
        assert!(
            err.contains("batch 1 left the queue without a receipt"),
            "{err}"
        );
    }

    #[test]
    fn a_later_batch_settling_first_is_reported() {
        let mut sim = Sim::new(7, 1);
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        frozen_batch(&mut sim, "e1");
        sim.apply(Action::Deliver).unwrap();
        sim.apply(Action::Deliver).unwrap(); // batch 1 acknowledged, waiting for its page
        frozen_batch(&mut sim, "e2");
        sim.apply(Action::Deliver).unwrap();
        sim.apply(Action::Deliver).unwrap(); // batch 2 acknowledged behind it
        sim.check().unwrap();
        assert_eq!(
            sim.clients[0].pushes.keys().copied().collect::<Vec<_>>(),
            [1, 2]
        );
        corrupt(&mut sim, 0, "DELETE FROM ahead_mutation WHERE push = 2");
        let err = sim.check().unwrap_err();
        assert!(
            err.contains("batches settle in sequence order")
                && err.contains("batch 2 settled while batch 1 is still pending"),
            "{err}"
        );
    }

    #[test]
    fn an_unsubscribe_settling_a_waiting_batch_is_not_a_violation() {
        let mut sim = Sim::new(8, 1);
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        frozen_batch(&mut sim, "e1");
        sim.apply(Action::Deliver).unwrap();
        sim.apply(Action::Deliver).unwrap();
        assert_eq!(sim.client(0).pending_count().unwrap(), 1);
        sim.apply(Action::Unsubscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        assert_eq!(
            sim.client(0).pending_count().unwrap(),
            0,
            "D6 settles the batch"
        );
        sim.check().unwrap();
        sim.apply(Action::Subscribe {
            client: 0,
            channel: "a".into(),
        })
        .unwrap();
        // The cursor restarted at 0, below the old checkpoint, in a new generation.
        sim.check().unwrap();
    }
}
