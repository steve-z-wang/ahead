//! One command/value contract shared by native language bridges.
use lfs_client::*;
use lfs_core::*;
use lfs_sqlite::SqliteStore;
use serde_json::{Value, json};
use std::collections::BTreeMap;
#[derive(Default)]
pub struct RuntimeHost {
    next: u64,
    clients: BTreeMap<u64, Entry>,
}
struct Entry {
    client: Client<SqliteStore>,
    session: Option<TransactionSession>,
    savepoints: Vec<TransactionSession>,
    cycle: SyncCycle,
    connection: ConnectionDriver,
}
impl RuntimeHost {
    pub fn call(&mut self, request: Value) -> Result<Value> {
        let op = text(&request, "op")?;
        if op == "open" {
            let migration = request
                .get("migration")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()?;
            let client = Client::open_with_migration(
                SqliteStore::open(text(&request, "path")?)?,
                Schema::from_value(request["schema"].clone())?,
                text(&request, "owner")?.into(),
                migration,
            )?;
            self.next = self
                .next
                .checked_add(1)
                .ok_or_else(|| invalid("handle exhausted"))?;
            let handle = self.next;
            let generation = client.generation();
            let client_id = client.client_id().to_string();
            self.clients.insert(
                handle,
                Entry {
                    client,
                    session: None,
                    savepoints: vec![],
                    cycle: SyncCycle::default(),
                    connection: ConnectionDriver::default(),
                },
            );
            return Ok(
                json!({"value":{"handle":handle,"clientId":client_id},"changed":false,"generation":generation}),
            );
        }
        let id = read_counter(&request["handle"], true)?;
        if op == "close" {
            self.clients
                .remove(&id)
                .ok_or_else(|| invalid("client_closed"))?;
            return Ok(json!({"value":null,"changed":false}));
        }
        let e = self
            .clients
            .get_mut(&id)
            .ok_or_else(|| invalid("client_closed"))?;
        let generation = e.client.generation();
        if request["transaction"] == true && e.session.is_none() {
            return Err(invalid("transaction_closed"));
        }
        let value = match op {
            "begin" => {
                if e.session.is_some() {
                    return Err(invalid("transaction already active"));
                }
                e.session = Some(e.client.begin_session());
                Value::Null
            }
            "commit" => {
                if !e.savepoints.is_empty() {
                    return Err(invalid("unclosed savepoint"));
                }
                let session = e
                    .session
                    .take()
                    .ok_or_else(|| invalid("no active transaction"))?;
                e.client.commit_session(session)?;
                Value::Null
            }
            "rollback" => {
                e.session
                    .take()
                    .ok_or_else(|| invalid("no active transaction"))?;
                e.savepoints.clear();
                Value::Null
            }
            "savepoint" => {
                e.savepoints.push(
                    e.session
                        .as_ref()
                        .ok_or_else(|| invalid("no active transaction"))?
                        .clone(),
                );
                Value::Null
            }
            "release" => {
                e.savepoints.pop().ok_or_else(|| invalid("no savepoint"))?;
                Value::Null
            }
            "rollbackSavepoint" => {
                e.session = Some(e.savepoints.pop().ok_or_else(|| invalid("no savepoint"))?);
                Value::Null
            }
            "read" => {
                let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                match &mut e.session {
                    Some(s) => s.run(|tx| tx.read(&key))?,
                    None => e.client.read(&key)?,
                }
                .unwrap_or(Value::Null)
            }
            "query" => {
                let model = text(&request, "model")?;
                let filter = request.get("filter").cloned().unwrap_or(json!({}));
                serde_json::to_value(match &mut e.session {
                    Some(s) => s.run(|tx| tx.query(model, &filter))?,
                    None => e.client.query(model, &filter)?,
                })?
            }
            "sql" => {
                let sql = text(&request, "sql")?;
                let parameters = request["parameters"]
                    .as_array()
                    .ok_or_else(|| invalid("SQL parameters must be array"))?;
                serde_json::to_value(match &e.session {
                    Some(s) => e.client.session_sql(s, sql, parameters)?,
                    None => e.client.read_sql(sql, parameters)?,
                })?
            }
            "querySpec" => {
                let model = text(&request, "model")?;
                let spec: QuerySpec = serde_json::from_value(request["query"].clone())?;
                serde_json::to_value(match &mut e.session {
                    Some(s) => s.run(|tx| tx.query_spec(model, &spec))?,
                    None => e.client.query_spec(model, &spec)?,
                })?
            }
            "related" => {
                let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                let name = text(&request, "relation")?;
                match &mut e.session {
                    Some(s) => s.run(|tx| tx.related(&key, name))?,
                    None => e.client.related(&key, name)?,
                }
                .unwrap_or(Value::Null)
            }
            "referencing" => {
                let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                let name = text(&request, "relation")?;
                let source = text(&request, "source")?;
                serde_json::to_value(match &mut e.session {
                    Some(s) => s.run(|tx| tx.referencing(&key, source, name))?,
                    None => e.client.referencing(&key, source, name)?,
                })?
            }
            "enqueue" => {
                let mutation: Mutation = serde_json::from_value(request["mutation"].clone())?;
                let ordinal = match &mut e.session {
                    Some(s) => s.run(|tx| tx.enqueue(mutation))?,
                    None => e.client.transaction(|tx| tx.enqueue(mutation))?,
                };
                json!(ordinal)
            }
            "direct" => {
                let operation: Operation = serde_json::from_value(request["operation"].clone())?;
                match &mut e.session {
                    Some(s) => s.run(|tx| tx.direct(operation))?,
                    None => e.client.transaction(|tx| tx.direct(operation))?,
                };
                Value::Null
            }
            "channel" => {
                let channel = text(&request, "channel")?.to_string();
                let subscribed = request["subscribed"]
                    .as_bool()
                    .ok_or_else(|| invalid("subscribed must be bool"))?;
                match &mut e.session {
                    Some(s) => s.run(|tx| {
                        tx.set_channel(channel, subscribed);
                        Ok(())
                    })?,
                    None => e.client.transaction(|tx| {
                        tx.set_channel(channel, subscribed);
                        Ok(())
                    })?,
                };
                Value::Null
            }
            _ => {
                if e.session.is_some() {
                    return Err(invalid("client transaction active"));
                }
                match op {
                    "connection" => {
                        let now = request
                            .get("now")
                            .map(|v| read_counter(v, false))
                            .transpose()?
                            .unwrap_or(0);
                        match text(&request, "event")? {
                            "start" => e.connection.start(now),
                            "stop" => e.connection.stop(),
                            "pause" => e.connection.pause(),
                            "resume" => e.connection.resume(now),
                            "wake" => e.connection.wake(),
                            "success" => e.connection.complete(true, now, 0),
                            "failure" => e.connection.complete(
                                false,
                                now,
                                request
                                    .get("entropy")
                                    .map(|v| read_counter(v, false))
                                    .transpose()?
                                    .unwrap_or(0),
                            ),
                            "next" => {}
                            _ => return Err(invalid("unknown connection event")),
                        }
                        if request["event"] == "next" {
                            serde_json::to_value(e.connection.next(now))?
                        } else {
                            Value::Null
                        }
                    }
                    "startSync" => {
                        e.cycle.restart();
                        Value::Null
                    }
                    "next" => serde_json::to_value(e.cycle.next(&mut e.client)?)?,
                    "complete" => {
                        e.cycle.complete(
                            &mut e.client,
                            serde_json::to_string(&request["response"])?.as_bytes(),
                        )?;
                        Value::Null
                    }
                    "freeze" => match e.client.freeze()? {
                        Some(bytes) => {
                            json!(String::from_utf8(bytes).map_err(|_| invalid("utf8"))?)
                        }
                        None => Value::Null,
                    },
                    "ack" => {
                        let receipt = PushReceipt::decode(
                            serde_json::to_string(&request["receipt"])?.as_bytes(),
                        )?;
                        e.client
                            .acknowledge(read_counter(&request["sequence"], true)?, receipt)?;
                        Value::Null
                    }
                    "pull" => {
                        let page =
                            PullPage::decode(serde_json::to_string(&request["page"])?.as_bytes())?;
                        serde_json::to_value(e.client.apply_page(page)?)?
                    }
                    "readiness" => {
                        let readiness: Readiness =
                            serde_json::from_value(request["state"].clone())?;
                        e.client.set_readiness(text(&request, "key")?, readiness)?;
                        Value::Null
                    }
                    "drop" => {
                        e.client
                            .drop_mutation(read_counter(&request["ordinal"], true)?)?;
                        Value::Null
                    }
                    "dismiss" => {
                        e.client
                            .dismiss_rejection(read_counter(&request["ordinal"], true)?)?;
                        Value::Null
                    }
                    "recordStatus" => {
                        let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                        e.client.record_status(&key)?
                    }
                    "tasks" => json!(e.client.pending_tasks()),
                    "status" => {
                        json!({"clientId":e.client.client_id(),"pending":e.client.pending_count(),"beforeImages":e.client.before_image_count(),"cursors":e.client.snapshot().cursors,"channels":e.client.desired_channels(),"rejections":e.client.rejections()})
                    }
                    _ => return Err(invalid(format!("unknown client command {op}"))),
                }
            }
        };
        Ok(
            json!({"value":value,"changed":generation!=e.client.generation(),"generation":e.client.generation()}),
        )
    }
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .ok_or_else(|| invalid(format!("{key} must be string")))
}
