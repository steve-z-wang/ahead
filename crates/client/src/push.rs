//! Freeze pushes from queued rows, record receipts, settle the accepted prefix.
use crate::engine::Engine;
use crate::store::ClientStore;
use crate::{Mutation, Operation};
use otter_core::{RecordKey, Rejection, Result};
use serde_json::{Value, json};
use std::collections::BTreeMap;

fn all_ops(m: &Mutation) -> impl Iterator<Item = &Operation> {
    m.operations.iter().chain(&m.companion).chain(&m.effects)
}

impl<S: ClientStore> Engine<'_, S> {
    /// Settle the accepted prefix of frozen pushes. Task 8 fills this in.
    pub fn settle(&mut self) -> Result<()> {
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
