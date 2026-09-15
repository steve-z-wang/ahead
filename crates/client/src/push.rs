//! Freeze pushes from queued rows, record receipts, settle the accepted prefix.
use crate::engine::Engine;
use crate::queue::Queued;
use crate::store::ClientStore;
use crate::{Mutation, Operation, OperationKind, mutate::apply_to_row};
use ahead_core::{
    ChannelCheckpoint, PushReceipt, PushRequest, RecordKey, Rejection, Result, canonical_json,
    invalid,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

const MAX_MUTATIONS: usize = 20;

/// A checkpoint row on this channel marks a batch whose receipt named nothing the
/// client can await. Its cursor is 0, which every channel has reached, so the
/// ordered walk settles the batch as soon as every earlier batch has settled
/// (guarantee A5) and never before. Without the row the batch would read as in
/// flight and be sent again.
pub(crate) const NOTHING_AWAITED: &str = "";

fn nothing_awaited() -> ChannelCheckpoint {
    ChannelCheckpoint {
        channel: NOTHING_AWAITED.into(),
        cursor: 0,
    }
}

fn keys_of<'a>(
    schema: &ahead_core::Schema,
    ops: impl Iterator<Item = &'a Operation>,
) -> Result<BTreeSet<String>> {
    ops.map(|op| schema.record_key(&op.model, &op.identity)?.encoded())
        .collect()
}
fn all_ops(m: &Mutation) -> impl Iterator<Item = &Operation> {
    m.operations.iter().chain(&m.companion).chain(&m.effects)
}

