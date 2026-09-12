use serde_json::{Value, json};
fn list<'a>(v: &'a Value, k: &str) -> Result<&'a Vec<Value>, String> {
    v[k].as_array()
        .ok_or_else(|| format!("history: expected {k} array"))
}
fn named<'a>(items: &'a [Value], name: &Value) -> Option<&'a Value> {
    items.iter().find(|item| item["name"] == *name)
}
/// Preserve historical mutation inputs independently of today's storage schema.
pub fn reconcile_history(current: &Value, history: Option<&Value>) -> Result<Value, String> {
    let mut result = history
        .cloned()
        .unwrap_or(json!({"formatVersion":1,"mutations":{}}));
    if result["formatVersion"] != 1 || !result["mutations"].is_object() {
        return Err("unsupported mutation history format".into());
    }
    let mutations = list(current, "mutations")?;
    for name in result["mutations"].as_object().unwrap().keys() {
        if !mutations.iter().any(|m| m["name"] == *name) {
            return Err(format!("retained mutation {name} cannot be removed"));
        }
    }
    for mutation in mutations {
        let name = mutation["name"].as_str().ok_or("unnamed mutation")?;
        let version = mutation["version"]
            .as_u64()
            .ok_or("invalid mutation version")?;
        let snapshot = capture(current, mutation)?;
        let versions = result["mutations"]
            .as_object_mut()
            .unwrap()
            .entry(name)
            .or_insert(json!({}))
            .as_object_mut()
            .ok_or("invalid history versions")?;
        let latest = versions
            .keys()
            .map(|v| v.parse::<u64>().map_err(|_| "invalid retained version"))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .max()
            .unwrap_or(0);
        if version < latest {
            return Err(format!("{name}: version cannot decrease from {latest}"));
        }
        if let Some(previous) = versions.get(&version.to_string())
            && !compatible(previous, &snapshot)?
        {
            return Err(format!(
                "{name} v{version}: incompatible input change; increase @@version"
            ));
        }
        versions.insert(version.to_string(), snapshot);
    }
    // A retained input may still invoke a prerequisite after a version upgrade.
    for versions in result["mutations"].as_object().unwrap().values() {
        for snapshot in versions
            .as_object()
            .ok_or("invalid history versions")?
            .values()
        {
            for requirement in snapshot["requirements"].as_array().unwrap_or(&vec![]) {
                let declaration = current["prerequisites"]
                    .as_array()
                    .and_then(|d| named(d, &requirement["name"]));
                let retained = snapshot["prerequisites"]
                    .as_array()
                    .and_then(|d| named(d, &requirement["name"]));
                if declaration != retained {
                    return Err(format!(
                        "retained mutation still requires original prerequisite {}",
                        requirement["name"]
                    ));
                }
            }
        }
    }
    Ok(result)
}
fn capture(config: &Value, mutation: &Value) -> Result<Value, String> {
    let slots = list(mutation, "slots")?;
    let mut models = vec![];
    let mut enum_names = std::collections::BTreeSet::new();
    let mut known = serde_json::Map::new();
    for model in list(&config["schema"], "models")? {
        let used: Vec<_> = slots
            .iter()
            .filter(|s| s["model"] == model["name"])
            .collect();
        if used.is_empty() {
            continue;
        }
        let identity = list(model, "identity")?;
        let fields = list(model, "fields")?;
        known.insert(
            model["name"].as_str().unwrap().into(),
            json!(fields.iter().map(|f| f["name"].clone()).collect::<Vec<_>>()),
        );
        let selected: Vec<_> = fields
            .iter()
            .filter(|f| {
                identity.contains(&f["name"])
                    || used.iter().any(|s| {
                        s["operation"] == "create"
                            || (s["operation"] == "update"
                                && s["allowedPatchFields"]
                                    .as_array()
                                    .is_none_or(|a| a.contains(&f["name"])))
                    })
            })
            .cloned()
            .collect();
        for field in &selected {
            if field["type"]["kind"] == "enum" {
                enum_names.insert(field["type"]["name"].as_str().unwrap().to_string());
            }
        }
        models.push(json!({"name":model["name"],"identity":identity,"fields":selected}));
    }
    let enums: Vec<_> = list(&config["schema"], "enums")?
        .iter()
        .filter(|e| enum_names.contains(e["name"].as_str().unwrap()))
        .cloned()
        .collect();
    let requirements: Vec<_> = config["requirements"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter(|r| {
            models.iter().any(|m| {
                m["name"] == r["model"]
                    && m["fields"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|f| f["name"] == r["field"])
            })
        })
        .cloned()
        .collect();
    let prerequisites: Vec<_> = config["prerequisites"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter(|p| requirements.iter().any(|r| r["name"] == p["name"]))
        .cloned()
        .collect();
    Ok(
        json!({"name":mutation["name"],"version":mutation["version"],"slots":slots,"input":{"models":models,"enums":enums},"knownFields":known,"requirements":requirements,"prerequisites":prerequisites,"sequence":mutation["sequence"]}),
    )
}
fn compatible(old: &Value, new: &Value) -> Result<bool, String> {
    let a = list(old, "slots")?;
    let b = list(new, "slots")?;
    if a.len() != b.len() {
        return Ok(false);
    }
    for (a, b) in a.iter().zip(b) {
        let mut left = a.clone();
        let mut right = b.clone();
        let old_patch = left
            .as_object_mut()
            .ok_or("invalid slot")?
            .remove("allowedPatchFields");
        let new_patch = right
            .as_object_mut()
            .ok_or("invalid slot")?
            .remove("allowedPatchFields");
        if left != right {
            return Ok(false);
        }
        if let Some(old_patch) = old_patch
            && !old_patch
                .as_array()
                .ok_or("invalid patch fields")?
                .iter()
                .all(|f| {
                    new_patch
                        .as_ref()
                        .and_then(Value::as_array)
                        .is_some_and(|a| a.contains(f))
                })
        {
            return Ok(false);
        }
    }
    for en in list(&old["input"], "enums")? {
        let Some(next) = named(list(&new["input"], "enums")?, &en["name"]) else {
            return Ok(false);
        };
        if !list(en, "values")?
            .iter()
            .all(|v| next["values"].as_array().unwrap().contains(v))
        {
            return Ok(false);
        }
    }
    for model in list(&old["input"], "models")? {
        let Some(next) = named(list(&new["input"], "models")?, &model["name"]) else {
            return Ok(false);
        };
        if model["identity"] != next["identity"] {
            return Ok(false);
        }
        for field in list(model, "fields")? {
            if named(list(next, "fields")?, &field["name"]) != Some(field) {
                return Ok(false);
            }
        }
        if b.iter()
            .any(|s| s["model"] == model["name"] && s["operation"] == "create")
        {
            for field in list(next, "fields")? {
                if named(list(model, "fields")?, &field["name"]).is_none()
                    && field["nullable"] != true
                {
                    return Ok(false);
                }
            }
        }
    }
    if old["requirements"] != new["requirements"] || old["sequence"] != new["sequence"] {
        return Ok(false);
    }
    Ok(true)
}
/// Preserve the reference published model/field-name fence. Stronger type/identity fences are deferred.
pub fn check_fence(before: &Value, after: &Value) -> Result<(), String> {
    for model in list(before, "models")? {
        let next = named(list(after, "models")?, &model["name"])
            .ok_or_else(|| format!("schema fence: published model {} removed", model["name"]))?;
        for field in list(model, "fields")? {
            named(list(next, "fields")?, &field["name"]).ok_or_else(|| {
                format!(
                    "schema fence: published field {}.{} removed",
                    model["name"], field["name"]
                )
            })?;
        }
    }
    Ok(())
}
