//! Reads over the visible rows: filtered model queries and raw read-only SQL.
use crate::engine::Engine;
use crate::store::{ClientStore, SqlRows};
use otter_core::{Result, ValueType, invalid};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuerySpec {
    #[serde(default)]
    pub filter: BTreeMap<String, Value>,
    #[serde(default)]
    pub order_by: Vec<QueryOrder>,
    pub limit: Option<usize>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct QueryOrder {
    pub field: String,
    pub direction: Direction,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    Ascending,
    Descending,
}

/// Equality filters only; Task 9 adds ordering and limits.
pub fn evaluate<S: ClientStore>(
    engine: &mut Engine<'_, S>,
    model: &str,
    spec: &QuerySpec,
) -> Result<Vec<Value>> {
    let schema = engine.schema;
    let model = schema.model(model)?.clone();
    let mut filter = vec![];
    for (name, value) in &spec.filter {
        let field = model
            .fields
            .iter()
            .find(|f| &f.name == name)
            .ok_or_else(|| invalid(format!("unknown query field {name}")))?;
        if matches!(field.value_type, ValueType::List { .. }) {
            return Err(invalid("list predicates unsupported"));
        }
        filter.push((name.clone(), schema.normalize_value(field, value)?));
    }
    engine.rows_where(&model.name, &model, &filter)
}

pub(crate) fn rows_to_objects(rows: SqlRows) -> Result<Vec<Value>> {
    if rows.columns.iter().collect::<BTreeSet<_>>().len() != rows.columns.len() {
        return Err(invalid(
            "SQL result column names must be unique; use aliases",
        ));
    }
    Ok(rows
        .rows
        .into_iter()
        .map(|row| Value::Object(rows.columns.iter().cloned().zip(row).collect()))
        .collect())
}
