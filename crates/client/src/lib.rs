//! Durable client state machine. Storage and transport never decide settlement.
mod query;
pub use query::{Direction, QueryOrder, QuerySpec};
pub mod ddl;
pub mod store;
pub use store::*;
mod migration;
pub use migration::SchemaMigration;
mod connection;
pub use connection::{ConnectionAction, ConnectionDriver};
mod cascade;
mod policies;
mod transport;
use otter_core::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::mpsc::{self, Receiver, Sender};
pub use transport::*;

pub trait LegacyClientStore {
    fn read_sql(
        &mut self,
        _schema: &Schema,
        _state: &ClientState,
        _sql: &str,
        _parameters: &[Value],
    ) -> Result<Vec<Value>> {
        Err(invalid("read-only SQL unsupported by persistence"))
    }
    fn load(&mut self) -> Result<Option<(u64, ClientState)>>;
    /// Atomically persist or reject a stale writer. Never partially commit state.
    fn commit(&mut self, expected_generation: u64, state: &ClientState) -> Result<u64>;
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StoredRecord {
    pub key: RecordKey,
    pub state: Value,
}
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
    #[serde(default)]
    pub subscribe: Vec<String>,
    #[serde(default)]
    pub unsubscribe: Vec<String>,
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
            subscribe: vec![],
            unsubscribe: vec![],
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
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct QueuedMutation {
    pub ordinal: u64,
    pub mutation: Mutation,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FrozenBatch {
    pub sequence: u64,
    pub ordinals: Vec<u64>,
    pub request: Value,
    pub receipt: Option<PushReceipt>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ClientState {
    pub client_id: String,
    pub owner: String,
    pub schema: Value,
    pub next_ordinal: u64,
    pub next_sequence: u64,
    pub records: BTreeMap<String, StoredRecord>,
    pub before: BTreeMap<String, Option<StoredRecord>>,
    pub queue: Vec<QueuedMutation>,
    pub batches: Vec<FrozenBatch>,
    pub cursors: BTreeMap<String, u64>,
    pub claims: BTreeMap<String, BTreeSet<String>>,
    pub channels: BTreeSet<String>,
    pub readiness: BTreeMap<String, Readiness>,
    pub rejections: Vec<Rejection>,
    #[serde(default)]
    pub rejection_details: BTreeMap<u64, Value>,
    #[serde(default)]
    pub tasks: BTreeMap<String, Value>,
}
#[derive(Debug, Default, Serialize)]
pub struct ApplyReport {
    pub applied: usize,
    pub skipped: usize,
    pub stale: bool,
}

pub struct Client<S: LegacyClientStore> {
    store: S,
    schema: Schema,
    state: ClientState,
    generation: u64,
    watchers: Vec<Sender<u64>>,
}
impl<S: LegacyClientStore> Client<S> {
    pub fn open(store: S, schema: Schema, owner: String) -> Result<Self> {
        Self::open_with_migration(store, schema, owner, None)
    }
    pub fn open_with_migration(
        mut store: S,
        schema: Schema,
        owner: String,
        migration: Option<SchemaMigration>,
    ) -> Result<Self> {
        schema.validate()?;
        let descriptor = serde_json::to_value(&schema)?;
        let (generation, state) = match store.load()? {
            Some((mut generation, mut state)) => {
                if state.owner != owner {
                    return Err(invalid("client.owner_mismatch"));
                }
                if state.schema != descriptor {
                    let options = migration
                        .as_ref()
                        .ok_or_else(|| invalid("schema migration required"))?;
                    migration::migrate(&mut state, &schema, options)?;
                    generation = store.commit(generation, &state)?;
                }
                (generation, state)
            }
            None => {
                let state = ClientState {
                    client_id: uuid::Uuid::new_v4().to_string(),
                    owner,
                    schema: descriptor,
                    next_ordinal: 1,
                    next_sequence: 1,
                    records: BTreeMap::new(),
                    before: BTreeMap::new(),
                    queue: vec![],
                    batches: vec![],
                    cursors: BTreeMap::new(),
                    claims: BTreeMap::new(),
                    channels: BTreeSet::new(),
                    readiness: BTreeMap::new(),
                    rejections: vec![],
                    rejection_details: BTreeMap::new(),
                    tasks: BTreeMap::new(),
                };
                let generation = store.commit(0, &state)?;
                (generation, state)
            }
        };
        Ok(Self {
            store,
            schema,
            state,
            generation,
            watchers: vec![],
        })
    }
    pub fn read_sql(&mut self, sql: &str, parameters: &[Value]) -> Result<Vec<Value>> {
        self.store
            .read_sql(&self.schema, &self.state, sql, parameters)
    }
    pub fn session_sql(
        &mut self,
        session: &TransactionSession,
        sql: &str,
        parameters: &[Value],
    ) -> Result<Vec<Value>> {
        if session.generation != self.generation || session.state.client_id != self.state.client_id
        {
            return Err(invalid("stale transaction session"));
        }
        self.store
            .read_sql(&self.schema, &session.state, sql, parameters)
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn begin_session(&self) -> TransactionSession {
        TransactionSession {
            schema: self.schema.clone(),
            state: self.state.clone(),
            generation: self.generation,
        }
    }
    pub fn commit_session(&mut self, session: TransactionSession) -> Result<()> {
        if session.generation != self.generation || session.state.client_id != self.state.client_id
        {
            return Err(invalid("stale transaction session"));
        }
        self.commit(session.state)
    }
    pub fn client_id(&self) -> &str {
        &self.state.client_id
    }
    pub fn snapshot(&self) -> &ClientState {
        &self.state
    }
    pub fn pending_count(&self) -> usize {
        self.state.queue.len()
    }
    pub fn before_image_count(&self) -> usize {
        self.state.before.values().filter(|v| v.is_some()).count()
    }
    pub fn cursor(&self, channel: &str) -> u64 {
        *self.state.cursors.get(channel).unwrap_or(&0)
    }
    pub fn pending_tasks(&self) -> Vec<Value> {
        self.state
            .tasks
            .iter()
            .filter(|(k, _)| self.state.readiness.get(*k) != Some(&Readiness::Ready))
            .map(|(k, v)| {
                let mut value = v.clone();
                value["key"] = json!(k);
                value["state"] = json!(
                    self.state
                        .readiness
                        .get(k)
                        .copied()
                        .unwrap_or(Readiness::Pending)
                );
                value
            })
            .collect()
    }
    pub fn record_status(&self, key: &RecordKey) -> Result<Value> {
        let key = self.schema.record_key(&key.model, &key.identity)?;
        let touches = |mutation: &Mutation| {
            mutation
                .operations
                .iter()
                .chain(&mutation.companion)
                .chain(&mutation.effects)
                .any(|op| op.model == key.model && op.identity == key.identity)
        };
        let pending=self.state.queue.iter().filter(|q|touches(&q.mutation)).map(|q|{
            let batch=self.state.batches.iter().find(|batch|batch.ordinals.contains(&q.ordinal));let phase=match batch{None=>"queued",Some(batch)if batch.receipt.is_some()=>"accepted",_=>"frozen"};
            let prerequisites=q.mutation.prerequisites.iter().map(|key|json!({"key":key,"state":self.state.readiness.get(key).copied().unwrap_or(Readiness::Pending)})).collect::<Vec<_>>();
            json!({"ordinal":q.ordinal,"name":q.mutation.name,"phase":phase,"prerequisites":prerequisites})
        }).collect::<Vec<_>>();
        let rejections = self
            .state
            .rejection_details
            .values()
            .filter(|detail| {
                detail["records"].as_array().is_some_and(|records| {
                    records.iter().any(|record| {
                        record["model"] == key.model && record["identity"] == key.identity
                    })
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({"pending":pending,"rejections":rejections}))
    }
    pub fn rejections(&self) -> &[Rejection] {
        &self.state.rejections
    }
    pub fn read(&self, key: &RecordKey) -> Result<Option<Value>> {
        read(&self.schema, &self.state, key)
    }
    pub fn query(&self, model: &str, filter: &Value) -> Result<Vec<Value>> {
        query(&self.schema, &self.state, model, filter)
    }
    pub fn query_spec(&self, model: &str, spec: &QuerySpec) -> Result<Vec<Value>> {
        query::evaluate(&self.schema, &self.state, model, spec)
    }
    pub fn related(&self, key: &RecordKey, name: &str) -> Result<Option<Value>> {
        query::related(&self.schema, &self.state, key, name)
    }
    pub fn referencing(&self, key: &RecordKey, source: &str, name: &str) -> Result<Vec<Value>> {
        query::referencing(&self.schema, &self.state, key, source, name)
    }

    pub fn subscribe(&mut self) -> Receiver<u64> {
        let (tx, rx) = mpsc::channel();
        self.watchers.push(tx);
        rx
    }
    fn commit(&mut self, next: ClientState) -> Result<()> {
        let generation = self.store.commit(self.generation, &next)?;
        self.state = next;
        self.generation = generation;
        self.watchers.retain(|w| w.send(generation).is_ok());
        Ok(())
    }
    pub fn transaction<T>(
        &mut self,
        body: impl FnOnce(&mut ClientTransaction<'_>) -> Result<T>,
    ) -> Result<T> {
        let mut next = self.state.clone();
        let result = body(&mut ClientTransaction {
            schema: &self.schema,
            state: &mut next,
        })?;
        self.commit(next)?;
        Ok(result)
    }
    pub fn desired_channels(&self) -> BTreeSet<String> {
        let mut channels = self.state.channels.clone();
        for q in &self.state.queue {
            for c in &q.mutation.subscribe {
                channels.insert(c.clone());
            }
            for c in &q.mutation.unsubscribe {
                channels.remove(c);
            }
        }
        channels
    }
    pub fn set_readiness(&mut self, key: &str, value: Readiness) -> Result<()> {
        if !self
            .state
            .queue
            .iter()
            .any(|q| q.mutation.prerequisites.iter().any(|k| k == key))
        {
            return Ok(());
        }
        let mut next = self.state.clone();
        next.readiness.insert(key.into(), value);
        self.commit(next)
    }
    pub fn dismiss_rejection(&mut self, ordinal: u64) -> Result<()> {
        let mut next = self.state.clone();
        next.rejections.retain(|r| r.ordinal != ordinal);
        next.rejection_details.remove(&ordinal);
        self.commit(next)
    }
    pub fn drop_mutation(&mut self, ordinal: u64) -> Result<()> {
        if self
            .state
            .batches
            .iter()
            .any(|b| b.ordinals.contains(&ordinal))
        {
            return Err(invalid(
                "cannot drop a sent mutation with unknown/accepted outcome",
            ));
        }
        let mut next = self.state.clone();
        remove_rejected(
            &self.schema,
            &mut next,
            &[Rejection {
                ordinal,
                code: "dropped".into(),
            }],
        )?;
        self.commit(next)
    }
    pub fn freeze(&mut self) -> Result<Option<Vec<u8>>> {
        self.freeze_with_limit(256 * 1024)
    }
    pub fn freeze_with_limit(&mut self, max_bytes: usize) -> Result<Option<Vec<u8>>> {
        if max_bytes == 0 {
            return Ok(None);
        }
        if let Some(batch) = self.state.batches.iter().find(|b| b.receipt.is_none()) {
            return Ok(Some(canonical_json(&batch.request)?.into_bytes()));
        }
        let assigned: BTreeSet<_> = self
            .state
            .batches
            .iter()
            .flat_map(|b| b.ordinals.iter().copied())
            .collect();
        let mut selected = BTreeSet::new();
        let mut acts = vec![];
        for q in &self.state.queue {
            if assigned.contains(&q.ordinal)
                || q.mutation
                    .prerequisites
                    .iter()
                    .any(|key| self.state.readiness.get(key) != Some(&Readiness::Ready))
            {
                continue;
            }
            let active = |id: &u64| {
                self.state.queue.iter().any(|p| p.ordinal == *id) && !assigned.contains(id)
            };
            let blocked = q.mutation.lifecycle_dependencies.iter().any(active)
                || q.mutation
                    .sequence_dependencies
                    .iter()
                    .any(|id| active(id) && !selected.contains(id));
            if blocked {
                continue;
            }
            let act = json!({"ordinal":q.ordinal,"name":q.mutation.name,"version":q.mutation.version,"operations":q.mutation.operations});
            if !acts.is_empty() {
                let mut candidate = acts.clone();
                candidate.push(act.clone());
                let request = json!({"clientId":self.state.client_id,"batchSequence":self.state.next_sequence,"mutations":candidate});
                if canonical_json(&request)?.len() > max_bytes {
                    continue;
                }
            }
            acts.push(act);
            selected.insert(q.ordinal);
            if acts.len() == 20 {
                break;
            }
        }
        if acts.is_empty() {
            return Ok(None);
        }
        let mut next = self.state.clone();
        let sequence = counter(next.next_sequence)?;
        next.next_sequence = sequence
            .checked_add(1)
            .ok_or_else(|| invalid("sequence exhausted"))?;
        let request = json!({"clientId":next.client_id,"batchSequence":sequence,"mutations":acts});
        let bytes = PushRequest::decode(canonical_json(&request)?.as_bytes())?.encode()?;
        next.batches.push(FrozenBatch {
            sequence,
            ordinals: selected.into_iter().collect(),
            request,
            receipt: None,
        });
        self.commit(next)?;
        Ok(Some(bytes))
    }
    pub fn acknowledge(&mut self, sequence: u64, receipt: PushReceipt) -> Result<()> {
        let receipt = PushReceipt::decode(&receipt.encode()?)?;
        let mut next = self.state.clone();
        let batch = next
            .batches
            .iter_mut()
            .find(|b| b.sequence == sequence)
            .ok_or_else(|| invalid("unknown batch receipt"))?;
        if let Some(existing) = &batch.receipt {
            if *existing != receipt {
                return Err(invalid("receipt changed"));
            }
            return Ok(());
        }
        if receipt
            .rejections
            .iter()
            .any(|r| !batch.ordinals.contains(&r.ordinal))
        {
            return Err(invalid("rejection ordinal not in batch"));
        }
        batch.receipt = Some(receipt.clone());
        remove_rejected(&self.schema, &mut next, &receipt.rejections)?;
        settle(&self.schema, &mut next)?;
        self.commit(next)
    }
    /// Matches the reference per-change failure policy, including its known skip limitation.
    pub fn apply_page(&mut self, page: PullPage) -> Result<ApplyReport> {
        page.validate()?;
        let current = self.cursor(&page.channel);
        if page.to_cursor <= current {
            return Ok(ApplyReport {
                stale: true,
                ..Default::default()
            });
        }
        if page.from_cursor > current {
            return Err(invalid("pull cursor gap"));
        }
        let mut report = ApplyReport::default();
        for change in page.changes.iter().filter(|c| c.cursor > current) {
            let mut next = self.state.clone();
            let outcome = (|| {
                let key = self.schema.record_key(&change.model, &change.identity)?;
                let encoded = key.encoded()?;
                if change.state.is_null() {
                    if let Some(claims) = next.claims.get_mut(&encoded) {
                        claims.remove(&page.channel);
                    }
                    if next.claims.get(&encoded).is_none_or(|c| c.is_empty()) {
                        next.claims.remove(&encoded);
                        set_authority(&self.schema, &mut next, key, None)?;
                    }
                } else {
                    let state = self.schema.validate_state(&change.model, &change.state)?;
                    next.claims
                        .entry(encoded)
                        .or_default()
                        .insert(page.channel.clone());
                    set_authority(&self.schema, &mut next, key, Some(state))?;
                }
                Ok::<(), Error>(())
            })();
            if outcome.is_err() {
                next = self.state.clone();
                report.skipped += 1;
            } else {
                report.applied += 1;
            }
            next.cursors.insert(page.channel.clone(), change.cursor);
            settle(&self.schema, &mut next)?;
            self.commit(next)?;
        }
        if self.cursor(&page.channel) < page.to_cursor {
            let mut next = self.state.clone();
            next.cursors.insert(page.channel, page.to_cursor);
            settle(&self.schema, &mut next)?;
            self.commit(next)?;
        }
        Ok(report)
    }
}
pub struct ClientTransaction<'a> {
    schema: &'a Schema,
    state: &'a mut ClientState,
}
impl ClientTransaction<'_> {
    pub fn read(&self, key: &RecordKey) -> Result<Option<Value>> {
        read(self.schema, self.state, key)
    }
    pub fn query(&self, model: &str, filter: &Value) -> Result<Vec<Value>> {
        query(self.schema, self.state, model, filter)
    }
    pub fn query_spec(&self, model: &str, spec: &QuerySpec) -> Result<Vec<Value>> {
        query::evaluate(self.schema, self.state, model, spec)
    }
    pub fn related(&self, key: &RecordKey, name: &str) -> Result<Option<Value>> {
        query::related(self.schema, self.state, key, name)
    }
    pub fn referencing(&self, key: &RecordKey, source: &str, name: &str) -> Result<Vec<Value>> {
        query::referencing(self.schema, self.state, key, source, name)
    }

    pub fn savepoint<T>(&mut self, body: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        let before = self.state.clone();
        match body(self) {
            Ok(v) => Ok(v),
            Err(e) => {
                *self.state = before;
                Err(e)
            }
        }
    }
    pub fn set_channel(&mut self, channel: String, subscribed: bool) {
        if subscribed {
            self.state.channels.insert(channel);
        } else {
            self.state.channels.remove(&channel);
        }
    }
    pub fn enqueue(&mut self, mut mutation: Mutation) -> Result<u64> {
        self.savepoint(|tx| {
            if mutation.name.trim().is_empty()
                || mutation.version == 0
                || mutation.operations.is_empty()
            {
                return Err(invalid("invalid named mutation"));
            }
            for dependency in mutation
                .lifecycle_dependencies
                .iter()
                .chain(&mutation.sequence_dependencies)
            {
                if !tx.state.queue.iter().any(|q| q.ordinal == *dependency) {
                    return Err(invalid("unknown mutation dependency"));
                }
            }
            mutation.effects.clear();
            let mut touched = BTreeSet::new();
            for op in mutation
                .operations
                .iter_mut()
                .chain(mutation.companion.iter_mut())
            {
                normalize_operation(tx.schema, op)?;
                let key = tx.schema.record_key(&op.model, &op.identity)?;
                let encoded = key.encoded()?;
                if touched.insert(encoded.clone()) && !dirty(tx.schema, tx.state, &encoded)? {
                    tx.state
                        .before
                        .insert(encoded.clone(), tx.state.records.get(&encoded).cloned());
                }
                if op.op == OperationKind::Delete {
                    for child in cascade::descendants(tx.schema, tx.state, &key)? {
                        let child_key = child.encoded()?;
                        if touched.insert(child_key.clone())
                            && !dirty(tx.schema, tx.state, &child_key)?
                        {
                            tx.state.before.insert(
                                child_key.clone(),
                                tx.state.records.get(&child_key).cloned(),
                            );
                        }
                        let effect = Operation {
                            model: child.model,
                            identity: child.identity,
                            op: OperationKind::Delete,
                            values: None,
                        };
                        apply_operation(tx.schema, &mut tx.state.records, &effect)?;
                        mutation.effects.push(effect);
                    }
                }
                apply_operation(tx.schema, &mut tx.state.records, op)?;
            }
            policies::derive(tx.schema, tx.state, &mut mutation)?;
            let ordinal = counter(tx.state.next_ordinal)?;
            tx.state.next_ordinal = ordinal
                .checked_add(1)
                .ok_or_else(|| invalid("ordinal exhausted"))?;
            tx.state.queue.push(QueuedMutation { ordinal, mutation });
            Ok(ordinal)
        })
    }
    pub fn direct(&mut self, operation: Operation) -> Result<()> {
        self.savepoint(|tx| tx.direct_inner(operation))
    }
    fn direct_inner(&mut self, mut operation: Operation) -> Result<()> {
        normalize_operation(self.schema, &mut operation)?;
        let key = self
            .schema
            .record_key(&operation.model, &operation.identity)?;
        if operation.op == OperationKind::Delete {
            for child in cascade::descendants(self.schema, self.state, &key)? {
                self.direct_one(Operation {
                    model: child.model,
                    identity: child.identity,
                    op: OperationKind::Delete,
                    values: None,
                })?;
            }
        }
        self.direct_one(operation)
    }
    fn direct_one(&mut self, operation: Operation) -> Result<()> {
        let encoded = self
            .schema
            .record_key(&operation.model, &operation.identity)?
            .encoded()?;
        let is_dirty = dirty(self.schema, self.state, &encoded)?;
        apply_operation(self.schema, &mut self.state.records, &operation)?;
        if is_dirty {
            let mut truth = BTreeMap::new();
            if let Some(Some(before)) = self.state.before.get(&encoded) {
                truth.insert(encoded.clone(), before.clone());
            }
            if operation.op == OperationKind::Delete {
                self.state.before.insert(encoded, None);
            } else if apply_operation(self.schema, &mut truth, &operation).is_ok() {
                self.state
                    .before
                    .insert(encoded.clone(), truth.remove(&encoded));
            } else {
                self.state
                    .before
                    .insert(encoded.clone(), self.state.records.get(&encoded).cloned());
            }
        }
        Ok(())
    }
}
fn read(schema: &Schema, state: &ClientState, key: &RecordKey) -> Result<Option<Value>> {
    let key = schema.record_key(&key.model, &key.identity)?;
    Ok(state.records.get(&key.encoded()?).map(|r| {
        let mut v = r.state.clone();
        if let Some(m) = v.as_object_mut() {
            for (k, x) in r.key.identity.as_object().into_iter().flatten() {
                m.insert(k.clone(), x.clone());
            }
        }
        v
    }))
}
fn query(schema: &Schema, state: &ClientState, model: &str, filter: &Value) -> Result<Vec<Value>> {
    query::evaluate(
        schema,
        state,
        model,
        &QuerySpec {
            filter: serde_json::from_value(filter.clone())?,
            ..Default::default()
        },
    )
}
fn normalize_operation(schema: &Schema, op: &mut Operation) -> Result<()> {
    op.identity = schema.record_key(&op.model, &op.identity)?.identity;
    match op.op {
        OperationKind::Create => {
            op.values = Some(
                schema.normalize_state(
                    &op.model,
                    op.values
                        .as_ref()
                        .ok_or_else(|| invalid("create values missing"))?,
                )?,
            );
        }
        OperationKind::Update => {
            op.values = Some(
                schema.validate_patch(
                    &op.model,
                    op.values
                        .as_ref()
                        .ok_or_else(|| invalid("update values missing"))?,
                )?,
            );
        }
        OperationKind::Delete => {
            if op.values.is_some() {
                return Err(invalid("delete cannot contain values"));
            }
        }
    }
    Ok(())
}
fn apply_operation(
    schema: &Schema,
    records: &mut BTreeMap<String, StoredRecord>,
    op: &Operation,
) -> Result<()> {
    let key = schema.record_key(&op.model, &op.identity)?;
    let encoded = key.encoded()?;
    match op.op {
        OperationKind::Create => {
            if records.contains_key(&encoded) {
                return Err(invalid("create already exists"));
            }
            let row = StoredRecord {
                key,
                state: op
                    .values
                    .clone()
                    .ok_or_else(|| invalid("create values missing"))?,
            };
            check_unique(schema, records, &encoded, &row)?;
            records.insert(encoded, row);
        }
        OperationKind::Update => {
            let mut row = records
                .get(&encoded)
                .ok_or_else(|| invalid("update row missing"))?
                .clone();
            for (k, v) in op
                .values
                .as_ref()
                .and_then(Value::as_object)
                .ok_or_else(|| invalid("patch missing"))?
            {
                row.state[k] = v.clone();
            }
            check_unique(schema, records, &encoded, &row)?;
            records.insert(encoded, row);
        }
        OperationKind::Delete => {
            records.remove(&encoded);
        }
    }
    Ok(())
}
fn check_unique(
    schema: &Schema,
    records: &BTreeMap<String, StoredRecord>,
    encoded: &str,
    row: &StoredRecord,
) -> Result<()> {
    let value = |record: &StoredRecord, field: &str| {
        record
            .key
            .identity
            .get(field)
            .or_else(|| record.state.get(field))
            .cloned()
            .unwrap_or(Value::Null)
    };
    for fields in &schema.model(&row.key.model)?.unique {
        let values: Vec<_> = fields.iter().map(|f| value(row, f)).collect();
        if values.iter().any(Value::is_null) {
            continue;
        }
        for (key, other) in records {
            if key != encoded
                && other.key.model == row.key.model
                && fields.iter().map(|f| value(other, f)).collect::<Vec<_>>() == values
            {
                return Err(invalid("unique constraint violation"));
            }
        }
    }
    Ok(())
}
fn dirty(schema: &Schema, state: &ClientState, encoded: &str) -> Result<bool> {
    for q in &state.queue {
        for op in q
            .mutation
            .operations
            .iter()
            .chain(&q.mutation.companion)
            .chain(&q.mutation.effects)
        {
            if schema.record_key(&op.model, &op.identity)?.encoded()? == encoded {
                return Ok(true);
            }
        }
    }
    Ok(false)
}
fn rebuild(schema: &Schema, state: &mut ClientState, encoded: &str) -> Result<()> {
    let truth = state.before.get(encoded).cloned().flatten();
    let mut rows = BTreeMap::new();
    if let Some(row) = &truth {
        rows.insert(encoded.into(), row.clone());
    }
    let mut pending = false;
    let mut failed = false;
    for q in &state.queue {
        for op in q
            .mutation
            .operations
            .iter()
            .chain(&q.mutation.companion)
            .chain(&q.mutation.effects)
        {
            if schema.record_key(&op.model, &op.identity)?.encoded()? == encoded {
                pending = true;
                if !failed && apply_operation(schema, &mut rows, op).is_err() {
                    failed = true;
                }
            }
        }
    }
    let result = if failed { truth } else { rows.remove(encoded) };
    match result {
        Some(row) => {
            state.records.insert(encoded.into(), row);
        }
        None => {
            state.records.remove(encoded);
        }
    }
    if !pending {
        state.before.remove(encoded);
    }
    Ok(())
}
fn set_authority(
    schema: &Schema,
    state: &mut ClientState,
    key: RecordKey,
    value: Option<Value>,
) -> Result<()> {
    if value.is_none() {
        for child in cascade::descendants(schema, state, &key)? {
            let encoded = child.encoded()?;
            state.claims.remove(&encoded);
            set_authority_one(schema, state, child, None)?;
        }
    }
    set_authority_one(schema, state, key, value)?;
    cascade::refresh_pending(schema, state)?;
    Ok(())
}
fn set_authority_one(
    schema: &Schema,
    state: &mut ClientState,
    key: RecordKey,
    value: Option<Value>,
) -> Result<()> {
    let encoded = key.encoded()?;
    let row = value.map(|value| StoredRecord { key, state: value });
    if dirty(schema, state, &encoded)? {
        state.before.insert(encoded.clone(), row);
        rebuild(schema, state, &encoded)?;
    } else {
        match row {
            Some(row) => {
                state.records.insert(encoded, row);
            }
            None => {
                state.records.remove(&encoded);
            }
        }
    }
    Ok(())
}
fn remove_rejected(
    schema: &Schema,
    state: &mut ClientState,
    rejections: &[Rejection],
) -> Result<()> {
    let mut rejected: BTreeMap<u64, String> = rejections
        .iter()
        .map(|r| (r.ordinal, r.code.clone()))
        .collect();
    loop {
        let more: Vec<_> = state
            .queue
            .iter()
            .filter(|q| {
                !rejected.contains_key(&q.ordinal)
                    && q.mutation
                        .lifecycle_dependencies
                        .iter()
                        .any(|id| rejected.contains_key(id))
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
    let mut affected = BTreeSet::new();
    for q in &state.queue {
        if let Some(code) = rejected.get(&q.ordinal) {
            for op in q
                .mutation
                .operations
                .iter()
                .chain(&q.mutation.companion)
                .chain(&q.mutation.effects)
            {
                affected.insert(schema.record_key(&op.model, &op.identity)?.encoded()?);
            }
            let records = q
                .mutation
                .operations
                .iter()
                .chain(&q.mutation.companion)
                .chain(&q.mutation.effects)
                .map(|op| json!({"model":op.model,"identity":op.identity}))
                .collect::<Vec<_>>();
            state.rejection_details.insert(
                q.ordinal,
                json!({"ordinal":q.ordinal,"code":code,"mutation":q.mutation,"records":records}),
            );
            state.rejections.push(Rejection {
                ordinal: q.ordinal,
                code: code.clone(),
            });
        }
    }
    state.queue.retain(|q| !rejected.contains_key(&q.ordinal));
    for encoded in affected {
        rebuild(schema, state, &encoded)?;
    }
    cleanup_readiness(state);
    Ok(())
}
fn cleanup_readiness(state: &mut ClientState) {
    let used: BTreeSet<_> = state
        .queue
        .iter()
        .flat_map(|q| q.mutation.prerequisites.iter().cloned())
        .collect();
    state.readiness.retain(|k, _| used.contains(k));
    state.tasks.retain(|k, _| used.contains(k));
}
fn settle(schema: &Schema, state: &mut ClientState) -> Result<()> {
    while let Some(batch) = state.batches.first() {
        let Some(receipt) = &batch.receipt else {
            break;
        };
        if receipt
            .required_checkpoints
            .iter()
            .any(|cp| state.cursors.get(&cp.channel).copied().unwrap_or(0) < cp.cursor)
        {
            break;
        }
        let batch = state.batches.remove(0);
        let selected: BTreeSet<_> = batch.ordinals.into_iter().collect();
        let mut affected = BTreeSet::new();
        let mut wire_rows = BTreeSet::new();
        for q in state.queue.iter().filter(|q| selected.contains(&q.ordinal)) {
            for op in &q.mutation.operations {
                wire_rows.insert(schema.record_key(&op.model, &op.identity)?.encoded()?);
            }
        }
        for q in &state.queue {
            if !selected.contains(&q.ordinal) {
                continue;
            }
            for op in q
                .mutation
                .operations
                .iter()
                .chain(&q.mutation.companion)
                .chain(&q.mutation.effects)
            {
                affected.insert(schema.record_key(&op.model, &op.identity)?.encoded()?);
            }
            let mut local_ops = q.mutation.companion.clone();
            for op in &q.mutation.companion {
                if op.op == OperationKind::Delete {
                    let key = schema.record_key(&op.model, &op.identity)?;
                    if !wire_rows.contains(&key.encoded()?) {
                        for child in cascade::descendants(schema, state, &key)? {
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
                let encoded = schema.record_key(&op.model, &op.identity)?.encoded()?;
                if wire_rows.contains(&encoded) {
                    continue;
                }
                let mut truth = BTreeMap::new();
                if let Some(Some(before)) = state.before.get(&encoded) {
                    truth.insert(encoded.clone(), before.clone());
                }
                if apply_operation(schema, &mut truth, op).is_ok() {
                    state.before.insert(encoded.clone(), truth.remove(&encoded));
                }
            }
            for c in &q.mutation.subscribe {
                state.channels.insert(c.clone());
            }
            for c in &q.mutation.unsubscribe {
                state.channels.remove(c);
            }
        }
        state.queue.retain(|q| !selected.contains(&q.ordinal));
        for encoded in affected {
            rebuild(schema, state, &encoded)?;
        }
        cleanup_readiness(state);
    }
    Ok(())
}

#[derive(Clone)]
pub struct TransactionSession {
    schema: Schema,
    state: ClientState,
    generation: u64,
}
impl TransactionSession {
    pub fn run<T>(
        &mut self,
        body: impl FnOnce(&mut ClientTransaction<'_>) -> Result<T>,
    ) -> Result<T> {
        body(&mut ClientTransaction {
            schema: &self.schema,
            state: &mut self.state,
        })
    }
}
