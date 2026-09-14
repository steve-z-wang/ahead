use serde_json::{Value, json};
mod emit;
pub use emit::{backend_typescript, client_typescript, dart, typescript};
#[derive(Clone, Debug)]
struct Token {
    text: String,
    line: usize,
    col: usize,
}
struct Parser {
    tokens: Vec<Token>,
    i: usize,
}
impl Parser {
    fn err(&self, msg: impl AsRef<str>) -> String {
        let t = &self.tokens[self.i.min(self.tokens.len() - 1)];
        format!(
            "{}:{}: {} (found '{}')",
            t.line,
            t.col,
            msg.as_ref(),
            t.text
        )
    }
    fn peek(&self) -> &str {
        &self.tokens[self.i].text
    }
    fn take(&mut self) -> String {
        let s = self.peek().to_string();
        if s != "<eof>" {
            self.i += 1;
        }
        s
    }
    fn eat(&mut self, s: &str) -> bool {
        if self.peek() == s {
            self.take();
            true
        } else {
            false
        }
    }
    fn need(&mut self, s: &str) -> Result<(), String> {
        if self.eat(s) {
            Ok(())
        } else {
            Err(self.err(format!("expected {s}")))
        }
    }
    fn ident(&mut self) -> Result<String, String> {
        let s = self.take();
        if s.chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            Ok(s)
        } else {
            Err(self.err("expected identifier"))
        }
    }
    fn expression(&mut self) -> Result<Value, String> {
        if self.eat("[") {
            let mut items = vec![];
            while !self.eat("]") {
                items.push(self.expression()?);
                if self.peek() != "]" {
                    self.need(",")?;
                }
            }
            return Ok(json!(items));
        }
        if self.peek().starts_with('"') {
            return serde_json::from_str(&self.take()).map_err(|_| self.err("invalid string"));
        }
        let mut name = self.ident()?;
        while self.eat(".") {
            name.push('.');
            name.push_str(&self.ident()?);
        }
        if self.peek() == "(" {
            return Ok(json!({"name":name,"arguments":self.arguments()?}));
        }
        Ok(json!(name))
    }
    fn arguments(&mut self) -> Result<Value, String> {
        self.need("(")?;
        let mut args = serde_json::Map::new();
        let mut positional = 0;
        while !self.eat(")") {
            let named = self.tokens.get(self.i + 1).is_some_and(|t| t.text == ":");
            let key = if named {
                let k = self.ident()?;
                self.need(":")?;
                k
            } else {
                let k = positional.to_string();
                positional += 1;
                k
            };
            let value = self.expression()?;
            if args.insert(key, value).is_some() {
                return Err(self.err("duplicate argument"));
            }
            if self.peek() != ")" {
                self.need(",")?;
            }
        }
        Ok(Value::Object(args))
    }
    fn names(&mut self, end: &str) -> Result<Vec<String>, String> {
        let mut n = vec![];
        while !self.eat(end) {
            n.push(self.ident()?);
            if self.peek() != end {
                self.need(",")?;
            }
        }
        Ok(n)
    }
}
fn lex(s: &str) -> Result<Vec<Token>, String> {
    let chars: Vec<_> = s.chars().collect();
    let (mut i, mut line, mut col) = (0, 1, 1);
    let mut out = vec![];
    while i < chars.len() {
        let c = chars[i];
        if c == '\n' {
            line += 1;
            col = 1;
            i += 1;
            continue;
        }
        if c.is_whitespace() {
            i += 1;
            col += 1;
            continue;
        }
        if c == '/' && chars.get(i + 1) == Some(&'/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
                col += 1;
            }
            continue;
        }
        let start = i;
        let column = col;
        if c.is_ascii_alphanumeric() || c == '_' {
            while i < chars.len() && (chars[i].is_ascii_alphanumeric() || chars[i] == '_') {
                i += 1;
                col += 1;
            }
        } else if c == '"' {
            i += 1;
            col += 1;
            while i < chars.len() && chars[i] != '"' {
                if chars[i] == '\\' {
                    i += 1;
                    col += 1;
                }
                i += 1;
                col += 1;
            }
            if i >= chars.len() {
                return Err(format!("{line}:{column}: unterminated string"));
            }
            i += 1;
            col += 1;
        } else if "{}()[]?,.@<>:".contains(c) {
            i += 1;
            col += 1;
        } else {
            return Err(format!("{line}:{col}: unsupported character {c}"));
        }
        out.push(Token {
            text: chars[start..i].iter().collect(),
            line,
            col: column,
        });
    }
    out.push(Token {
        text: "<eof>".into(),
        line,
        col,
    });
    Ok(out)
}
pub fn compile(source: &str) -> Result<Value, String> {
    let mut p = Parser {
        tokens: lex(source)?,
        i: 0,
    };
    let (mut models, mut enums, mut mutations, mut constraints) = (vec![], vec![], vec![], vec![]);
    let mut prerequisites = vec![];
    while p.peek() != "<eof>" {
        let kind = p.take();
        let name = p.ident()?;
        if kind == "prerequisite" {
            p.need("(")?;
            let mut fields = vec![];
            while !p.eat(")") {
                let field = p.ident()?;
                let ty = p.ident()?;
                fields.push(json!({"name":field,"type":ty}));
                if p.peek() != ")" {
                    p.need(",")?;
                }
            }
            prerequisites.push(json!({"name":name,"fields":fields}));
            continue;
        }
        p.need("{")?;
        match kind.as_str() {
            "enum" => {
                let mut values = vec![];
                while !p.eat("}") {
                    values.push(p.ident()?);
                    p.eat(",");
                }
                enums.push(json!({"name":name,"values":values}));
            }
            "model" => {
                let (mut fields, mut identity) = (vec![], vec![]);
                while !p.eat("}") {
                    if p.eat("@") {
                        p.need("@")?;
                        let attr = p.ident()?;
                        p.need("(")?;
                        let names = p.names(")")?;
                        match attr.as_str() {
                            "id" => {
                                if !identity.is_empty() {
                                    return Err(p.err("duplicate identity"));
                                }
                                identity = names
                            }
                            "unique" => constraints.push(json!({"model":name,"fields":names})),
                            _ => return Err(p.err(format!("unsupported model directive {attr}"))),
                        }
                        continue;
                    }
                    let field = p.ident()?;
                    let ty = p.ident()?;
                    let list = if p.eat("[") {
                        p.need("]")?;
                        true
                    } else {
                        false
                    };
                    let nullable = p.eat("?");
                    let mut attributes = serde_json::Map::new();
                    while p.peek() == "@" && p.tokens.get(p.i + 1).is_some_and(|t| t.text != "@") {
                        p.need("@")?;
                        let attr = p.ident()?;
                        if !["reference", "inverse", "requires"].contains(&attr.as_str()) {
                            return Err(p.err(format!("unsupported field directive {attr}")));
                        }
                        let args = p.arguments()?;
                        if attributes.insert(attr, args).is_some() {
                            return Err(p.err("duplicate field directive"));
                        }
                    }
                    fields.push(json!({"name":field,"typeName":ty,"list":list,"nullable":nullable,"attributes":attributes}));
                }
                models.push(json!({"name":name,"identity":identity,"fields":fields}));
            }
            "mutation" => {
                let (mut slots, mut version) = (vec![], 1);
                let mut sequence = Value::Null;
                let mut version_seen = false;
                while !p.eat("}") {
                    if p.eat("@") {
                        p.need("@")?;
                        let attr = p.ident()?;
                        if attr == "sequence" {
                            sequence = p.arguments()?;
                            continue;
                        }
                        if attr != "version" {
                            return Err(p.err(format!("unsupported mutation directive {attr}")));
                        }
                        if version_seen {
                            return Err(p.err("duplicate version"));
                        }
                        version_seen = true;
                        p.need("(")?;
                        version = p
                            .take()
                            .parse::<u64>()
                            .map_err(|_| p.err("expected positive version"))?;
                        if version == 0 || version > savoia_core::MAX_SAFE_INTEGER {
                            return Err(p.err("version must be positive"));
                        }
                        p.need(")")?;
                        continue;
                    }
                    let slot = p.ident()?;
                    let model = p.ident()?;
                    p.need(".")?;
                    let op = p.ident()?;
                    if !["create", "update", "delete"].contains(&op.as_str()) {
                        return Err(p.err("unknown operation"));
                    }
                    let allowed = if p.eat("<") {
                        if op != "update" {
                            return Err(p.err("field restriction requires update"));
                        }
                        Some(p.names(">")?)
                    } else {
                        None
                    };
                    let bindings = if p.peek() == "(" {
                        p.arguments()?
                    } else {
                        json!({})
                    };
                    let cardinality = if p.eat("[") {
                        p.need("]")?;
                        "list"
                    } else if p.eat("?") {
                        "optional"
                    } else {
                        "single"
                    };
                    let mut value =
                        json!({"name":slot,"model":model,"operation":op,"cardinality":cardinality});
                    if let Some(a) = allowed {
                        value["allowedPatchFields"] = json!(a)
                    }
                    value["relationBindings"] = bindings;
                    slots.push(value);
                }
                mutations
                    .push(json!({"name":name,"version":version,"slots":slots,"sequence":sequence}));
            }
            _ => return Err(p.err(format!("unsupported declaration {kind}"))),
        }
    }
    let raw_models = models.clone();
    let mut inverses = vec![];
    let mut requirements = vec![];
    for m in &mut models {
        let model_name = m["name"].clone();
        let mut relations = vec![];
        let mut stored = vec![];
        for f in m["fields"].as_array().unwrap() {
            if let Some(req) = f["attributes"].get("requires") {
                requirements.push(json!({"model":model_name,"field":f["name"],"invocation":req}));
            }
            if let Some(target) = raw_models
                .iter()
                .find(|target| target["name"] == f["typeName"])
            {
                if let Some(reference) = f["attributes"].get("reference") {
                    if f["list"] == true {
                        return Err(p.err("reference must be singular"));
                    }
                    if reference
                        .as_object()
                        .unwrap()
                        .keys()
                        .any(|k| !["0", "via", "onTargetDelete"].contains(&k.as_str()))
                    {
                        return Err(p.err("unknown reference argument"));
                    }
                    let fields = reference["via"]
                        .as_array()
                        .ok_or_else(|| p.err("reference requires via fields"))?;
                    if fields.len() != target["identity"].as_array().unwrap().len() {
                        return Err(p.err("reference identity arity mismatch"));
                    }
                    for (local, remote) in fields.iter().zip(target["identity"].as_array().unwrap())
                    {
                        let lf = m["fields"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|x| x["name"] == *local)
                            .ok_or_else(|| p.err("unknown reference field"))?;
                        let rf = target["fields"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .find(|x| x["name"] == *remote)
                            .ok_or_else(|| p.err("unknown target identity"))?;
                        if lf["typeName"] != rf["typeName"] || lf["list"] == true {
                            return Err(p.err("reference field type mismatch"));
                        }
                    }
                    let on_delete = reference
                        .get("onTargetDelete")
                        .cloned()
                        .unwrap_or(json!("none"));
                    if on_delete != "none" && on_delete != "delete" {
                        return Err(p.err("unsupported onTargetDelete"));
                    }
                    relations.push(json!({"name":f["name"],"target":target["name"],"fields":fields,"targetFields":target["identity"],"onDelete":on_delete}));
                } else {
                    inverses.push(json!({"model":model_name,"name":f["name"],"target":target["name"],"list":f["list"],"nullable":f["nullable"],"relationName":f["attributes"]["inverse"]["0"]}));
                }
                continue;
            }
            if f["attributes"].get("reference").is_some()
                || f["attributes"].get("inverse").is_some()
            {
                return Err(p.err("relation directive requires model type"));
            }
            stored.push(f.clone());
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
        for f in m["fields"].as_array_mut().unwrap() {
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
                return Err(p.err(format!("unknown or unsupported field type {ty}")));
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
    }
    for mutation in &mut mutations {
        let original_slots = mutation["slots"].as_array().unwrap().clone();
        for slot in mutation["slots"].as_array_mut().unwrap() {
            let mut bindings = vec![];
            for (relation, parent) in slot["relationBindings"].as_object().unwrap() {
                let model = models
                    .iter()
                    .find(|m| m["name"] == slot["model"])
                    .ok_or_else(|| p.err("unknown bound model"))?;
                let rel = model["relations"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|r| r["name"] == *relation)
                    .ok_or_else(|| p.err("unknown binding relation"))?;
                let parent_slot = original_slots
                    .iter()
                    .find(|s| s["name"] == *parent)
                    .ok_or_else(|| p.err("unknown parent slot"))?;
                if parent_slot["model"] != rel["target"] || parent_slot["cardinality"] != "single" {
                    return Err(p.err("binding parent must be single matching model"));
                }
                bindings.push(json!({"slot":parent,"fields":rel["fields"]}));
            }
            slot.as_object_mut().unwrap().remove("relationBindings");
            if !bindings.is_empty() {
                slot["bindings"] = json!(bindings)
            }
        }
    }
    for mutation in &mut mutations {
        for slot in mutation["slots"].as_array_mut().unwrap() {
            if slot["operation"] == "update" && slot.get("allowedPatchFields").is_none() {
                let model = models
                    .iter()
                    .find(|m| m["name"] == slot["model"])
                    .ok_or_else(|| p.err("unknown mutation model"))?;
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
    for inverse in &mut inverses {
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
            return Err(
                p.err("inverse must resolve to exactly one reference; use a shared relation name")
            );
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
                return Err(p.err("singular inverse requires unique reference fields"));
            }
        }
        inverse["reference"] = reference["name"].clone();
        inverse["fields"] = reference["attributes"]["reference"]["via"].clone();
    }
    let mut prerequisite_names = std::collections::BTreeSet::new();
    for declaration in &prerequisites {
        if !prerequisite_names.insert(declaration["name"].as_str().unwrap()) {
            return Err(p.err("duplicate prerequisite"));
        }
        let mut fields = std::collections::BTreeSet::new();
        for field in declaration["fields"].as_array().unwrap() {
            if !fields.insert(field["name"].as_str().unwrap())
                || ![
                    "String", "UUID", "DateTime", "Int", "Float", "Bool", "Boolean",
                ]
                .contains(&field["type"].as_str().unwrap())
            {
                return Err(p.err("invalid prerequisite field"));
            }
        }
    }
    for requirement in &requirements {
        let args = requirement["invocation"].as_object().unwrap();
        if args.len() != 1 || !args.contains_key("0") {
            return Err(p.err("requires expects one invocation"));
        }
        let invocation = &args["0"];
        let declaration = prerequisites
            .iter()
            .find(|d| d["name"] == invocation["name"])
            .ok_or_else(|| p.err("unknown prerequisite"))?;
        let arguments = invocation["arguments"]
            .as_object()
            .ok_or_else(|| p.err("requires expects invocation arguments"))?;
        if arguments.len() != declaration["fields"].as_array().unwrap().len() {
            return Err(p.err("prerequisite argument mismatch"));
        }
        for field in declaration["fields"].as_array().unwrap() {
            let expression = arguments
                .get(field["name"].as_str().unwrap())
                .ok_or_else(|| p.err("missing prerequisite argument"))?;
            if expression != "self" {
                return Err(p.err("prerequisite argument currently requires self"));
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
                return Err(p.err("prerequisite argument type mismatch"));
            }
        }
    }
    for mutation in &mutations {
        if !mutation["sequence"].is_null() {
            let sequence = mutation["sequence"].as_object().unwrap();
            if sequence.len() != 1 || !sequence.contains_key("after") {
                return Err(p.err("sequence requires after"));
            }
            let after = sequence["after"]
                .as_array()
                .ok_or_else(|| p.err("sequence after must be list"))?;
            for call in after {
                let target = mutations
                    .iter()
                    .find(|m| m["name"] == call["name"])
                    .ok_or_else(|| p.err("unknown sequence mutation"))?;
                let args = call["arguments"]
                    .as_object()
                    .ok_or_else(|| p.err("sequence requires invocation"))?;
                for (slot, expression) in args {
                    let target_slot = target["slots"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|s| s["name"] == *slot)
                        .ok_or_else(|| p.err("unknown sequence target slot"))?;
                    let mut parts = expression
                        .as_str()
                        .ok_or_else(|| p.err("sequence requires slot path"))?
                        .split('.');
                    let source_slot = mutation["slots"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|s| Some(s["name"].as_str().unwrap()) == parts.clone().next())
                        .ok_or_else(|| p.err("unknown sequence source slot"))?;
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
                            .ok_or_else(|| p.err("unknown sequence relation path"))?;
                        model = models
                            .iter()
                            .find(|m| m["name"] == relation["target"])
                            .unwrap();
                    }
                    if model["name"] != target_slot["model"] {
                        return Err(p.err("sequence target model mismatch"));
                    }
                }
            }
        }
    }
    requirements=requirements.into_iter().map(|r|json!({"model":r["model"],"field":r["field"],"name":r["invocation"]["0"]["name"],"arguments":r["invocation"]["0"]["arguments"]})).collect();
    let schema = json!({"models":models,"enums":enums,"requirements":requirements,"prerequisites":prerequisites,"clientPolicies":mutations});
    savoia_core::Schema::from_value(schema.clone()).map_err(|e| p.err(e.to_string()))?;
    let mut seen = std::collections::BTreeSet::new();
    for mutation in &mutations {
        if !seen.insert(mutation["name"].as_str().unwrap()) {
            return Err(p.err("duplicate mutation"));
        }
        let mut slots = std::collections::BTreeSet::new();
        if mutation["slots"].as_array().unwrap().is_empty() {
            return Err(p.err("mutation requires slots"));
        }
        for slot in mutation["slots"].as_array().unwrap() {
            if !slots.insert(slot["name"].as_str().unwrap()) {
                return Err(p.err("duplicate slot"));
            }
            let m = models
                .iter()
                .find(|m| m["name"] == slot["model"])
                .ok_or_else(|| p.err("unknown mutation model"))?;
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
                        return Err(p.err("invalid allowed patch field"));
                    }
                }
            }
        }
    }
    for c in &constraints {
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
            return Err(p.err("invalid unique fields"));
        }
    }
    Ok(
        json!({"schema":schema,"mutations":mutations,"loaders":models.iter().map(|m|m["name"].clone()).collect::<Vec<_>>(),"uniqueConstraints":constraints,"inverses":inverses,"requirements":requirements,"prerequisites":prerequisites}),
    )
}

mod history;
pub use history::{check_fence, reconcile_history};
