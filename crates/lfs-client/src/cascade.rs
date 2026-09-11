use super::*;
pub(super) fn descendants(
    schema: &Schema,
    state: &ClientState,
    parent: &RecordKey,
) -> Result<Vec<RecordKey>> {
    let mut candidates = state.records.clone();
    for (k, v) in &state.before {
        if let Some(row) = v {
            candidates.entry(k.clone()).or_insert_with(|| row.clone());
        }
    }
    let mut seen = BTreeSet::from([parent.encoded()?]);
    let mut todo = vec![parent.clone()];
    let mut result = vec![];
    while let Some(parent) = todo.pop() {
        for (encoded, row) in &candidates {
            if seen.contains(encoded) {
                continue;
            }
            for relation in &schema.model(&row.key.model)?.relations {
                if relation.target != parent.model || relation.on_delete != "delete" {
                    continue;
                }
                let matches =
                    relation
                        .fields
                        .iter()
                        .zip(&relation.target_fields)
                        .all(|(local, target)| {
                            row.key.identity.get(local).or_else(|| row.state.get(local))
                                == parent.identity.get(target)
                        });
                if matches {
                    seen.insert(encoded.clone());
                    todo.push(row.key.clone());
                    result.push(row.key.clone());
                    break;
                }
            }
        }
    }
    Ok(result)
}
pub(super) fn refresh_pending(schema: &Schema, state: &mut ClientState) -> Result<()> {
    let deletions: Vec<_> = state
        .queue
        .iter()
        .flat_map(|q| {
            q.mutation
                .operations
                .iter()
                .chain(&q.mutation.companion)
                .filter(|op| op.op == OperationKind::Delete)
                .map(move |op| (q.ordinal, op.clone()))
        })
        .collect();
    for (ordinal, op) in deletions {
        let parent = schema.record_key(&op.model, &op.identity)?;
        for child in descendants(schema, state, &parent)? {
            let encoded = child.encoded()?;
            let already = state
                .queue
                .iter()
                .find(|q| q.ordinal == ordinal)
                .is_some_and(|q| {
                    q.mutation
                        .effects
                        .iter()
                        .any(|op| op.model == child.model && op.identity == child.identity)
                });
            if already {
                continue;
            }
            if !dirty(schema, state, &encoded)? {
                state
                    .before
                    .insert(encoded.clone(), state.records.get(&encoded).cloned());
            }
            let q = state
                .queue
                .iter_mut()
                .find(|q| q.ordinal == ordinal)
                .ok_or_else(|| invalid("cascade owner missing"))?;
            q.mutation.effects.push(Operation {
                model: child.model,
                identity: child.identity,
                op: OperationKind::Delete,
                values: None,
            });
            rebuild(schema, state, &encoded)?;
        }
    }
    Ok(())
}
