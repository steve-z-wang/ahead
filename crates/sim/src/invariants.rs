//! What must be true after every step. Each check reads the clients and the host;
//! none of them mutates anything except the high-water marks on Sim.
use crate::Sim;
use otter_core::PushReceipt;
use serde_json::{Value, json};
use std::collections::BTreeSet;

type Check = fn(&mut Sim) -> Result<(), String>;

const CHECKS: &[(&str, Check)] = &[
    ("stamps never decrease", stamps_never_decrease),
    ("cursors never decrease", cursors_never_decrease),
    ("handler calls match outcomes", handler_calls_match_outcomes),
    ("no pending means converged", no_pending_means_converged),
    (
        "claims belong to subscriptions",
        claims_belong_to_subscriptions,
    ),
    ("record rows have a claim", record_rows_have_a_claim),
    ("receipts match server", receipts_match_server),
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
                    "SELECT stamp FROM otter_record WHERE model = ? AND identity = ?",
                    &[json!(key.model), json!(key.encoded_identity().unwrap())],
                )
                .map_err(|e| e.to_string())?;
            // A client with no local row for this key (never synced it, or dropped it
            // after unsubscribing / a delete) has nothing to compare: its absence is
            // not a stamp of 0, so leave the high-water mark untouched until the row
            // reappears. Purge the stale entry too - the same reason `seen_cursors`
            // is purged on unsubscribe below: a lingering high mark for a row this
            // client no longer holds must not outlive the row.
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

fn handler_calls_match_outcomes(sim: &mut Sim) -> Result<(), String> {
    let calls = sim.host.handler_calls();
    let outcomes = sim.host.accepted() + sim.host.rejected() + sim.host.failed();
    if calls != outcomes {
        return Err(format!("{calls} handler calls, {outcomes} outcomes"));
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
            .read_sql("SELECT DISTINCT channel FROM otter_claim", &[])
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
                 (SELECT 1 FROM otter_claim c WHERE c.model = '{model}' \
                 AND c.identity = json_object('id', r.id)) \
                 AND NOT EXISTS (SELECT 1 FROM otter_mutation_operation o \
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
}