impl<S: ClientStore> Engine<'_, S> {
    fn client_id(&mut self) -> Result<String> {
        Ok(self
            .scalar("SELECT client_id FROM ahead_client", &[])?
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default())
    }
    fn request_json(&mut self, push: u64, mutations: &[Queued]) -> Result<Value> {
        let acts: Vec<Value> = mutations
            .iter()
            .map(|q| json!({"ordinal":q.ordinal,"name":q.mutation.name,"version":q.mutation.version,"operations":q.mutation.operations}))
            .collect();
        Ok(json!({"clientId":self.client_id()?,"batchSequence":push,"mutations":acts}))
    }
    pub fn encode_push(&mut self, push: u64) -> Result<Vec<u8>> {
        let mutations: Vec<Queued> = self
            .queued()?
            .into_iter()
            .filter(|q| q.push == Some(push))
            .collect();
        let request = self.request_json(push, &mutations)?;
        PushRequest::decode(canonical_json(&request)?.as_bytes())?.encode()
    }
    /// The push that was sent and not yet acknowledged, if any.
    fn in_flight(&mut self) -> Result<Option<u64>> {
        for push in self.pushes()? {
            if self.checkpoints(push)?.is_empty() {
                return Ok(Some(push));
            }
        }
        Ok(None)
    }
    pub fn freeze(&mut self, max_bytes: usize) -> Result<Option<Vec<u8>>> {
        if max_bytes == 0 {
            return Ok(None);
        }
        if let Some(push) = self.in_flight()? {
            return Ok(Some(self.encode_push(push)?));
        }
        let queue = self.queued()?;
        let blocked_keys: BTreeSet<String> = self
            .prerequisite_keys()?
            .into_iter()
            .map(|(k, _)| k)
            .collect();
        let unsent: BTreeSet<u64> = queue
            .iter()
            .filter(|q| q.push.is_none())
            .map(|q| q.ordinal)
            .collect();
        let mut selected: Vec<Queued> = vec![];
        let mut chosen = BTreeSet::new();
        let next_push = self
            .scalar("SELECT next_push FROM ahead_client", &[])?
            .map(|v| crate::engine::as_u64(&v))
            .transpose()?
            .unwrap_or(1);
        for q in queue.iter().filter(|q| q.push.is_none()) {
            if q.mutation
                .prerequisites
                .iter()
                .any(|k| blocked_keys.contains(k))
            {
                continue;
            }
            let blocked = q
                .mutation
                .lifecycle_dependencies
                .iter()
                .any(|d| unsent.contains(d))
                || q.mutation
                    .sequence_dependencies
                    .iter()
                    .any(|d| unsent.contains(d) && !chosen.contains(d));
            if blocked {
                continue;
            }
            if !selected.is_empty() {
                let mut candidate = selected.clone();
                candidate.push(q.clone());
                if canonical_json(&self.request_json(next_push, &candidate)?)?.len() > max_bytes {
                    continue;
                }
            }
            chosen.insert(q.ordinal);
            selected.push(q.clone());
            if selected.len() == MAX_MUTATIONS {
                break;
            }
        }
        if selected.is_empty() {
            return Ok(None);
        }
        let push = self.allocate_push()?;
        let ordinals: Vec<u64> = selected.iter().map(|q| q.ordinal).collect();
        self.assign_push(&ordinals, push)?;
        Ok(Some(self.encode_push(push)?))
    }
    pub fn acknowledge(&mut self, push: u64, receipt: &PushReceipt) -> Result<()> {
        let mutations: Vec<Queued> = self
            .queued()?
            .into_iter()
            .filter(|q| q.push == Some(push))
            .collect();
        let existing = self.checkpoints(push)?;
        if !existing.is_empty() {
            let awaited = self.awaitable(&receipt.required_checkpoints)?;
            let same = if existing == [nothing_awaited()] {
                awaited.is_empty()
            } else {
                awaited == existing
            };
            if !same {
                return Err(invalid("receipt changed"));
            }
            return Ok(());
        }
        if mutations.is_empty() {
            return Err(invalid("unknown batch receipt"));
        }
        let ordinals: BTreeSet<u64> = mutations.iter().map(|q| q.ordinal).collect();
        if receipt
            .rejections
            .iter()
            .any(|r| !ordinals.contains(&r.ordinal))
        {
            return Err(invalid("rejection ordinal not in batch"));
        }
        self.remove_rejected(&receipt.rejections)?;
        let remaining = self.queued()?.into_iter().any(|q| q.push == Some(push));
        if !remaining {
            return Ok(());
        }
        let awaited = self.awaitable(&receipt.required_checkpoints)?;
        if awaited.is_empty() {
            // Nothing to wait for, but the batch still settles in sequence order
            // behind any earlier batch that is waiting (guarantee A5).
            self.insert_checkpoints(push, &[nothing_awaited()])?;
        } else {
            self.insert_checkpoints(push, &awaited)?;
        }
        self.settle()
    }
    /// The checkpoints this client can ever meet: only a subscribed channel has a
    /// cursor that advances, so a checkpoint on any other channel cannot be awaited
    /// and is dropped, which settles the push as if the receipt had not named it.
    fn awaitable(&mut self, checkpoints: &[ChannelCheckpoint]) -> Result<Vec<ChannelCheckpoint>> {
        let mut awaited = vec![];
        for cp in checkpoints {
            if self.cursor(&cp.channel)?.is_some() {
                awaited.push(cp.clone());
            }
        }
        awaited.sort_by(|a, b| a.channel.cmp(&b.channel));
        Ok(awaited)
    }
    /// Settle the accepted prefix of frozen pushes.
    pub fn settle(&mut self) -> Result<()> {
        self.settle_satisfied(&BTreeSet::new())
    }
    /// `satisfied` names acknowledged pushes whose last checkpoint row was just
    /// deleted (an unsubscribe); without it they would read as in flight forever.
    pub fn settle_satisfied(&mut self, satisfied: &BTreeSet<u64>) -> Result<()> {
        loop {
            let Some(push) = self.pushes()?.into_iter().next() else {
                return Ok(());
            };
            let checkpoints = self.checkpoints(push)?;
            if checkpoints.is_empty() && !satisfied.contains(&push) {
                return Ok(()); // in flight; nothing later may settle first
            }
            for cp in &checkpoints {
                if self.cursor(&cp.channel)?.unwrap_or(0) < cp.cursor {
                    return Ok(());
                }
            }
            self.settle_push(push)?;
        }
    }
    pub fn settle_push(&mut self, push: u64) -> Result<()> {
        let schema = self.schema;
        let mutations: Vec<Queued> = self
            .queued()?
            .into_iter()
            .filter(|q| q.push == Some(push))
            .collect();
        let mut wire_rows = BTreeSet::new();
        let mut affected: BTreeMap<String, RecordKey> = BTreeMap::new();
        for q in &mutations {
            wire_rows.extend(keys_of(schema, q.mutation.operations.iter())?);
            for op in all_ops(&q.mutation) {
                let key = schema.record_key(&op.model, &op.identity)?;
                affected.insert(key.encoded()?, key);
            }
        }
        for q in &mutations {
            let mut local_ops = q.mutation.companion.clone();
            for op in &q.mutation.companion {
                if op.op == OperationKind::Delete {
                    let key = schema.record_key(&op.model, &op.identity)?;
                    if !wire_rows.contains(&key.encoded()?) {
                        for child in self.descendants(&key)? {
                            local_ops.push(Operation {
                                model: child.model,
                                identity: child.identity,
                                op: OperationKind::Delete,
                                values: None,
                            });
                        }
                    }
                }
            }
            for op in &local_ops {
                let key = schema.record_key(&op.model, &op.identity)?;
                if wire_rows.contains(&key.encoded()?) {
                    continue;
                }
                let mut truth = self.before_get(&key)?;
                if apply_to_row(&mut truth, op).is_ok() {
                    self.before_set(&key, truth.as_ref())?;
                }
                affected.insert(key.encoded()?, key);
            }
        }
        let ordinals: Vec<u64> = mutations.iter().map(|q| q.ordinal).collect();
        self.delete_mutations(&ordinals)?;
        self.delete_checkpoints(push)?;
        for key in affected.values() {
            self.rebuild(key)?;
        }
        Ok(())
    }
    /// Drop rejected mutations and everything whose lifecycle depended on them,
    /// keep a durable record of why, and rebuild the rows they touched.
    pub fn remove_rejected(&mut self, rejections: &[Rejection]) -> Result<()> {
        let schema = self.schema;
        let queue = self.queued()?;
        let mut rejected: BTreeMap<u64, String> = rejections
            .iter()
            .map(|r| (r.ordinal, r.code.clone()))
            .collect();
        loop {
            let more: Vec<u64> = queue
                .iter()
                .filter(|q| {
                    !rejected.contains_key(&q.ordinal)
                        && q.mutation
                            .lifecycle_dependencies
                            .iter()
                            .any(|d| rejected.contains_key(d))
                })
                .map(|q| q.ordinal)
                .collect();
            if more.is_empty() {
                break;
            }
            for id in more {
                rejected.insert(id, "dependency.rejected".into());
            }
        }
        let mut affected: BTreeMap<String, RecordKey> = BTreeMap::new();
        for q in queue.iter().filter(|q| rejected.contains_key(&q.ordinal)) {
            let code = &rejected[&q.ordinal];
            for op in all_ops(&q.mutation) {
                let key = schema.record_key(&op.model, &op.identity)?;
                affected.insert(key.encoded()?, key);
            }
            let records: Vec<Value> = all_ops(&q.mutation)
                .map(|op| json!({"model":op.model,"identity":op.identity}))
                .collect();
            let detail =
                json!({"ordinal":q.ordinal,"code":code,"mutation":q.mutation,"records":records});
            self.insert_rejection(q.ordinal, &q.mutation.name, code, &detail)?;
        }
        let ordinals: Vec<u64> = rejected.keys().copied().collect();
        self.delete_mutations(&ordinals)?;
        for key in affected.values() {
            self.rebuild(key)?;
        }
        Ok(())
    }
}
