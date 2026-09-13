use serde_json::{Value, json};
fn config() -> Value {
    json!({"schema":{"enums":[],"models":[{"name":"Task","identity":["id"],"fields":[{"name":"id","type":{"kind":"scalar","name":"string"},"nullable":false},{"name":"title","type":{"kind":"scalar","name":"string"},"nullable":false},{"name":"note","type":{"kind":"scalar","name":"string"},"nullable":true}]}]},"loaders":["Task"],"mutations":[{"name":"edit","version":1,"slots":[{"name":"task","model":"Task","operation":"update","cardinality":"single","allowedPatchFields":["title"]}]}]})
}
#[test]
fn ordered_slot_decodes_known_fields_and_ignores_new_fields() {
    let args=otter_server::decode_arguments(&config(),&json!({"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a","future":1},"values":{"title":"hi","future":true}}]})).unwrap();
    assert_eq!(
        args,
        json!({"task":{"identity":{"id":"a"},"patch":{"title":"hi"}}})
    );
}
#[test]
fn known_disallowed_patch_is_explicit_refusal() {
    let err=otter_server::decode_arguments(&config(),&json!({"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a"},"values":{"note":"x"}}]})).unwrap_err();
    assert_eq!(err, "edit.not_allowed");
}
#[test]
fn undeclared_operation_is_invalid() {
    assert_eq!(otter_server::decode_arguments(&config(),&json!({"name":"edit","operations":[{"model":"Task","op":"delete","identity":{"id":"a"}}]})).unwrap_err(),"mutation.invalid");
}
#[test]
fn create_binding_mismatch_refuses_the_whole_act() {
    let mut c = config();
    c["mutations"] = json!([{"name":"createPair","version":1,"slots":[{"name":"parent","model":"Task","operation":"delete","cardinality":"single"},{"name":"child","model":"Task","operation":"create","cardinality":"single","bindings":[{"relation":"parent","fields":["note"],"slot":"parent"}]}]}]);
    let body = json!({"name":"createPair","operations":[{"model":"Task","op":"delete","identity":{"id":"a"}},{"model":"Task","op":"create","identity":{"id":"b"},"values":{"title":"child","note":"other"}}]});
    assert_eq!(
        otter_server::decode_arguments(&c, &body).unwrap_err(),
        "create_pair.invalid"
    );
}
#[test]
fn historical_known_field_outside_capability_is_refused() {
    let mut c = config();
    let mut input = c["schema"].clone();
    input["models"][0]["fields"]
        .as_array_mut()
        .unwrap()
        .retain(|f| f["name"] != "note");
    c["mutations"][0]["input"] = input;
    c["mutations"][0]["knownFields"] = json!({"Task":["id","title","note"]});
    let result = otter_server::decode_arguments(
        &c,
        &json!({"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a"},"values":{"title":"valid","note":"disallowed"}}]}),
    );
    assert_eq!(result.unwrap_err(), "edit.not_allowed");
}

#[test]
fn live_subscribe_requires_one_subscribe_frame_and_normalizes_scopes() {
    let decoded = otter_server::live::decode_subscribe(
        br#"{"type":"subscribe","scopes":["shared","alice","shared"]}"#,
    )
    .unwrap();
    assert_eq!(decoded, vec!["alice", "shared"]);
    assert!(otter_server::live::decode_subscribe(br#"{"type":"other","scopes":["a"]}"#).is_err());
    assert!(otter_server::live::decode_subscribe(br#"{"type":"subscribe","scopes":[]}"#).is_err());
}

#[test]
fn live_page_progression_uses_wire_cursor_and_fifty_row_boundary() {
    let full = json!({
        "scope":"shared", "fromCursor":7, "toCursor":57,
        "changes": (8..=57).map(|sync_id| json!({
            "syncId":sync_id,"model":"Task","identity":{"id":sync_id},"stamp":sync_id,"state":null
        })).collect::<Vec<_>>()
    });
    let progress = otter_server::live::page_progress(&full.to_string(), "shared", 7).unwrap();
    assert_eq!(progress.to_cursor, 57);
    assert!(progress.continues);

    let tail = json!({"scope":"shared","fromCursor":57,"toCursor":60,"changes":[]});
    let progress = otter_server::live::page_progress(&tail.to_string(), "shared", 57).unwrap();
    assert_eq!(progress.to_cursor, 60);
    assert!(!progress.continues);
}
#[test]
fn startup_rejects_invalid_patch_capabilities() {
    for fields in [json!(["id"]), json!(["missing"]), json!(["title", "title"])] {
        let mut c = config();
        c["mutations"][0]["slots"][0]["allowedPatchFields"] = fields;
        assert!(otter_server::Config::decode(c).is_err());
    }
    let mut c = config();
    c["mutations"][0]["slots"][0]["operation"] = json!("delete");
    assert!(otter_server::Config::decode(c).is_err());
}
