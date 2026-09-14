//! Pending mutations, their operations, dependencies, prerequisites, push checkpoints and rejections.
use crate::engine::{Engine, as_u64};
use crate::store::ClientStore;
use crate::{Mutation, Operation, OperationKind};
use savoia_core::{ChannelCheckpoint, RecordKey, Rejection, Result, invalid};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OpKind {
    Wire,
    Companion,
    Effect,
}
#[derive(Clone, Debug)]
pub struct QueuedOp {
    pub ordinal: u64,
    pub position: u64,
    pub kind: OpKind,
    pub op: Operation,
}
#[derive(Clone, Debug)]
pub struct Queued {
    pub ordinal: u64,
    pub push: Option<u64>,
    pub mutation: Mutation,
}

fn text(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}
fn op_text(op: OperationKind) -> &'static str {
    match op {
        OperationKind::Create => "create",
        OperationKind::Update => "update",
        OperationKind::Delete => "delete",
    }
}
fn kind_text(kind: OpKind) -> &'static str {
    match kind {
        OpKind::Wire => "wire",
        OpKind::Companion => "companion",
        OpKind::Effect => "effect",
    }
}
fn decode_op(row: &[Value]) -> Result<QueuedOp> {
    // columns: ordinal, position, kind, model, identity, op, values
    let kind = match row[2].as_str() {
        Some("wire") => OpKind::Wire,
        Some("companion") => OpKind::Companion,
        Some("effect") => OpKind::Effect,
        _ => return Err(invalid("unknown operation kind")),
    };
    let op = match row[5].as_str() {
        Some("create") => OperationKind::Create,
        Some("update") => OperationKind::Update,
        Some("delete") => OperationKind::Delete,
        _ => return Err(invalid("unknown operation")),
    };
    Ok(QueuedOp {
        ordinal: as_u64(&row[0])?,
        position: as_u64(&row[1])?,
        kind,
        op: Operation {
            model: text(&row[3]),
            op,
            identity: serde_json::from_str(row[4].as_str().unwrap_or("null"))?,
            values: row[6].as_str().map(serde_json::from_str).transpose()?,
        },
    })
}

