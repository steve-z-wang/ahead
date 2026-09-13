//! One command/value contract shared by native language bridges.
use otter_client::*;
use otter_sqlite::SqliteStore;
use serde_json::{Value, json};
use std::collections::BTreeMap;
#[derive(Default)]
pub struct RuntimeHost {
    next: u64,
    clients: BTreeMap<u64, Entry>,
}
struct Entry {
    client: Client<SqliteStore>,
    cycle: SyncCycle,
    connection: ConnectionDriver,
}
impl RuntimeHost {
    pub fn call(&mut self, request: Value) -> Result<Value> {
        let op = text(&request, "op")?;
        if op == "open" {
            // `owner` and `migration` may still be sent by language packages; the
            // row-based client keeps neither, so both are accepted and ignored.
            let client = Client::open(
                SqliteStore::open(text(&request, "path")?)?,
                Schema::from_value(request["schema"].clone())?,
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
        if request["transaction"] == true && !e.client.session_active() {
            return Err(invalid("transaction_closed"));
        }
        let value = match op {
            "begin" => {
                e.client.begin_session()?;
                Value::Null
            }
            "commit" => {
                e.client.commit_session()?;
                Value::Null
            }
            "rollback" => {
                e.client.rollback_session()?;
                Value::Null
            }
            "savepoint" => {
                e.client.session_savepoint()?;
                Value::Null
            }
            "release" => {
                e.client.session_release()?;
                Value::Null
            }
            "rollbackSavepoint" => {
                e.client.session_rollback_savepoint()?;
                Value::Null
            }
            "read" => {
                let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                if e.client.session_active() {
                    e.client.session(|tx| tx.read(&key))?
                } else {
                    e.client.read(&key)?
                }
                .unwrap_or(Value::Null)
            }
            "query" => {
                let model = text(&request, "model")?;
                let filter = request.get("filter").cloned().unwrap_or(json!({}));
                serde_json::to_value(if e.client.session_active() {
                    e.client.session(|tx| tx.query(model, &filter))?
                } else {
                    e.client.query(model, &filter)?
                })?
            }
            "sql" => {
                let sql = text(&request, "sql")?;
                let parameters = request["parameters"]
                    .as_array()
                    .ok_or_else(|| invalid("SQL parameters must be array"))?;
                serde_json::to_value(if e.client.session_active() {
                    e.client.session_sql(sql, parameters)?
                } else {
                    e.client.read_sql(sql, parameters)?
                })?
            }
            "querySpec" => {
                let model = text(&request, "model")?;
                let spec: QuerySpec = serde_json::from_value(request["query"].clone())?;
                serde_json::to_value(if e.client.session_active() {
                    e.client.session(|tx| tx.query_spec(model, &spec))?
                } else {
                    e.client.query_spec(model, &spec)?
                })?
            }
            "related" => {
                let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                let name = text(&request, "relation")?;
                if e.client.session_active() {
                    e.client.session(|tx| tx.related(&key, name))?
                } else {
                    e.client.related(&key, name)?
                }
                .unwrap_or(Value::Null)
            }
            "referencing" => {
                let key: RecordKey = serde_json::from_value(request["key"].clone())?;
                let name = text(&request, "relation")?;
                let source = text(&request, "source")?;
                serde_json::to_value(if e.client.session_active() {
                    e.client.session(|tx| tx.referencing(&key, source, name))?
                } else {
                    e.client.referencing(&key, source, name)?
                })?
            }
            "enqueue" => {
                let mutation: Mutation = serde_json::from_value(request["mutation"].clone())?;
                let ordinal = if e.client.session_active() {
                    e.client.session(|tx| tx.enqueue(mutation))?
                } else {
                    e.client.transaction(|tx| tx.enqueue(mutation))?
                };
                json!(ordinal)
            }
            "direct" => {
                let operation: Operation = serde_json::from_value(request["operation"].clone())?;
                if e.client.session_active() {
                    e.client.session(|tx| tx.direct(operation))?
                } else {
                    e.client.transaction(|tx| tx.direct(operation))?
                };
                Value::Null
            }
            "channel" => {
                let channel = text(&request, "channel")?.to_string();
                let subscribed = request["subscribed"]
                    .as_bool()
                    .ok_or_else(|| invalid("subscribed must be bool"))?;
                if e.client.session_active() {
                    e.client.session(|tx| tx.set_channel(channel, subscribed))?
                } else {
                    e.client
                        .transaction(|tx| tx.set_channel(channel, subscribed))?
                };
                Value::Null
            }
            _ => {
                if e.client.session_active() {
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
                    "tasks" => json!(e.client.pending_tasks()?),
                    "status" => {
                        json!({"clientId":e.client.client_id(),"pending":e.client.pending_count()?,"beforeImages":e.client.before_image_count()?,"cursors":e.client.subscriptions()?.into_iter().collect::<BTreeMap<_,_>>(),"channels":e.client.desired_channels()?,"rejections":e.client.rejections()?})
                    }
                    _ => return Err(invalid(format!("unknown client command {op}"))),
                }
            }
        };
        Ok(
            json!({"value":value,"changed":generation!=e.client.generation(),"changedTables":e.client.last_changed(),"generation":e.client.generation()}),
        )
    }
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .ok_or_else(|| invalid(format!("{key} must be string")))
}
