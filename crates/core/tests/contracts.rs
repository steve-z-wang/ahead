use ahead_core::*;
use serde_json::{Value, json};

fn schema() -> Schema {
    Schema::from_value(
        json!({"enums": [{"name":"Mood","values":["calm","busy"]}], "models":[{
            "name":"Entry", "identity":["id"], "fields":[
                {"name":"id","type":{"kind":"scalar","name":"uuid"},"nullable":false},
                {"name":"text","type":{"kind":"scalar","name":"string"},"nullable":false},
                {"name":"note","type":{"kind":"scalar","name":"string"},"nullable":true},
                {"name":"count","type":{"kind":"scalar","name":"int"},"nullable":false}
            ]
        }]}),
    )
    .unwrap()
}
const ID: &str = "01890F47-1234-7123-8123-123456789ABC";

#[test]
fn identities_are_exact_normalized_and_independent_of_channels() {
    let schema = schema();
    let key = schema.record_key("Entry", &json!({"id":ID})).unwrap();
    assert_eq!(key.identity, json!({"id":ID.to_lowercase()}));
    assert_eq!(
        key.encoded_identity().unwrap(),
        format!("{{\"id\":\"{}\"}}", ID.to_lowercase())
    );
    assert!(
        schema
            .record_key("Entry", &json!({"id":ID,"channel":"book"}))
            .is_err()
    );
    assert!(schema.record_key("Entry", &json!({"id":"bad"})).is_err());
}

#[test]
fn state_is_complete_but_patch_preserves_absent_and_null() {
    let s = schema();
    assert_eq!(
        s.normalize_state("Entry", &json!({"id":ID,"text":"a","count":0}))
            .unwrap(),
        json!({"text":"a","count":0,"note":null})
    );
    assert!(s.validate_state("Entry", &json!({"count":0})).is_err());
    assert_eq!(
        s.validate_patch("Entry", &json!({"note":null})).unwrap(),
        json!({"note":null})
    );
    assert_eq!(s.validate_patch("Entry", &json!({})).unwrap(), json!({}));
    assert!(s.validate_patch("Entry", &json!({"text":null})).is_err());
    assert!(s.validate_patch("Entry", &json!({"id":ID})).is_err());
    assert!(
        s.validate_patch("Entry", &json!({"count":9007199254740992u64}))
            .is_err()
    );
}

#[test]
fn independent_schemas_load_without_business_rust_types() {
    let second=Schema::from_value(json!({"enums":[],"models":[{"name":"Book","identity":["slug","edition"],"fields":[{"name":"slug","type":{"kind":"scalar","name":"string"},"nullable":false},{"name":"edition","type":{"kind":"scalar","name":"int"},"nullable":false}]}]})).unwrap();
    assert!(
        second
            .record_key("Book", &json!({"slug":"x","edition":1}))
            .is_ok()
    );
    assert!(
        schema()
            .record_key("Book", &json!({"slug":"x","edition":1}))
            .is_err()
    );
}

