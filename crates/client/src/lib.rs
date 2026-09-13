//! Client engine over per-model SQLite tables. No state lives in memory between calls.
pub mod connection;
pub mod ddl;
mod downlink;
pub mod engine;
pub mod ledger;
mod mutate;
mod policies;
mod push;
pub mod query;
pub mod queue;
pub mod rows;
pub mod store;
pub mod transport;

pub use connection::*;
pub use otter_core::*;
pub use query::{Direction, QueryOrder, QuerySpec};
pub use store::*;
pub use transport::*;

use engine::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::{self, Receiver, Sender};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OperationKind {
    Create,
    Update,
    Delete,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Operation {
    pub model: String,
    pub op: OperationKind,
    pub identity: Value,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub values: Option<Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mutation {
    pub name: String,
    #[serde(default = "one")]
    pub version: u64,
    pub operations: Vec<Operation>,
    #[serde(default)]
    pub companion: Vec<Operation>,
    #[serde(default)]
    pub effects: Vec<Operation>,
    #[serde(default)]
    pub prerequisites: Vec<String>,
    #[serde(default)]
    pub lifecycle_dependencies: Vec<u64>,
    #[serde(default)]
    pub sequence_dependencies: Vec<u64>,
}
fn one() -> u64 {
    1
}
impl Mutation {
    pub fn new(name: impl Into<String>, operations: Vec<Operation>) -> Self {
        Self {
            name: name.into(),
            version: 1,
            operations,
            companion: vec![],
            effects: vec![],
            prerequisites: vec![],
            lifecycle_dependencies: vec![],
            sequence_dependencies: vec![],
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Readiness {
    Pending,
    Ready,
    Failed,
}
#[derive(Debug, Default, Serialize)]
pub struct ApplyReport {
    pub applied: usize,
    pub skipped: usize,
    pub stale: bool,
    pub conflicts: usize,
    pub diagnostics: Vec<Value>,
}

/// A transaction the host holds open across calls, with its own savepoint stack.
struct Session {
    changed: BTreeSet<String>,
    savepoints: Vec<String>,
    counter: u64,
}

pub struct Client<S: ClientStore> {
    store: S,
    schema: Schema,
    client_id: String,
    generation: u64,
    watchers: Vec<(BTreeSet<String>, Sender<()>)>,
    session: Option<Session>,
    last_changed: BTreeSet<String>,
}

impl<S: ClientStore> Client<S> {
    pub fn open(mut store: S, schema: Schema) -> Result<Self> {
        schema.validate()?;
        store.execute_batch(ddl::FRAMEWORK_DDL)?;
        store.begin()?;
        let opened = (|| {
            ddl::reconcile(&mut store, &schema)?;
            let row = store.query("SELECT client_id, generation FROM otter_client", &[])?;
            let (client_id, generation) = match row.rows.first() {
                Some(r) => (
                    r[0].as_str().unwrap_or("").to_string(),
                    engine::as_u64(&r[1])?,
                ),
                None => {
                    let id = uuid::Uuid::new_v4().to_string();
                    store.execute("INSERT INTO otter_client (client_id, next_ordinal, next_push, generation) VALUES (?,1,1,1)", &[Value::from(id.clone())])?;
                    (id, 1)
                }
            };
            // Settling belongs to the opening transaction: it must not consume a
            // generation, or opening a second handle would fence out the first.
            let mut changed = BTreeSet::new();
            Engine::new(&mut store, &schema, &mut changed, false).settle()?;
            Ok::<_, Error>((client_id, generation))
        })();
        let (client_id, generation) = match opened {
            Ok(v) => v,
            Err(e) => {
                store.rollback()?;
                return Err(e);
            }
        };
        store.commit()?;
        Ok(Self {
            store,
            schema,
            client_id,
            generation,
            watchers: vec![],
            session: None,
            last_changed: BTreeSet::new(),
        })
    }
    pub fn client_id(&self) -> &str {
        &self.client_id
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn last_changed(&self) -> &BTreeSet<String> {
        &self.last_changed
    }
    pub fn session_active(&self) -> bool {
        self.session.is_some()
    }
    pub fn watch(&mut self, tables: BTreeSet<String>) -> Receiver<()> {
        let (tx, rx) = mpsc::channel();
        self.watchers.push((tables, tx));
        rx
    }
    fn notify(&mut self, changed: BTreeSet<String>) {
        self.watchers.retain(|(tables, sender)| {
            if tables.iter().any(|t| changed.contains(t)) {
                sender.send(()).is_ok()
            } else {
                true
            }
        });
        self.last_changed = changed;
    }
    /// Bump the generation inside the open transaction; a stale writer fails here.
    fn fence(&mut self) -> Result<()> {
        let affected = self.store.execute(
            "UPDATE otter_client SET generation = generation + 1 WHERE generation = ?",
            &[Value::from(self.generation)],
        )?;
        if affected != 1 {
            return Err(invalid("stale client writer; reopen runtime"));
        }
        Ok(())
    }
    pub(crate) fn write<T>(
        &mut self,
        body: impl FnOnce(&mut Engine<'_, S>) -> Result<T>,
    ) -> Result<T> {
        if self.session.is_some() {
            return Err(invalid("client transaction active"));
        }
        self.store.begin()?;
        let mut changed = BTreeSet::new();
        let applied = body(&mut Engine::new(
            &mut self.store,
            &self.schema,
            &mut changed,
            false,
        ));
        match applied.and_then(|value| self.fence().map(|()| value)) {
            Ok(value) => {
                self.store.commit()?;
                self.generation += 1;
                changed.insert("otter_client".into());
                self.notify(changed);
                Ok(value)
            }
            Err(e) => {
                self.store.rollback()?;
                Err(e)
            }
        }
    }
    pub(crate) fn view<T>(
        &mut self,
        body: impl FnOnce(&mut Engine<'_, S>) -> Result<T>,
    ) -> Result<T> {
        let mut changed = BTreeSet::new();
        body(&mut Engine::new(
            &mut self.store,
            &self.schema,
            &mut changed,
            true,
        ))
    }
    pub fn transaction<T>(
        &mut self,
        body: impl FnOnce(&mut ClientTransaction<'_, S>) -> Result<T>,
    ) -> Result<T> {
        self.write(|engine| {
            let mut tx = ClientTransaction {
                engine: Engine::new(
                    &mut *engine.store,
                    engine.schema,
                    &mut *engine.changed,
                    false,
                ),
                depth: 0,
            };
            body(&mut tx)
        })
    }
    pub fn begin_session(&mut self) -> Result<()> {
        if self.session.is_some() {
            return Err(invalid("transaction already active"));
        }
        self.store.begin()?;
        self.session = Some(Session {
            changed: BTreeSet::new(),
            savepoints: vec![],
            counter: 0,
        });
        Ok(())
    }
    pub fn session<T>(
        &mut self,
        body: impl FnOnce(&mut ClientTransaction<'_, S>) -> Result<T>,
    ) -> Result<T> {
        let Self {
            store,
            schema,
            session,
            ..
        } = self;
        let session = session
            .as_mut()
            .ok_or_else(|| invalid("no active transaction"))?;
        let mut tx = ClientTransaction {
            engine: Engine::new(store, schema, &mut session.changed, false),
            depth: 0,
        };
        body(&mut tx)
    }
    pub fn commit_session(&mut self) -> Result<()> {
        let session = self
            .session
            .take()
            .ok_or_else(|| invalid("no active transaction"))?;
        if !session.savepoints.is_empty() {
            self.store.rollback()?;
            return Err(invalid("unclosed savepoint"));
        }
        if let Err(e) = self.fence() {
            self.store.rollback()?;
            return Err(e);
        }
        self.store.commit()?;
        self.generation += 1;
        let mut changed = session.changed;
        changed.insert("otter_client".into());
        self.notify(changed);
        Ok(())
    }
    pub fn rollback_session(&mut self) -> Result<()> {
        self.session
            .take()
            .ok_or_else(|| invalid("no active transaction"))?;
        self.store.rollback()
    }
    pub fn session_savepoint(&mut self) -> Result<()> {
        let session = self
            .session
            .as_mut()
            .ok_or_else(|| invalid("no active transaction"))?;
        session.counter += 1;
        let name = format!("session_{}", session.counter);
        self.store.savepoint(&name)?;
        session.savepoints.push(name);
        Ok(())
    }
    pub fn session_release(&mut self) -> Result<()> {
        let session = self
            .session
            .as_mut()
            .ok_or_else(|| invalid("no active transaction"))?;
        let name = session
            .savepoints
            .pop()
            .ok_or_else(|| invalid("no savepoint"))?;
        self.store.release(&name)
    }
    pub fn session_rollback_savepoint(&mut self) -> Result<()> {
        let session = self
            .session
            .as_mut()
            .ok_or_else(|| invalid("no active transaction"))?;
        let name = session
            .savepoints
            .pop()
            .ok_or_else(|| invalid("no savepoint"))?;
        self.store.rollback_to(&name)
    }
    pub fn read(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        let key = self.schema.record_key(&key.model, &key.identity)?;
        self.view(|e| e.read_row(&key))
    }
    pub fn query(&mut self, model: &str, filter: &Value) -> Result<Vec<Value>> {
        let filter: std::collections::BTreeMap<String, Value> =
            serde_json::from_value(filter.clone())?;
        self.view(|e| {
            query::evaluate(
                e,
                model,
                &QuerySpec {
                    filter,
                    ..Default::default()
                },
            )
        })
    }
    pub fn read_sql(&mut self, sql: &str, parameters: &[Value]) -> Result<Vec<Value>> {
        let rows = self.store.query_committed(sql, parameters)?;
        query::rows_to_objects(rows)
    }
    pub fn session_sql(&mut self, sql: &str, parameters: &[Value]) -> Result<Vec<Value>> {
        if self.session.is_none() {
            return Err(invalid("no active transaction"));
        }
        let rows = self.store.query(sql, parameters)?;
        query::rows_to_objects(rows)
    }
    pub fn pending_count(&mut self) -> Result<usize> {
        self.view(|e| Ok(e.count("otter_mutation")? as usize))
    }
    pub fn before_image_count(&mut self) -> Result<usize> {
        let tables: Vec<String> = self
            .schema
            .models
            .iter()
            .map(|m| ddl::before_table(&m.name))
            .collect();
        self.view(|e| {
            let mut total = 0;
            for table in &tables {
                total += e.count(table)? as usize;
            }
            Ok(total)
        })
    }
    pub fn cursor(&mut self, channel: &str) -> Result<u64> {
        self.view(|e| Ok(e.cursor(channel)?.unwrap_or(0)))
    }
    pub fn subscriptions(&mut self) -> Result<Vec<(String, u64)>> {
        self.view(|e| e.subscriptions())
    }
    pub fn desired_channels(&mut self) -> Result<BTreeSet<String>> {
        Ok(self.subscriptions()?.into_iter().map(|(c, _)| c).collect())
    }
    pub fn checkpoint_channels(&mut self) -> Result<BTreeSet<String>> {
        self.view(|e| e.checkpoint_channels())
    }
    pub fn drop_mutation(&mut self, ordinal: u64) -> Result<()> {
        self.write(|e| {
            match e.queued_one(ordinal)? {
                None => return Ok(()),
                Some(q) if q.push.is_some() => {
                    return Err(invalid(
                        "cannot drop a sent mutation with unknown/accepted outcome",
                    ));
                }
                Some(_) => {}
            }
            e.remove_rejected(&[Rejection {
                ordinal,
                code: "dropped".into(),
            }])
        })
    }
    pub fn freeze(&mut self) -> Result<Option<Vec<u8>>> {
        self.freeze_with_limit(256 * 1024)
    }
    pub fn freeze_with_limit(&mut self, max_bytes: usize) -> Result<Option<Vec<u8>>> {
        self.write(|e| e.freeze(max_bytes))
    }
    pub fn acknowledge(&mut self, sequence: u64, receipt: PushReceipt) -> Result<()> {
        let receipt = PushReceipt::decode(&receipt.encode()?)?;
        self.write(|e| e.acknowledge(sequence, &receipt))
    }
    pub fn set_readiness(&mut self, key: &str, value: Readiness) -> Result<()> {
        self.write(|e| {
            match value {
                Readiness::Ready => e.resolve_prerequisite(key)?,
                Readiness::Failed => e.fail_prerequisite(key, "failed")?,
                Readiness::Pending => e.reset_prerequisite(key)?,
            };
            Ok(())
        })
    }
    pub fn pending_tasks(&mut self) -> Result<Vec<Value>> {
        self.view(|e| {
            Ok(e.prerequisite_keys()?
                .into_iter()
                .map(|(key, error)| {
                    // Schema-derived keys are canonical JSON invocations; any other
                    // key is opaque and carries no fields of its own.
                    let mut value = serde_json::from_str::<Value>(&key)
                        .ok()
                        .filter(Value::is_object)
                        .unwrap_or_else(|| json!({}));
                    value["key"] = json!(key);
                    value["state"] = json!(if error.is_some() { "failed" } else { "pending" });
                    value
                })
                .collect())
        })
    }
    pub fn dismiss_rejection(&mut self, ordinal: u64) -> Result<()> {
        self.write(|e| e.delete_rejection(ordinal))
    }
    pub fn rejections(&mut self) -> Result<Vec<Rejection>> {
        self.view(|e| e.rejections())
    }
    pub fn record_status(&mut self, key: &RecordKey) -> Result<Value> {
        let key = self.schema.record_key(&key.model, &key.identity)?;
        self.view(|e| {
            let prerequisites: BTreeMap<String, Option<String>> =
                e.prerequisite_keys()?.into_iter().collect();
            let mut pending = vec![];
            for q in e.queued()? {
                let touches = q
                    .mutation
                    .operations
                    .iter()
                    .chain(&q.mutation.companion)
                    .chain(&q.mutation.effects)
                    .any(|op| op.model == key.model && op.identity == key.identity);
                if !touches {
                    continue;
                }
                let phase = match q.push {
                    None => "queued",
                    Some(push) if e.checkpoints(push)?.is_empty() => "frozen",
                    Some(_) => "accepted",
                };
                let prerequisites: Vec<Value> = q
                    .mutation
                    .prerequisites
                    .iter()
                    .map(|k| {
                        json!({"key":k,"state":match prerequisites.get(k) {
                            None => "ready",
                            Some(Some(_)) => "failed",
                            Some(None) => "pending",
                        }})
                    })
                    .collect();
                pending.push(json!({"ordinal":q.ordinal,"name":q.mutation.name,"phase":phase,"prerequisites":prerequisites}));
            }
            let rejections: Vec<Value> = e
                .rejection_details()?
                .into_iter()
                .filter(|d| {
                    d["records"].as_array().is_some_and(|r| {
                        r.iter()
                            .any(|x| x["model"] == key.model && x["identity"] == key.identity)
                    })
                })
                .collect();
            Ok(json!({"pending":pending,"rejections":rejections}))
        })
    }
}

pub struct ClientTransaction<'a, S: ClientStore> {
    pub(crate) engine: Engine<'a, S>,
    depth: u64,
}
impl<S: ClientStore> ClientTransaction<'_, S> {
    pub fn read(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        let key = self.engine.schema.record_key(&key.model, &key.identity)?;
        self.engine.read_row(&key)
    }
    pub fn savepoint<T>(&mut self, body: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        self.depth += 1;
        let name = format!("tx_{}", self.depth);
        self.engine.store.savepoint(&name)?;
        let result = body(self);
        self.depth -= 1;
        match result {
            Ok(v) => {
                self.engine.store.release(&name)?;
                Ok(v)
            }
            Err(e) => {
                self.engine.store.rollback_to(&name)?;
                Err(e)
            }
        }
    }
    pub fn set_channel(&mut self, channel: String, subscribed: bool) -> Result<()> {
        if subscribed {
            if self.engine.cursor(&channel)?.is_none() {
                self.engine.set_cursor(&channel, 0)?;
            }
            Ok(())
        } else {
            self.engine.unsubscribe(&channel)
        }
    }
    pub fn enqueue(&mut self, mutation: Mutation) -> Result<u64> {
        self.savepoint(|tx| tx.engine.enqueue(mutation))
    }
    pub fn direct(&mut self, operation: Operation) -> Result<()> {
        self.savepoint(|tx| tx.engine.direct(operation))
    }
}
