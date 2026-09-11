//! SQLite implements the client's atomic persistence capability.
mod query;
use lfs_client::{ClientState, ClientStore};
use lfs_core::{Result, invalid};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value};
use std::path::Path;

pub struct SqliteStore {
    connection: Connection,
}
impl SqliteStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path).map_err(db)?;
        connection
            .busy_timeout(std::time::Duration::from_secs(5))
            .map_err(db)?;
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE IF NOT EXISTS lfs_meta (id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL); INSERT OR IGNORE INTO lfs_meta VALUES(1,0); CREATE TABLE IF NOT EXISTS lfs_documents (bucket TEXT NOT NULL,key TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(bucket,key));").map_err(db)?;
        Ok(Self { connection })
    }
}
fn db(e: rusqlite::Error) -> lfs_core::Error {
    invalid(format!("sqlite: {e}"))
}
impl ClientStore for SqliteStore {
    fn read_sql(
        &mut self,
        schema: &lfs_core::Schema,
        state: &ClientState,
        sql: &str,
        parameters: &[Value],
    ) -> Result<Vec<Value>> {
        query::evaluate(schema, state, sql, parameters)
    }
    fn load(&mut self) -> Result<Option<(u64, ClientState)>> {
        let tx = self.connection.transaction().map_err(db)?;
        let generation: i64 = tx
            .query_row("SELECT generation FROM lfs_meta WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(db)?;
        let generation =
            u64::try_from(generation).map_err(|_| invalid("negative storage generation"))?;
        if generation == 0 {
            return Ok(None);
        }
        let mut document = Map::new();
        {
            let mut statement = tx
                .prepare("SELECT bucket,key,value FROM lfs_documents ORDER BY bucket,key")
                .map_err(db)?;
            let rows = statement
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                })
                .map_err(db)?;
            for row in rows {
                let (bucket, key, value) = row.map_err(db)?;
                let value: Value = serde_json::from_str(&value)?;
                if bucket == "meta" {
                    document.insert(key, value);
                } else {
                    document
                        .entry(bucket)
                        .or_insert_with(|| Value::Object(Map::new()))
                        .as_object_mut()
                        .ok_or_else(|| invalid("storage bucket corrupted"))?
                        .insert(key, value);
                }
            }
        }
        for name in ["records", "before", "cursors", "claims", "readiness"] {
            document
                .entry(name)
                .or_insert_with(|| Value::Object(Map::new()));
        }
        let state = serde_json::from_value(Value::Object(document))?;
        tx.commit().map_err(db)?;
        Ok(Some((generation, state)))
    }
    fn commit(&mut self, expected_generation: u64, state: &ClientState) -> Result<u64> {
        let next = expected_generation
            .checked_add(1)
            .filter(|v| *v <= i64::MAX as u64)
            .ok_or_else(|| invalid("storage generation exhausted"))?;
        let tx = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(db)?;
        if tx
            .execute(
                "UPDATE lfs_meta SET generation=? WHERE id=1 AND generation=?",
                params![next as i64, expected_generation as i64],
            )
            .map_err(db)?
            != 1
        {
            return Err(invalid("stale client writer; reopen runtime"));
        }
        let value = serde_json::to_value(state)?;
        let mut desired = std::collections::BTreeMap::new();
        for (name, value) in value
            .as_object()
            .ok_or_else(|| invalid("state must be object"))?
        {
            if ["records", "before", "cursors", "claims", "readiness"].contains(&name.as_str()) {
                for (key, value) in value
                    .as_object()
                    .ok_or_else(|| invalid("bucket must be object"))?
                {
                    desired.insert((name.clone(), key.clone()), serde_json::to_string(value)?);
                }
            } else {
                desired.insert(("meta".into(), name.clone()), serde_json::to_string(value)?);
            }
        }
        let existing: Vec<(String, String)> = {
            let mut statement = tx
                .prepare("SELECT bucket,key FROM lfs_documents")
                .map_err(db)?;
            statement
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(db)?
                .collect::<std::result::Result<_, _>>()
                .map_err(db)?
        };
        for (bucket, key) in existing {
            if !desired.contains_key(&(bucket.clone(), key.clone())) {
                tx.execute(
                    "DELETE FROM lfs_documents WHERE bucket=? AND key=?",
                    params![bucket, key],
                )
                .map_err(db)?;
            }
        }
        for ((bucket, key), value) in desired {
            let current: Option<String> = tx
                .query_row(
                    "SELECT value FROM lfs_documents WHERE bucket=? AND key=?",
                    params![bucket, key],
                    |r| r.get(0),
                )
                .optional()
                .map_err(db)?;
            if current.as_deref() != Some(&value) {
                tx.execute("INSERT INTO lfs_documents(bucket,key,value) VALUES(?,?,?) ON CONFLICT(bucket,key) DO UPDATE SET value=excluded.value",params![bucket,key,value]).map_err(db)?;
            }
        }
        tx.commit().map_err(db)?;
        Ok(next)
    }
}