#[test]
fn wire_names_remain_legacy_and_counters_are_safe() {
    let page=PullPage::decode(br#"{"scope":"book:1","fromCursor":0,"toCursor":2,"changes":[{"syncId":2,"model":"Entry","identity":{"id":"x"},"stamp":2,"state":null}],"future":true}"#).unwrap();
    assert_eq!(page.channel, "book:1");
    assert_eq!(page.to_cursor, 2);
    let wire: Value = serde_json::from_slice(&page.encode().unwrap()).unwrap();
    assert_eq!(wire["scope"], "book:1");
    assert!(wire.get("channel").is_none());
    assert!(
        PullPage::decode(
            br#"{"scope":"a","fromCursor":0,"toCursor":9007199254740992,"changes":[]}"#
        )
        .is_err()
    );
    assert!(
        PullPage::decode(br#"{"scope":"a","fromCursor":2,"toCursor":1,"changes":[]}"#).is_err()
    );
}

#[test]
fn batch_envelope_keeps_unknown_data_in_receipt_hash() {
    let a=PushRequest::decode(br#"{"clientId":"c","batchSequence":1,"mutations":[{"ordinal":4,"name":"Edit","args":{}}],"future":1}"#).unwrap();
    let b=PushRequest::decode(br#"{"future":1,"mutations":[{"args":{},"name":"Edit","ordinal":4}],"batchSequence":1,"clientId":"c"}"#).unwrap();
    assert_eq!(a.semantic_hash().unwrap(), b.semantic_hash().unwrap());
    let c=PushRequest::decode(br#"{"clientId":"c","batchSequence":1,"mutations":[{"ordinal":4,"name":"Edit","args":{}}]}"#).unwrap();
    assert_ne!(a.semantic_hash().unwrap(), c.semantic_hash().unwrap());
    assert!(
        PushRequest::decode(
            br#"{"clientId":"c","batchSequence":1,"mutations":[{"ordinal":1},{"ordinal":1}]}"#
        )
        .is_err()
    );
}

#[test]
fn canonical_numbers_match_javascript_and_utf16_key_order() {
    assert_eq!(
        canonical_json(&json!({"z":1.0,"a":-0.0})).unwrap(),
        "{\"a\":0,\"z\":1}"
    );
    assert_eq!(
        canonical_json(&json!({"\u{e000}":1,"\u{1f600}":2})).unwrap(),
        "{\"😀\":2,\"\":1}"
    );
}

#[test]
fn checkpoint_wire_roundtrip_retains_legacy_fallback() {
    let receipt = PushReceipt {
        required_checkpoints: vec![ChannelCheckpoint {
            channel: "b".into(),
            cursor: 3,
        }],
        required_channel: "b".into(),
        required_cursor: 3,
        rejections: vec![Rejection {
            ordinal: 2,
            code: "denied".into(),
        }],
    };
    let value: Value = serde_json::from_slice(&receipt.encode().unwrap()).unwrap();
    assert_eq!(
        value["requiredCheckpoints"][0],
        json!({"scope":"b","syncId":3})
    );
    assert_eq!(value["requiredScope"], "b");
    assert_eq!(
        PushReceipt::decode(&receipt.encode().unwrap()).unwrap(),
        receipt
    );
}

#[test]
fn received_state_supports_additive_schema_evolution() {
    let s = schema();
    assert_eq!(
        s.validate_state("Entry", &json!({"text":"a","count":0,"newField":42}))
            .unwrap(),
        json!({"text":"a","count":0,"note":null})
    );
    assert!(
        s.validate_state("Entry", &json!({"id":ID,"text":"a","count":0}))
            .is_err()
    );
}
#[test]
fn server_pull_request_accepts_js_integer_number_spellings() {
    for number in ["0.0", "1e0", "-0"] {
        let wire = format!("{{\"clientId\":\"c\",\"scope\":\"s\",\"fromCursor\":{number}}}");
        assert!(PullRequest::decode(wire.as_bytes()).is_ok(), "{number}");
    }
}
#[test]
fn receipt_distinguishes_missing_checkpoints_from_explicit_empty() {
    assert!(
        PushReceipt::decode(br#"{"requiredScope":"s","requiredSyncId":0,"rejections":[]}"#).is_ok()
    );
    assert!(
        PushReceipt::decode(
            br#"{"requiredScope":"s","requiredSyncId":0,"rejections":[],"requiredCheckpoints":[]}"#
        )
        .is_err()
    );
    assert!(PushReceipt::decode(br#"{"requiredScope":"s","requiredSyncId":0,"rejections":[],"requiredCheckpoints":[{"scope":"s","syncId":0},{"scope":"s","syncId":1}]}"#).is_err());
}

#[test]
fn shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../fixtures/protocol/counter-and-checkpoint.json"
    ))
    .unwrap();
    for kind in ["pull", "receipt"] {
        for case in fixture[kind].as_array().unwrap() {
            let wire = case["wire"].as_str().unwrap().as_bytes();
            let valid = if kind == "pull" {
                PullPage::decode(wire).is_ok()
            } else {
                PushReceipt::decode(wire).is_ok()
            };
            assert_eq!(valid, case["valid"].as_bool().unwrap(), "{}", case["name"]);
        }
    }
}

#[test]
fn field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected() {
    let field: FieldDescriptor = serde_json::from_value(
        json!({"name":"rank","nullable":false,"type":{"kind":"scalar","name":"int"},"default":0}),
    )
    .unwrap();
    assert_eq!(field.default, Some(json!(0)));
    let plain: FieldDescriptor = serde_json::from_value(
        json!({"name":"t","nullable":true,"type":{"kind":"scalar","name":"string"}}),
    )
    .unwrap();
    assert_eq!(plain.default, None);
    assert!(!serde_json::to_string(&plain).unwrap().contains("default"));
    let page = PullPage::decode(
        br#"{"scope":"c","fromCursor":0,"toCursor":1,"changes":[{"syncId":1,"model":"E","identity":{"id":"e"},"stamp":7,"state":null}]}"#,
    )
    .unwrap();
    assert_eq!(page.changes[0].stamp, 7);
    assert!(
        String::from_utf8(page.encode().unwrap())
            .unwrap()
            .contains(r#""stamp":7"#)
    );
    let unstamped = PullPage::decode(
        br#"{"scope":"c","fromCursor":0,"toCursor":1,"changes":[{"syncId":1,"model":"E","identity":{"id":"e"},"state":null}]}"#,
    );
    assert!(unstamped.unwrap_err().to_string().contains("stamp"));
    let bad = Schema::from_value(
        json!({"enums":[],"models":[{"name":"ahead_x","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}}]}]}),
    );
    assert!(bad.is_err());
    for name in ["sqlite_x", "SQLITE_x", "Ahead_x"] {
        let reserved = Schema::from_value(
            json!({"enums":[],"models":[{"name":name,"identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}}]}]}),
        );
        assert!(
            reserved.unwrap_err().to_string().contains("reserved"),
            "{name} must be refused as reserved"
        );
    }
    for name in ["sqlitex", "Sqlite", "aheadx"] {
        assert!(
            Schema::from_value(
                json!({"enums":[],"models":[{"name":name,"identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}}]}]}),
            )
            .is_ok(),
            "{name} must stay valid"
        );
    }
}

#[test]
fn scalar_and_enum_values_normalize_or_are_refused() {
    let s = Schema::from_value(json!({"enums":[{"name":"Mood","values":["calm","busy"]}],"models":[{
        "name":"E","identity":["id"],"fields":[
            {"name":"id","type":{"kind":"scalar","name":"string"},"nullable":false},
            {"name":"at","type":{"kind":"scalar","name":"dateTime"},"nullable":false},
            {"name":"ratio","type":{"kind":"scalar","name":"float"},"nullable":true},
            {"name":"mood","type":{"kind":"enum","name":"Mood"},"nullable":false},
            {"name":"tags","type":{"kind":"list","element":{"kind":"scalar","name":"string"}},"nullable":false}
        ]}]}))
    .unwrap();
    let patch = |v: Value| s.validate_patch("E", &v);
    // dateTime re-encodes to UTC milliseconds; a date, a space separator or a number is refused.
    assert_eq!(
        patch(json!({"at":"2024-01-02T03:04:05+01:00"})).unwrap(),
        json!({"at":"2024-01-02T02:04:05.000Z"})
    );
    assert_eq!(
        patch(json!({"at":"2024-01-02T03:04:05.25Z"})).unwrap()["at"],
        "2024-01-02T03:04:05.250Z"
    );
    for bad in [
        json!("2024-01-02"),
        json!("2024-01-02 03:04:05Z"),
        json!(1704164645),
    ] {
        assert!(patch(json!({"at":bad})).is_err(), "{bad} must be refused");
    }
    // float must be finite; -0 becomes 0; null is allowed only because ratio is nullable.
    assert_eq!(patch(json!({"ratio":-0.0})).unwrap()["ratio"], json!(0.0));
    assert_eq!(patch(json!({"ratio":1.5})).unwrap()["ratio"], json!(1.5));
    assert_eq!(patch(json!({"ratio":null})).unwrap()["ratio"], Value::Null);
    assert!(patch(json!({"ratio":"1.5"})).is_err());
    // JSON cannot carry NaN or infinity: `Value::from(f64::NAN)` is already null,
    // so the only non-finite inputs a wire can produce are refused as non-numbers.
    assert!(patch(json!({"ratio":"NaN"})).is_err());
    assert!(patch(json!({"ratio":"Infinity"})).is_err());
    // enum values must be declared and be strings.
    assert_eq!(patch(json!({"mood":"busy"})).unwrap()["mood"], "busy");
    assert!(patch(json!({"mood":"angry"})).is_err());
    assert!(patch(json!({"mood":1})).is_err());
    assert!(patch(json!({"mood":null})).is_err(), "mood is not nullable");
    // lists normalize each element and refuse non-lists and bad elements.
    assert_eq!(
        patch(json!({"tags":["a","b"]})).unwrap()["tags"],
        json!(["a", "b"])
    );
    assert!(patch(json!({"tags":"a"})).is_err());
    assert!(patch(json!({"tags":["a",1]})).is_err());
    assert!(patch(json!({"tags":null})).is_err(), "lists cannot be null");
}

#[test]
fn list_descriptors_must_hold_scalars_and_cannot_be_nullable() {
    let model = |field: Value| {
        Schema::from_value(
            json!({"enums":[{"name":"Mood","values":["calm"]}],"models":[{
            "name":"E","identity":["id"],"fields":[
                {"name":"id","type":{"kind":"scalar","name":"string"},"nullable":false},
                field
            ]}]}),
        )
    };
    assert!(model(json!({"name":"tags","type":{"kind":"list","element":{"kind":"scalar","name":"string"}},"nullable":false})).is_ok());
    let nullable_list = model(
        json!({"name":"tags","type":{"kind":"list","element":{"kind":"scalar","name":"string"}},"nullable":true}),
    );
    assert!(
        nullable_list
            .unwrap_err()
            .to_string()
            .contains("lists cannot be nullable")
    );
    let enum_list = model(
        json!({"name":"moods","type":{"kind":"list","element":{"kind":"enum","name":"Mood"}},"nullable":false}),
    );
    assert!(
        enum_list
            .unwrap_err()
            .to_string()
            .contains("list elements must be scalar")
    );
    let nested = model(
        json!({"name":"grid","type":{"kind":"list","element":{"kind":"list","element":{"kind":"scalar","name":"int"}}},"nullable":false}),
    );
    assert!(nested.is_err());
    assert!(
        model(json!({"name":"mood","type":{"kind":"enum","name":"Unknown"},"nullable":false}))
            .is_err()
    );
}

#[test]
fn push_batches_hold_one_to_twenty_mutations_with_distinct_ordinals() {
    let batch = |count: usize| {
        let mutations: Vec<Value> = (1..=count)
            .map(|i| json!({"ordinal":i,"name":"edit","operations":[]}))
            .collect();
        json!({"clientId":"c","batchSequence":1,"mutations":mutations}).to_string()
    };
    assert!(PushRequest::decode(batch(0).as_bytes()).is_err());
    assert_eq!(
        PushRequest::decode(batch(1).as_bytes())
            .unwrap()
            .mutations
            .len(),
        1
    );
    assert_eq!(
        PushRequest::decode(batch(20).as_bytes())
            .unwrap()
            .mutations
            .len(),
        20
    );
    let err = PushRequest::decode(batch(21).as_bytes()).unwrap_err();
    assert!(err.to_string().contains("1..20"), "{err}");
    let duplicate = json!({"clientId":"c","batchSequence":1,"mutations":[
        {"ordinal":1,"name":"edit","operations":[]},{"ordinal":1,"name":"edit","operations":[]}
    ]})
    .to_string();
    assert!(PushRequest::decode(duplicate.as_bytes()).is_err());
    let zero = json!({"clientId":"c","batchSequence":1,"mutations":[{"ordinal":0,"name":"edit","operations":[]}]}).to_string();
    assert!(PushRequest::decode(zero.as_bytes()).is_err());
}

#[test]
fn push_and_pull_requests_refuse_a_blank_client_id() {
    let mutations = json!([{"ordinal":1,"name":"edit","operations":[]}]);
    for blank in ["", "   "] {
        let push = json!({"clientId":blank,"batchSequence":1,"mutations":mutations}).to_string();
        assert!(
            PushRequest::decode(push.as_bytes()).is_err(),
            "push {blank:?}"
        );
        let pull = json!({"clientId":blank,"scope":"a","fromCursor":0}).to_string();
        assert!(
            PullRequest::decode(pull.as_bytes()).is_err(),
            "pull {blank:?}"
        );
    }
    let push = json!({"clientId":"c","batchSequence":1,"mutations":mutations}).to_string();
    assert_eq!(PushRequest::decode(push.as_bytes()).unwrap().client_id, "c");
    let missing = json!({"batchSequence":1,"mutations":mutations}).to_string();
    assert!(
        PushRequest::decode(missing.as_bytes()).is_err(),
        "missing clientId"
    );
}

#[test]
fn shared_limits_are_defined_once_and_a_page_continues_only_when_full() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../fixtures/protocol/live-messages.json"
    ))
    .unwrap();
    assert_eq!(fixture["limits"]["pushMutations"], limits::PUSH_MUTATIONS);
    assert_eq!(fixture["limits"]["pushBytes"], limits::PUSH_BYTES);
    assert_eq!(fixture["limits"]["pullChanges"], limits::PULL_CHANGES);
    let page = |count: usize| {
        let changes: Vec<Value> = (1..=count)
            .map(|i| json!({"syncId":i,"model":"Entry","identity":{"id":i.to_string()},"stamp":i,"state":null}))
            .collect();
        json!({"scope":"book","fromCursor":0,"toCursor":count.max(1),"changes":changes}).to_string()
    };
    let below = PullPage::decode(page(limits::PULL_CHANGES - 1).as_bytes()).unwrap();
    assert!(!below.continues(), "a short page reaches the head");
    let full = PullPage::decode(page(limits::PULL_CHANGES).as_bytes()).unwrap();
    assert!(full.continues(), "a full page may leave changes behind");
    let err = PullPage::decode(page(limits::PULL_CHANGES + 1).as_bytes()).unwrap_err();
    assert!(err.to_string().contains("exceeds 50"), "{err}");
    assert!(!PullPage::decode(page(0).as_bytes()).unwrap().continues());
}

#[test]
fn live_frames_decode_as_acknowledgement_or_page_and_scopes_normalize() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../fixtures/protocol/live-messages.json"
    ))
    .unwrap();
    for case in fixture["subscribe"].as_array().unwrap() {
        let wire = case["wire"].as_str().unwrap().as_bytes();
        match SubscribeRequest::decode(wire) {
            Ok(request) => {
                assert_eq!(case["valid"], true, "{}", case["name"]);
                assert_eq!(json!(request.scopes), case["scopes"], "{}", case["name"]);
                let again = SubscribeRequest::decode(&request.encode().unwrap()).unwrap();
                assert_eq!(again, request, "encoding is canonical: {}", case["name"]);
            }
            Err(_) => assert_eq!(case["valid"], false, "{}", case["name"]),
        }
    }
    for case in fixture["acknowledgement"].as_array().unwrap() {
        let wire = case["wire"].as_str().unwrap().as_bytes();
        match SubscriptionAck::decode(wire) {
            Ok(ack) => {
                assert_eq!(case["valid"], true, "{}", case["name"]);
                assert_eq!(json!(ack.scopes), case["scopes"], "{}", case["name"]);
                assert_eq!(
                    SubscriptionAck::decode(&ack.encode().unwrap()).unwrap(),
                    ack
                );
            }
            Err(_) => assert_eq!(case["valid"], false, "{}", case["name"]),
        }
    }
    for case in fixture["frame"].as_array().unwrap() {
        let wire = case["wire"].as_str().unwrap().as_bytes();
        let kind = match LiveMessage::decode(wire) {
            Ok(LiveMessage::Acknowledged(_)) => "acknowledged",
            Ok(LiveMessage::Page(_)) => "page",
            Err(_) => "invalid",
        };
        assert_eq!(kind, case["kind"], "{}", case["name"]);
    }
    let request = SubscribeRequest::new(vec!["b".into(), "a".into()]).unwrap();
    assert!(
        SubscriptionAck::new(vec!["a".into(), "b".into()])
            .unwrap()
            .confirms(&request)
    );
    assert!(
        !SubscriptionAck::new(vec!["a".into()])
            .unwrap()
            .confirms(&request)
    );
    assert!(
        !SubscriptionAck::new(vec!["a".into(), "b".into(), "c".into()])
            .unwrap()
            .confirms(&request)
    );
    // The server's frame is the acknowledgement the client decodes, byte for byte.
    assert_eq!(
        String::from_utf8(
            SubscriptionAck::new(vec!["b".into(), "a".into()])
                .unwrap()
                .encode()
                .unwrap()
        )
        .unwrap(),
        r#"{"rejections":[],"scopes":["a","b"],"type":"subscribed"}"#
    );
}
