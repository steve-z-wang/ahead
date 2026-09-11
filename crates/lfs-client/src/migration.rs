use super::*;
/// Explicit application migration. Only absent fields receive defaults; durable requests remain untouched.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SchemaMigration {
    #[serde(default)]
    pub defaults: Value,
    #[serde(default)]
    pub replay_pull: bool,
}
pub(super) fn migrate(
    state: &mut ClientState,
    schema: &Schema,
    options: &SchemaMigration,
) -> Result<()> {
    let old = Schema::from_value(state.schema.clone())?;
    for model in &old.models {
        let next = schema.model(&model.name)?;
        if model.identity != next.identity {
            return Err(invalid(
                "identity migration requires explicit data conversion",
            ));
        }
        for field in &model.fields {
            if !next.fields.iter().any(|f| f.name == field.name) {
                return Err(invalid("field removal requires explicit data conversion"));
            }
        }
    }
    let transform = |row: &mut StoredRecord| -> Result<()> {
        row.key = schema.record_key(&row.key.model, &row.key.identity)?;
        if let Some(defaults) = options
            .defaults
            .get(&row.key.model)
            .and_then(Value::as_object)
        {
            for (k, v) in defaults {
                if row.state.get(k).is_none() {
                    row.state[k] = v.clone();
                }
            }
        }
        row.state = schema.normalize_state(&row.key.model, &row.state)?;
        Ok(())
    };
    for row in state.records.values_mut() {
        transform(row)?;
    }
    for row in state.before.values_mut().flatten() {
        transform(row)?;
    }
    // Future optimistic replay uses the upgraded local shape. Frozen request bodies are immutable.
    for queued in &mut state.queue {
        for op in queued
            .mutation
            .operations
            .iter_mut()
            .chain(&mut queued.mutation.companion)
        {
            if op.op == OperationKind::Create {
                let mut row = StoredRecord {
                    key: schema.record_key(&op.model, &op.identity)?,
                    state: op
                        .values
                        .clone()
                        .ok_or_else(|| invalid("create data missing"))?,
                };
                transform(&mut row)?;
                op.values = Some(row.state);
            }
        }
    }
    state.schema = serde_json::to_value(schema)?;
    if options.replay_pull {
        for cursor in state.cursors.values_mut() {
            *cursor = 0;
        }
    }
    Ok(())
}