impl<S: ClientStore> Engine<'_, S> {
    fn bump(&mut self, column: &str) -> Result<u64> {
        let current = self
            .scalar(&format!("SELECT {column} FROM ahead_client"), &[])?
            .ok_or_else(|| invalid("client row missing"))?;
        let value = as_u64(&current)?;
        let next = value
            .checked_add(1)
            .filter(|v| *v <= savoia_core::MAX_SAFE_INTEGER)
            .ok_or_else(|| invalid("counter exhausted"))?;
        self.exec(
            "ahead_client",
            &format!("UPDATE ahead_client SET {column}=?"),
            &[json!(next)],
        )?;
        Ok(value)
    }
    pub fn allocate_ordinal(&mut self) -> Result<u64> {
        self.bump("next_ordinal")
    }
    pub fn allocate_push(&mut self) -> Result<u64> {
        self.bump("next_push")
    }
    fn insert_op(
        &mut self,
        ordinal: u64,
        position: u64,
        kind: OpKind,
        op: &Operation,
    ) -> Result<()> {
        let key = self.schema.record_key(&op.model, &op.identity)?;
        self.exec(
            "ahead_mutation_operation",
            "INSERT INTO ahead_mutation_operation (ordinal, position, kind, model, identity, op, \"values\") VALUES (?,?,?,?,?,?,?)",
            &[
                json!(ordinal),
                json!(position),
                json!(kind_text(kind)),
                json!(op.model),
                json!(key.encoded_identity()?),
                json!(op_text(op.op)),
                match &op.values {
                    Some(v) => json!(serde_json::to_string(v)?),
                    None => Value::Null,
                },
            ],
        )?;
        Ok(())
    }
    pub fn insert_mutation(&mut self, ordinal: u64, mutation: &Mutation) -> Result<()> {
        self.exec(
            "ahead_mutation",
            "INSERT INTO ahead_mutation (ordinal, name, version, push) VALUES (?,?,?,NULL)",
            &[
                json!(ordinal),
                json!(mutation.name),
                json!(mutation.version),
            ],
        )?;
        let mut position = 0;
        for (kind, ops) in [
            (OpKind::Wire, &mutation.operations),
            (OpKind::Companion, &mutation.companion),
            (OpKind::Effect, &mutation.effects),
        ] {
            for op in ops {
                self.insert_op(ordinal, position, kind, op)?;
                position += 1;
            }
        }
        for (kind, deps) in [
            ("lifecycle", &mutation.lifecycle_dependencies),
            ("sequence", &mutation.sequence_dependencies),
        ] {
            for dep in deps {
                self.exec("ahead_mutation_dependency", "INSERT OR IGNORE INTO ahead_mutation_dependency (ordinal, depends_on, kind) VALUES (?,?,?)", &[json!(ordinal), json!(dep), json!(kind)])?;
            }
        }
        for key in &mutation.prerequisites {
            self.exec("ahead_mutation_prerequisite", "INSERT OR IGNORE INTO ahead_mutation_prerequisite (ordinal, key, error) VALUES (?,?,NULL)", &[json!(ordinal), json!(key)])?;
        }
        Ok(())
    }
    pub fn add_effect(&mut self, ordinal: u64, op: &Operation) -> Result<()> {
        let next = self.scalar(
            "SELECT COALESCE(MAX(position), -1) + 1 FROM ahead_mutation_operation WHERE ordinal=?",
            &[json!(ordinal)],
        )?;
        let position = as_u64(&next.unwrap_or(json!(0)))?;
        self.insert_op(ordinal, position, OpKind::Effect, op)
    }
    fn ops_by_ordinal(
        &mut self,
        filter: &str,
        params: &[Value],
    ) -> Result<BTreeMap<u64, Vec<QueuedOp>>> {
        let rows = self.rows(&format!("SELECT ordinal, position, kind, model, identity, op, \"values\" FROM ahead_mutation_operation {filter} ORDER BY ordinal, position"), params)?;
        let mut result: BTreeMap<u64, Vec<QueuedOp>> = BTreeMap::new();
        for row in &rows.rows {
            let op = decode_op(row)?;
            result.entry(op.ordinal).or_default().push(op);
        }
        Ok(result)
    }
    fn queued_where(&mut self, filter: &str, params: &[Value]) -> Result<Vec<Queued>> {
        let mutations = self.rows(
            &format!(
                "SELECT ordinal, name, version, push FROM ahead_mutation {filter} ORDER BY ordinal"
            ),
            params,
        )?;
        if mutations.rows.is_empty() {
            return Ok(vec![]);
        }
        let ops = self.ops_by_ordinal(filter, params)?;
        let deps = self.rows(
            &format!(
                "SELECT ordinal, depends_on, kind FROM ahead_mutation_dependency {filter} ORDER BY ordinal, depends_on"
            ),
            params,
        )?;
        let prerequisites = self.rows(
            &format!(
                "SELECT ordinal, key FROM ahead_mutation_prerequisite {filter} ORDER BY ordinal, key"
            ),
            params,
        )?;
        let mut result = vec![];
        for row in &mutations.rows {
            let ordinal = as_u64(&row[0])?;
            let mut mutation = Mutation::new(text(&row[1]), vec![]);
            mutation.version = as_u64(&row[2])?;
            for op in ops.get(&ordinal).into_iter().flatten() {
                match op.kind {
                    OpKind::Wire => mutation.operations.push(op.op.clone()),
                    OpKind::Companion => mutation.companion.push(op.op.clone()),
                    OpKind::Effect => mutation.effects.push(op.op.clone()),
                }
            }
            for dep in deps
                .rows
                .iter()
                .filter(|d| as_u64(&d[0]).ok() == Some(ordinal))
            {
                let target = as_u64(&dep[1])?;
                if dep[2] == "lifecycle" {
                    mutation.lifecycle_dependencies.push(target);
                } else {
                    mutation.sequence_dependencies.push(target);
                }
            }
            for p in prerequisites
                .rows
                .iter()
                .filter(|p| as_u64(&p[0]).ok() == Some(ordinal))
            {
                mutation.prerequisites.push(text(&p[1]));
            }
            result.push(Queued {
                ordinal,
                push: row[3].as_u64(),
                mutation,
            });
        }
        Ok(result)
    }
    pub fn queued(&mut self) -> Result<Vec<Queued>> {
        self.queued_where("", &[])
    }
    pub fn queued_one(&mut self, ordinal: u64) -> Result<Option<Queued>> {
        Ok(self
            .queued_where("WHERE ordinal=?", &[json!(ordinal)])?
            .into_iter()
            .next())
    }
    pub fn ops_for(&mut self, key: &RecordKey) -> Result<Vec<QueuedOp>> {
        Ok(self
            .ops_by_ordinal(
                "WHERE model=? AND identity=?",
                &[json!(key.model), json!(key.encoded_identity()?)],
            )?
            .into_values()
            .flatten()
            .collect())
    }
    pub fn dirty(&mut self, key: &RecordKey) -> Result<bool> {
        Ok(self
            .scalar(
                "SELECT 1 FROM ahead_mutation_operation WHERE model=? AND identity=? LIMIT 1",
                &[json!(key.model), json!(key.encoded_identity()?)],
            )?
            .is_some())
    }
    pub fn delete_mutations(&mut self, ordinals: &[u64]) -> Result<()> {
        for ordinal in ordinals {
            self.exec(
                "ahead_mutation",
                "DELETE FROM ahead_mutation WHERE ordinal=?",
                &[json!(ordinal)],
            )?;
        }
        for table in [
            "ahead_mutation_operation",
            "ahead_mutation_dependency",
            "ahead_mutation_prerequisite",
        ] {
            self.changed.insert(table.into());
        }
        Ok(())
    }
    pub fn assign_push(&mut self, ordinals: &[u64], push: u64) -> Result<()> {
        for ordinal in ordinals {
            self.exec(
                "ahead_mutation",
                "UPDATE ahead_mutation SET push=? WHERE ordinal=?",
                &[json!(push), json!(ordinal)],
            )?;
        }
        Ok(())
    }
    pub fn pushes(&mut self) -> Result<Vec<u64>> {
        let rows = self.rows("SELECT push FROM ahead_mutation WHERE push IS NOT NULL UNION SELECT push FROM ahead_push_checkpoint ORDER BY 1", &[])?;
        rows.rows.iter().map(|r| as_u64(&r[0])).collect()
    }
    pub fn prerequisite_keys(&mut self) -> Result<Vec<(String, Option<String>)>> {
        let rows = self.rows(
            "SELECT key, MAX(error) FROM ahead_mutation_prerequisite GROUP BY key ORDER BY key",
            &[],
        )?;
        Ok(rows
            .rows
            .into_iter()
            .map(|r| (text(&r[0]), r[1].as_str().map(str::to_owned)))
            .collect())
    }
    pub fn resolve_prerequisite(&mut self, key: &str) -> Result<usize> {
        self.exec(
            "ahead_mutation_prerequisite",
            "DELETE FROM ahead_mutation_prerequisite WHERE key=?",
            &[json!(key)],
        )
    }
    pub fn fail_prerequisite(&mut self, key: &str, error: &str) -> Result<usize> {
        self.exec(
            "ahead_mutation_prerequisite",
            "UPDATE ahead_mutation_prerequisite SET error=? WHERE key=?",
            &[json!(error), json!(key)],
        )
    }
    pub fn reset_prerequisite(&mut self, key: &str) -> Result<usize> {
        self.exec(
            "ahead_mutation_prerequisite",
            "UPDATE ahead_mutation_prerequisite SET error=NULL WHERE key=?",
            &[json!(key)],
        )
    }
    pub fn checkpoints(&mut self, push: u64) -> Result<Vec<ChannelCheckpoint>> {
        let rows = self.rows(
            "SELECT channel, cursor FROM ahead_push_checkpoint WHERE push=? ORDER BY channel",
            &[json!(push)],
        )?;
        rows.rows
            .iter()
            .map(|r| {
                Ok(ChannelCheckpoint {
                    channel: text(&r[0]),
                    cursor: as_u64(&r[1])?,
                })
            })
            .collect()
    }
    pub fn insert_checkpoints(
        &mut self,
        push: u64,
        checkpoints: &[ChannelCheckpoint],
    ) -> Result<()> {
        for cp in checkpoints {
            self.exec(
                "ahead_push_checkpoint",
                "INSERT INTO ahead_push_checkpoint (push, channel, cursor) VALUES (?,?,?)",
                &[json!(push), json!(cp.channel), json!(cp.cursor)],
            )?;
        }
        Ok(())
    }
    pub fn delete_checkpoints(&mut self, push: u64) -> Result<()> {
        self.exec(
            "ahead_push_checkpoint",
            "DELETE FROM ahead_push_checkpoint WHERE push=?",
            &[json!(push)],
        )?;
        Ok(())
    }
    /// The pushes waiting on `channel`, taken before its checkpoint rows are deleted.
    pub fn pushes_awaiting(&mut self, channel: &str) -> Result<BTreeSet<u64>> {
        let rows = self.rows(
            "SELECT DISTINCT push FROM ahead_push_checkpoint WHERE channel=?",
            &[json!(channel)],
        )?;
        rows.rows.iter().map(|r| as_u64(&r[0])).collect()
    }
    pub fn delete_channel_checkpoints(&mut self, channel: &str) -> Result<()> {
        self.exec(
            "ahead_push_checkpoint",
            "DELETE FROM ahead_push_checkpoint WHERE channel=?",
            &[json!(channel)],
        )?;
        Ok(())
    }
    pub fn checkpoint_channels(&mut self) -> Result<BTreeSet<String>> {
        let rows = self.rows("SELECT DISTINCT channel FROM ahead_push_checkpoint", &[])?;
        Ok(rows.rows.iter().map(|r| text(&r[0])).collect())
    }
    pub fn insert_rejection(
        &mut self,
        ordinal: u64,
        name: &str,
        code: &str,
        detail: &Value,
    ) -> Result<()> {
        self.exec(
            "ahead_rejection",
            "INSERT OR REPLACE INTO ahead_rejection (ordinal, name, code, detail) VALUES (?,?,?,?)",
            &[
                json!(ordinal),
                json!(name),
                json!(code),
                json!(serde_json::to_string(detail)?),
            ],
        )?;
        Ok(())
    }
    pub fn rejections(&mut self) -> Result<Vec<Rejection>> {
        let rows = self.rows(
            "SELECT ordinal, code FROM ahead_rejection ORDER BY ordinal",
            &[],
        )?;
        rows.rows
            .iter()
            .map(|r| {
                Ok(Rejection {
                    ordinal: as_u64(&r[0])?,
                    code: text(&r[1]),
                })
            })
            .collect()
    }
    pub fn rejection_details(&mut self) -> Result<Vec<Value>> {
        let rows = self.rows("SELECT detail FROM ahead_rejection ORDER BY ordinal", &[])?;
        rows.rows
            .iter()
            .map(|r| Ok(serde_json::from_str(r[0].as_str().unwrap_or("null"))?))
            .collect()
    }
    pub fn delete_rejection(&mut self, ordinal: u64) -> Result<()> {
        self.exec(
            "ahead_rejection",
            "DELETE FROM ahead_rejection WHERE ordinal=?",
            &[json!(ordinal)],
        )?;
        Ok(())
    }
}
