use super::*;
use std::cmp::Ordering;
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
fn compare(a: &Value, b: &Value) -> Ordering {
    match (a, b) {
        (Value::Null, Value::Null) => Ordering::Equal,
        (Value::Null, _) => Ordering::Less,
        (_, Value::Null) => Ordering::Greater,
        (Value::String(a), Value::String(b)) => a.encode_utf16().cmp(b.encode_utf16()),
        (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
        (Value::Number(a), Value::Number(b)) => a.as_f64().unwrap().total_cmp(&b.as_f64().unwrap()),
        _ => Ordering::Equal,
    }
}
pub(super) fn evaluate(
    schema: &Schema,
    state: &ClientState,
    model: &str,
    spec: &QuerySpec,
) -> Result<Vec<Value>> {
    let model = schema.model(model)?;
    let field = |name: &str| {
        model
            .fields
            .iter()
            .find(|f| f.name == name)
            .ok_or_else(|| invalid(format!("unknown query field {name}")))
    };
    let mut filter = vec![];
    for (name, value) in &spec.filter {
        let field = field(name)?;
        if matches!(field.value_type, ValueType::List { .. }) {
            return Err(invalid("list predicates unsupported"));
        }
        filter.push((name, schema.normalize_value(field, value)?));
    }
    for order in &spec.order_by {
        if !matches!(field(&order.field)?.value_type, ValueType::Scalar { .. }) {
            return Err(invalid("ordering requires scalar field"));
        }
    }
    let mut rows = vec![];
    for row in state.records.values().filter(|r| r.key.model == model.name) {
        if let Some(value) = read(schema, state, &row.key)?
            && filter.iter().all(|(k, v)| value.get(*k) == Some(v))
        {
            rows.push(value);
        }
    }
    rows.sort_by(|a, b| {
        for order in &spec.order_by {
            let cmp = compare(&a[&order.field], &b[&order.field]);
            let cmp = match order.direction {
                Direction::Ascending => cmp,
                Direction::Descending => cmp.reverse(),
            };
            if cmp != Ordering::Equal {
                return cmp;
            }
        }
        for field in &model.identity {
            let cmp = compare(&a[field], &b[field]);
            if cmp != Ordering::Equal {
                return cmp;
            }
        }
        Ordering::Equal
    });
    if let Some(limit) = spec.limit {
        rows.truncate(limit);
    }
    Ok(rows)
}
pub(super) fn related(
    schema: &Schema,
    state: &ClientState,
    key: &RecordKey,
    name: &str,
) -> Result<Option<Value>> {
    let key = schema.record_key(&key.model, &key.identity)?;
    let relation = schema
        .model(&key.model)?
        .relations
        .iter()
        .find(|r| r.name == name)
        .ok_or_else(|| invalid("unknown relation"))?;
    let Some(row) = read(schema, state, &key)? else {
        return Ok(None);
    };
    let mut identity = serde_json::Map::new();
    for (local, target) in relation.fields.iter().zip(&relation.target_fields) {
        if row[local].is_null() {
            return Ok(None);
        }
        identity.insert(target.clone(), row[local].clone());
    }
    read(
        schema,
        state,
        &schema.record_key(&relation.target, &Value::Object(identity))?,
    )
}
pub(super) fn referencing(
    schema: &Schema,
    state: &ClientState,
    key: &RecordKey,
    source: &str,
    name: &str,
) -> Result<Vec<Value>> {
    let key = schema.record_key(&key.model, &key.identity)?;
    let relation = schema
        .model(source)?
        .relations
        .iter()
        .find(|r| r.name == name && r.target == key.model)
        .ok_or_else(|| invalid("unknown inverse relation"))?;
    let filter = relation
        .fields
        .iter()
        .zip(&relation.target_fields)
        .map(|(local, target)| (local.clone(), key.identity[target].clone()))
        .collect();
    evaluate(
        schema,
        state,
        source,
        &QuerySpec {
            filter,
            ..Default::default()
        },
    )
}
