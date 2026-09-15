use ahead_compiler::{Pos, compile, parse, validate};

const SOURCE: &str = "prerequisite Uploaded(key String)\nenum Status { active archived }\nmodel Parent {\n id UUID\n children Child[]\n @@id(id)\n @@unique(id)\n}\nmodel Child {\n id UUID\n parentId UUID\n label String @requires(Uploaded(key: self))\n parent Parent @reference(via: [parentId], onTargetDelete: delete)\n @@id(id)\n}\nmutation Add {\n parent Parent.create\n children Child.create(parent: parent)[]\n @@version(2)\n @@sequence(after: [Rename(parent: parent)])\n}\nmutation Rename { parent Parent.update<> }\n";

fn pos(line: usize, col: usize) -> Pos {
    Pos { line, col }
}

#[test]
fn parse_keeps_every_declaration_with_its_position() {
    let d = parse(SOURCE).unwrap();
    assert_eq!(d.prerequisites.len(), 1);
    assert_eq!(d.prerequisites[0].name, "Uploaded");
    assert_eq!(d.prerequisites[0].pos, pos(1, 1));
    assert_eq!(d.prerequisites[0].fields[0].name, "key");
    assert_eq!(d.prerequisites[0].fields[0].type_name, "String");
    assert_eq!(d.prerequisites[0].fields[0].pos, pos(1, 23));
    assert_eq!(d.enums[0].name, "Status");
    assert_eq!(d.enums[0].values, vec!["active", "archived"]);
    assert_eq!(d.enums[0].pos, pos(2, 1));
    let parent = &d.models[0];
    assert_eq!((parent.name.as_str(), parent.pos), ("Parent", pos(3, 1)));
    assert_eq!(parent.identity, vec!["id"]);
    assert_eq!(parent.fields[1].name, "children");
    assert!(parent.fields[1].list && !parent.fields[1].nullable);
    assert_eq!(parent.fields[1].pos, pos(5, 2));
    assert_eq!(parent.unique[0].fields, vec!["id"]);
    assert_eq!(parent.unique[0].pos, pos(7, 2));
    let child = &d.models[1];
    let label = &child.fields[2];
    assert_eq!(label.pos, pos(12, 2));
    assert_eq!(
        label.attributes["requires"],
        serde_json::json!({"0":{"name":"Uploaded","arguments":{"key":"self"}}})
    );
    assert_eq!(
        child.fields[3].attributes["reference"],
        serde_json::json!({"via":["parentId"],"onTargetDelete":"delete"})
    );
    let add = &d.mutations[0];
    assert_eq!(
        (add.name.as_str(), add.version, add.pos),
        ("Add", 2, pos(16, 1))
    );
    assert_eq!(add.slots[0].pos, pos(17, 2));
    assert_eq!(add.slots[1].cardinality, "list");
    assert_eq!(
        add.slots[1].relation_bindings,
        serde_json::json!({"parent":"parent"})
    );
    let sequence = add.sequence.as_ref().unwrap();
    assert_eq!(sequence.pos, pos(20, 2));
    assert_eq!(sequence.arguments["after"][0]["name"], "Rename");
    assert_eq!(d.mutations[1].slots[0].allowed_patch_fields, Some(vec![]));
    assert_eq!(d.end, pos(23, 1));
}

#[test]
fn parse_reports_syntax_errors_with_the_found_token_and_nothing_semantic() {
    let e =
        parse("model A { id UUID @@id(id) }\nmodel B { id Nope @@id(id) @@bogus(x) }").unwrap_err();
    assert!(e.starts_with("2:"), "{e}");
    assert!(e.contains("unsupported model directive bogus"), "{e}");
    assert!(e.contains("(found"), "{e}");
    // A semantic mistake (unknown type) parses fine; only validate refuses it.
    let d = parse("model B {\n id UUID\n label Nope\n @@id(id)\n}").unwrap();
    assert_eq!(d.models[0].fields[1].type_name, "Nope");
    let e = validate(&d).unwrap_err();
    assert!(e.starts_with("3:"), "{e}");
    assert!(e.contains("unknown or unsupported field type"), "{e}");
}

#[test]
fn compile_is_parse_then_validate_and_declarations_are_plain_data() {
    let d = parse(SOURCE).unwrap();
    assert_eq!(validate(&d).unwrap(), compile(SOURCE).unwrap());
    assert_eq!(parse(SOURCE).unwrap(), d, "parsing is deterministic");
    let copy = d.clone();
    assert_eq!(validate(&copy).unwrap(), validate(&d).unwrap());
}
