//! Validate: declarations to runtime descriptors and typed-interface input.
//! Every rule reachable from source reports the offending declaration; the
//! core descriptor check at the end is a backstop at the end of the input.
use crate::parse::{Declarations, Pos, at};
use serde_json::{Value, json};

/// Check the declarations and produce the compiler output consumed by
/// [`crate::emit`] and the CLI: `{schema, mutations, loaders, uniqueConstraints,
/// inverses, requirements, prerequisites}`.
pub fn validate(d: &Declarations) -> Result<Value, String> {
    // Working JSON for the semantic passes, with positions running parallel to
    // each vector so a failing rule can name its declaration.
    let enums: Vec<Value> = d
        .enums
        .iter()
        .map(|e| json!({"name":e.name,"values":e.values}))
        .collect();
    let mut models: Vec<Value> = vec![];
    let mut model_pos: Vec<Pos> = vec![];
    let mut field_pos: Vec<Vec<Pos>> = vec![];
    let mut constraints: Vec<Value> = vec![];
    let mut constraint_pos: Vec<Pos> = vec![];
    for m in &d.models {
        let fields: Vec<Value> = m
            .fields
            .iter()
            .map(|f| json!({"name":f.name,"typeName":f.type_name,"list":f.list,"nullable":f.nullable,"attributes":f.attributes}))
            .collect();
        models.push(json!({"name":m.name,"identity":m.identity,"fields":fields}));
        model_pos.push(m.pos);
        field_pos.push(m.fields.iter().map(|f| f.pos).collect());
        for u in &m.unique {
            constraints.push(json!({"model":m.name,"fields":u.fields}));
            constraint_pos.push(u.pos);
        }
    }
    let mut mutations: Vec<Value> = vec![];
    let mut mutation_pos: Vec<Pos> = vec![];
    let mut slot_pos: Vec<Vec<Pos>> = vec![];
    let mut sequence_pos: Vec<Option<Pos>> = vec![];
    for m in &d.mutations {
        let slots: Vec<Value> = m
            .slots
            .iter()
            .map(|s| {
                let mut value = json!({"name":s.name,"model":s.model,"operation":s.operation,"cardinality":s.cardinality});
                if let Some(a) = &s.allowed_patch_fields {
                    value["allowedPatchFields"] = json!(a)
                }
                value["relationBindings"] = s.relation_bindings.clone();
                value
            })
            .collect();
        let sequence = m
            .sequence
            .as_ref()
            .map(|s| s.arguments.clone())
            .unwrap_or(Value::Null);
        mutations
            .push(json!({"name":m.name,"version":m.version,"slots":slots,"sequence":sequence}));
        mutation_pos.push(m.pos);
        slot_pos.push(m.slots.iter().map(|s| s.pos).collect());
        sequence_pos.push(m.sequence.as_ref().map(|s| s.pos));
    }
    let prerequisites: Vec<Value> = d
        .prerequisites
        .iter()
        .map(|p| json!({"name":p.name,"fields":p.fields.iter().map(|f| json!({"name":f.name,"type":f.type_name})).collect::<Vec<_>>()}))
        .collect();
    let prerequisite_pos: Vec<Pos> = d.prerequisites.iter().map(|p| p.pos).collect();
    let prerequisite_field_pos: Vec<Vec<Pos>> = d
        .prerequisites
        .iter()
        .map(|p| p.fields.iter().map(|f| f.pos).collect())
        .collect();
    // Enum and model names in declaration order, for duplicate detection.
    let mut declared_names: Vec<(String, Pos)> = d
        .enums
        .iter()
        .map(|e| (e.name.clone(), e.pos))
        .chain(d.models.iter().map(|m| (m.name.clone(), m.pos)))
        .collect();
    declared_names.sort_by_key(|(_, pos)| (pos.line, pos.col));
    let eof = d.end;
    // Descriptor rules that core also enforces, checked here first so the
    // diagnostic names the declaration. Core remains the authority at load time.
    let mut seen_names = std::collections::BTreeSet::new();
    for (name, pos) in &declared_names {
        if !seen_names.insert(name.as_str()) {
            return Err(at(*pos, format!("duplicate declaration {name}")));
        }
    }
    for (mi, m) in models.iter().enumerate() {
        let name = m["name"].as_str().unwrap();
        if ahead_core::reserved_model_name(name) {
            return Err(at(
                model_pos[mi],
                format!("model name {name} uses a reserved prefix (ahead_, sqlite_)"),
            ));
        }
        let fields = m["fields"].as_array().unwrap();
        let mut seen_fields = std::collections::BTreeSet::new();
        for (fi, f) in fields.iter().enumerate() {
            if !seen_fields.insert(f["name"].as_str().unwrap()) {
                return Err(at(field_pos[mi][fi], "duplicate field"));
            }
            if f["list"] == true && f["nullable"] == true {
                return Err(at(field_pos[mi][fi], "lists cannot be nullable"));
            }
        }
        let identity = m["identity"].as_array().unwrap();
        if identity.is_empty() {
            return Err(at(model_pos[mi], "model requires an @@id identity"));
        }
        let mut seen_identity = std::collections::BTreeSet::new();
        for id in identity {
            let (fi, field) = fields
                .iter()
                .enumerate()
                .find(|(_, f)| f["name"] == *id)
                .ok_or_else(|| at(model_pos[mi], format!("identity field {id} missing")))?;
            if !seen_identity.insert(id.as_str().unwrap()) {
                return Err(at(model_pos[mi], format!("duplicate identity field {id}")));
            }
            if field["nullable"] == true || field["list"] == true {
                return Err(at(
                    field_pos[mi][fi],
                    "identity fields must be non-nullable scalars",
                ));
            }
        }
    }
    let raw_models = models.clone();
    let mut inverses = vec![];
    let mut inverse_pos: Vec<Pos> = vec![];
    let mut requirements = vec![];
    let mut requirement_pos: Vec<Pos> = vec![];
    for (mi, m) in models.iter_mut().enumerate() {
        let model_name = m["name"].clone();
        let mut relations = vec![];
        let mut stored = vec![];
        let mut stored_pos = vec![];
        for (fi, f) in m["fields"].as_array().unwrap().iter().enumerate() {
            let fpos = field_pos[mi][fi];
            if let Some(req) = f["attributes"].get("requires") {
                requirements.push(json!({"model":model_name,"field":f["name"],"invocation":req}));
                requirement_pos.push(fpos);
            }
            if let Some(target) = raw_models
                .iter()
                .find(|target| target["name"] == f["typeName"])
            {
                if let Some(reference) = f["attributes"].get("reference") {
                    if f["list"] == true {
                        return Err(at(fpos, "reference must be singular"));
                    }
                    if reference
                        .as_object()
                        .unwrap()
                        .keys()
                        .any(|k| !["0", "via", "onTargetDelete"].contains(&k.as_str()))
                    {
                        return Err(at(fpos, "unknown reference argument"));
                    }
                    let fields = reference["via"]
                        .as_array()
                        .ok_or_else(|| at(fpos, "reference requires via fields"))?;
                    if fields.len() != target["identity"].as_array().unwrap().len() {
                        return Err(at(fpos, "reference identity arity mismatch"));
                    }
                    for (local, remote) in fields.iter().zip(target["identity"].as_array().unwrap())
                    {
                        let lf = m["fields"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|x| x["name"] == *local)
                            .ok_or_else(|| at(fpos, "unknown reference field"))?;
                        let rf = target["fields"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|x| x["name"] == *remote)
                            .ok_or_else(|| at(fpos, "unknown target identity"))?;
                        if lf["typeName"] != rf["typeName"] || lf["list"] == true {
                            return Err(at(fpos, "reference field type mismatch"));
                        }
                    }
                    let on_delete = reference
                        .get("onTargetDelete")
                        .cloned()
                        .unwrap_or(json!("none"));
                    if on_delete != "none" && on_delete != "delete" {
                        return Err(at(fpos, "unsupported onTargetDelete"));
                    }
                    relations.push(json!({"name":f["name"],"target":target["name"],"fields":fields,"targetFields":target["identity"],"onDelete":on_delete}));
                } else {
                    inverses.push(json!({"model":model_name,"name":f["name"],"target":target["name"],"list":f["list"],"nullable":f["nullable"],"relationName":f["attributes"]["inverse"]["0"]}));
                    inverse_pos.push(fpos);
                }
                continue;
            }
            if f["attributes"].get("reference").is_some()
                || f["attributes"].get("inverse").is_some()
            {
                return Err(at(fpos, "relation directive requires model type"));
            }
            stored.push(f.clone());
            stored_pos.push(fpos);
        }
        m["fields"] = json!(stored);
        m["relations"] = json!(relations);
        m["unique"] = json!(
            constraints
                .iter()
                .filter(|c| c["model"] == model_name)
                .map(|c| c["fields"].clone())
                .collect::<Vec<_>>()
        );
        for (fi, f) in m["fields"].as_array_mut().unwrap().iter_mut().enumerate() {
            let ty = f["typeName"].as_str().unwrap();
            let scalar = match ty {
                "String" => Some("string"),
                "Bool" | "Boolean" => Some("boolean"),
                "Int" => Some("int"),
                "Float" => Some("float"),
                "UUID" => Some("uuid"),
                "DateTime" => Some("dateTime"),
                _ => None,
            };
            let mut t = if let Some(s) = scalar {
                json!({"kind":"scalar","name":s})
            } else if enums.iter().any(|e| e["name"] == ty) {
                json!({"kind":"enum","name":ty})
            } else {
                return Err(at(
                    stored_pos[fi],
                    format!("unknown or unsupported field type {ty}"),
                ));
            };
            if f["list"] == true {
                t = json!({"kind":"list","element":t})
            }
            let obj = f.as_object_mut().unwrap();
            obj.remove("attributes");
            obj.remove("typeName");
            obj.remove("list");
            obj.insert("type".into(), t);
        }
        let identity = m["identity"].as_array().unwrap();
        for f in m["fields"].as_array().unwrap() {
            if identity.contains(&f["name"]) && f["type"]["kind"] != "scalar" {
                let fi = m["fields"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .position(|x| x["name"] == f["name"])
                    .unwrap();
                return Err(at(
                    stored_pos[fi],
                    "identity fields must be non-nullable scalars",
                ));
            }
        }
    }
    for (mi, mutation) in mutations.iter_mut().enumerate() {
        let original_slots = mutation["slots"].as_array().unwrap().clone();
        for (si, slot) in mutation["slots"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .enumerate()
        {
            let spos = slot_pos[mi][si];
            let mut bindings = vec![];
            for (relation, parent) in slot["relationBindings"].as_object().unwrap() {
                let model = models
                    .iter()
                    .find(|m| m["name"] == slot["model"])
                    .ok_or_else(|| at(spos, "unknown bound model"))?;
                let rel = model["relations"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|r| r["name"] == *relation)
                    .ok_or_else(|| at(spos, "unknown binding relation"))?;
                let parent_slot = original_slots
                    .iter()
                    .find(|s| s["name"] == *parent)
                    .ok_or_else(|| at(spos, "unknown parent slot"))?;
                if parent_slot["model"] != rel["target"] || parent_slot["cardinality"] != "single" {
                    return Err(at(spos, "binding parent must be single matching model"));
                }
                bindings.push(json!({"slot":parent,"fields":rel["fields"]}));
            }
            slot.as_object_mut().unwrap().remove("relationBindings");
            if !bindings.is_empty() {
                slot["bindings"] = json!(bindings)
            }
        }
    }
    for (mi, mutation) in mutations.iter_mut().enumerate() {
        for (si, slot) in mutation["slots"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .enumerate()
        {
            if slot["operation"] == "update" && slot.get("allowedPatchFields").is_none() {
                let model = models
                    .iter()
                    .find(|m| m["name"] == slot["model"])
                    .ok_or_else(|| at(slot_pos[mi][si], "unknown mutation model"))?;
                slot["allowedPatchFields"] = json!(
                    model["fields"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .filter(|f| !model["identity"].as_array().unwrap().contains(&f["name"]))
                        .map(|f| f["name"].clone())
                        .collect::<Vec<_>>()
                );
            }
        }
    }
    for (k, inverse) in inverses.iter_mut().enumerate() {
        let ipos = inverse_pos[k];
        let target = raw_models
            .iter()
            .find(|m| m["name"] == inverse["target"])
            .unwrap();
        let candidates: Vec<_> = target["fields"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|f| {
                f["typeName"] == inverse["model"]
                    && f["attributes"].get("reference").is_some()
                    && (inverse["relationName"].is_null()
                        || f["attributes"]["reference"]["0"] == inverse["relationName"])
            })
            .collect();
        if candidates.len() != 1 {
            return Err(at(
                ipos,
                "inverse must resolve to exactly one reference; use a shared relation name",
            ));
        }
        let reference = candidates[0];
        if inverse["list"] != true {
            let fields = reference["attributes"]["reference"]["via"]
                .as_array()
                .unwrap();
            let same = |candidate: &Value| {
                candidate.as_array().is_some_and(|values| {
                    values.len() == fields.len() && fields.iter().all(|f| values.contains(f))
                })
            };
            let normalized = models.iter().find(|m| m["name"] == target["name"]).unwrap();
            if !same(&normalized["identity"])
                && !normalized["unique"].as_array().unwrap().iter().any(same)
            {
                return Err(at(
                    ipos,
                    "singular inverse requires unique reference fields",
                ));
            }
        }
        inverse["reference"] = reference["name"].clone();
        inverse["fields"] = reference["attributes"]["reference"]["via"].clone();
    }
    let mut prerequisite_names = std::collections::BTreeSet::new();
    for (k, declaration) in prerequisites.iter().enumerate() {
        if !prerequisite_names.insert(declaration["name"].as_str().unwrap()) {
            return Err(at(prerequisite_pos[k], "duplicate prerequisite"));
        }
        let mut fields = std::collections::BTreeSet::new();
        for (j, field) in declaration["fields"].as_array().unwrap().iter().enumerate() {
            if !fields.insert(field["name"].as_str().unwrap())
                || ![
                    "String", "UUID", "DateTime", "Int", "Float", "Bool", "Boolean",
                ]
                .contains(&field["type"].as_str().unwrap())
            {
                return Err(at(
                    prerequisite_field_pos[k][j],
                    "invalid prerequisite field",
                ));
            }
        }
    }
    for (k, requirement) in requirements.iter().enumerate() {
        let rpos = requirement_pos[k];
        let args = requirement["invocation"].as_object().unwrap();
        if args.len() != 1 || !args.contains_key("0") {
            return Err(at(rpos, "requires expects one invocation"));
        }
        let invocation = &args["0"];
        let declaration = prerequisites
            .iter()
            .find(|d| d["name"] == invocation["name"])
            .ok_or_else(|| at(rpos, "unknown prerequisite"))?;
        let arguments = invocation["arguments"]
            .as_object()
            .ok_or_else(|| at(rpos, "requires expects invocation arguments"))?;
        if arguments.len() != declaration["fields"].as_array().unwrap().len() {
            return Err(at(rpos, "prerequisite argument mismatch"));
        }
        for field in declaration["fields"].as_array().unwrap() {
            let expression = arguments
                .get(field["name"].as_str().unwrap())
                .ok_or_else(|| at(rpos, "missing prerequisite argument"))?;
            if expression != "self" {
                return Err(at(rpos, "prerequisite argument currently requires self"));
            }
            let model = raw_models
                .iter()
                .find(|m| m["name"] == requirement["model"])
                .unwrap();
            let source = model["fields"]
                .as_array()
                .unwrap()
                .iter()
                .find(|f| f["name"] == requirement["field"])
                .unwrap();
            if source["typeName"] != field["type"] {
                return Err(at(rpos, "prerequisite argument type mismatch"));
            }
        }
    }
    for (mi, mutation) in mutations.iter().enumerate() {
        if !mutation["sequence"].is_null() {
            let qpos = sequence_pos[mi].unwrap_or(mutation_pos[mi]);
            let sequence = mutation["sequence"].as_object().unwrap();
            if sequence.len() != 1 || !sequence.contains_key("after") {
                return Err(at(qpos, "sequence requires after"));
            }
            let after = sequence["after"]
                .as_array()
                .ok_or_else(|| at(qpos, "sequence after must be list"))?;
            for call in after {
                let target = mutations
                    .iter()
                    .find(|m| m["name"] == call["name"])
                    .ok_or_else(|| at(qpos, "unknown sequence mutation"))?;
                let args = call["arguments"]
                    .as_object()
                    .ok_or_else(|| at(qpos, "sequence requires invocation"))?;
                for (slot, expression) in args {
                    let target_slot = target["slots"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|s| s["name"] == *slot)
                        .ok_or_else(|| at(qpos, "unknown sequence target slot"))?;
                    let mut parts = expression
                        .as_str()
                        .ok_or_else(|| at(qpos, "sequence requires slot path"))?
                        .split('.');
                    let source_slot = mutation["slots"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|s| Some(s["name"].as_str().unwrap()) == parts.clone().next())
                        .ok_or_else(|| at(qpos, "unknown sequence source slot"))?;
                    parts.next();
                    let mut model = models
                        .iter()
                        .find(|m| m["name"] == source_slot["model"])
                        .unwrap();
                    for part in parts {
                        let relation = model["relations"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|r| r["name"] == part)
                            .ok_or_else(|| at(qpos, "unknown sequence relation path"))?;
                        model = models
                            .iter()
                            .find(|m| m["name"] == relation["target"])
                            .unwrap();
                    }
                    if model["name"] != target_slot["model"] {
                        return Err(at(qpos, "sequence target model mismatch"));
                    }
                }
            }
        }
    }
    requirements=requirements.into_iter().map(|r|json!({"model":r["model"],"field":r["field"],"name":r["invocation"]["0"]["name"],"arguments":r["invocation"]["0"]["arguments"]})).collect();
    let schema = json!({"models":models,"enums":enums,"requirements":requirements,"prerequisites":prerequisites,"clientPolicies":mutations});
    for (ci, c) in constraints.iter().enumerate() {
        let m = models.iter().find(|m| m["name"] == c["model"]).unwrap();
        if c["fields"].as_array().unwrap().is_empty()
            || c["fields"].as_array().unwrap().iter().any(|f| {
                !m["fields"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|x| x["name"] == *f)
            })
        {
            return Err(at(constraint_pos[ci], "invalid unique fields"));
        }
    }
    // Backstop: core validates the assembled descriptors. Rules reachable
    // from source are checked above with a location; anything left reports
    // the end of the input.
    ahead_core::Schema::from_value(schema.clone()).map_err(|e| at(eof, e.to_string()))?;
    let mut seen = std::collections::BTreeSet::new();
    for (mi, mutation) in mutations.iter().enumerate() {
        if !seen.insert(mutation["name"].as_str().unwrap()) {
            return Err(at(mutation_pos[mi], "duplicate mutation"));
        }
        let mut slots = std::collections::BTreeSet::new();
        if mutation["slots"].as_array().unwrap().is_empty() {
            return Err(at(mutation_pos[mi], "mutation requires slots"));
        }
        for (si, slot) in mutation["slots"].as_array().unwrap().iter().enumerate() {
            let spos = slot_pos[mi][si];
            if !slots.insert(slot["name"].as_str().unwrap()) {
                return Err(at(spos, "duplicate slot"));
            }
            let m = models
                .iter()
                .find(|m| m["name"] == slot["model"])
                .ok_or_else(|| at(spos, "unknown mutation model"))?;
            if let Some(fields) = slot["allowedPatchFields"].as_array() {
                let mut seen = std::collections::BTreeSet::new();
                for f in fields {
                    if !seen.insert(f.as_str().unwrap())
                        || m["identity"].as_array().unwrap().contains(f)
                        || !m["fields"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|x| x["name"] == *f)
                    {
                        return Err(at(spos, "invalid allowed patch field"));
                    }
                }
            }
        }
    }
    Ok(
        json!({"schema":schema,"mutations":mutations,"loaders":models.iter().map(|m|m["name"].clone()).collect::<Vec<_>>(),"uniqueConstraints":constraints,"inverses":inverses,"requirements":requirements,"prerequisites":prerequisites}),
    )
}
