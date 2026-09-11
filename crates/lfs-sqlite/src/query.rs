//! SQL is evaluated on an isolated snapshot, never against writable persistence internals.
use super::*;
use lfs_core::{ScalarType, Schema, ValueType};
use rusqlite::types::{Value as SqlValue, ValueRef};
fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}
fn parameter(value: &Value) -> Result<SqlValue> {
    Ok(match value {
        Value::Null => SqlValue::Null,
        Value::Bool(v) => SqlValue::Integer(i64::from(*v)),
        Value::Number(v) => {
            if let Some(v) = v.as_i64() {
                SqlValue::Integer(v)
            } else {
                SqlValue::Real(v.as_f64().ok_or_else(|| invalid("invalid SQL number"))?)
            }
        }
        Value::String(v) => SqlValue::Text(v.clone()),
        Value::Array(_) | Value::Object(_) => SqlValue::Text(serde_json::to_string(value)?),
    })
}
pub(super) fn evaluate(
    schema: &Schema,
    state: &ClientState,
    sql: &str,
    parameters: &[Value],
) -> Result<Vec<Value>> {
    let first = sql
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    if !["select", "with", "explain"].contains(&first.as_str()) {
        return Err(invalid("only read-only SQL queries are supported"));
    }
    let mut connection = Connection::open_in_memory().map_err(db)?;
    let tx = connection.transaction().map_err(db)?;
    for model in &schema.models {
        let columns = model
            .fields
            .iter()
            .map(|field| {
                let ty = match field.value_type {
                    ValueType::Scalar {
                        name: ScalarType::Boolean | ScalarType::Int,
                    } => "INTEGER",
                    ValueType::Scalar {
                        name: ScalarType::Float,
                    } => "REAL",
                    _ => "TEXT",
                };
                format!("{} {ty}", quote(&field.name))
            })
            .collect::<Vec<_>>()
            .join(",");
        tx.execute_batch(&format!("CREATE TABLE {} ({columns})", quote(&model.name)))
            .map_err(db)?;
        let placeholders = vec!["?"; model.fields.len()].join(",");
        let mut insert = tx
            .prepare(&format!(
                "INSERT INTO {} VALUES ({placeholders})",
                quote(&model.name)
            ))
            .map_err(db)?;
        for row in state.records.values().filter(|r| r.key.model == model.name) {
            let values = model
                .fields
                .iter()
                .map(|field| {
                    parameter(
                        row.key
                            .identity
                            .get(&field.name)
                            .or_else(|| row.state.get(&field.name))
                            .unwrap_or(&Value::Null),
                    )
                })
                .collect::<Result<Vec<_>>>()?;
            insert
                .execute(rusqlite::params_from_iter(values))
                .map_err(db)?;
        }
    }
    tx.commit().map_err(db)?;
    connection
        .execute_batch("PRAGMA query_only=ON")
        .map_err(db)?;
    let mut statement = connection.prepare(sql).map_err(db)?;
    if !statement.readonly() || statement.column_count() == 0 {
        return Err(invalid("SQL write statements are forbidden"));
    }
    let names = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if names
        .iter()
        .collect::<std::collections::BTreeSet<_>>()
        .len()
        != names.len()
    {
        return Err(invalid(
            "SQL result column names must be unique; use aliases",
        ));
    }
    let values = parameters
        .iter()
        .map(parameter)
        .collect::<Result<Vec<_>>>()?;
    let mut rows = statement
        .query(rusqlite::params_from_iter(values))
        .map_err(db)?;
    let mut output = vec![];
    while let Some(row) = rows.next().map_err(db)? {
        let mut value = Map::new();
        for (i, name) in names.iter().enumerate() {
            let v = match row.get_ref(i).map_err(db)? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(v) => Value::from(v),
                ValueRef::Real(v) => Value::from(v),
                ValueRef::Text(v) => Value::from(
                    std::str::from_utf8(v).map_err(|_| invalid("SQL text must be UTF8"))?,
                ),
                ValueRef::Blob(_) => {
                    return Err(invalid("SQL blobs cannot cross the JSON boundary"));
                }
            };
            value.insert(name.clone(), v);
        }
        output.push(Value::Object(value));
    }
    Ok(output)
}
