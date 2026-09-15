use serde_json::{Value, json};
fn config() -> Value {
    json!({"schema":{"enums":[],"models":[{"name":"Task","identity":["id"],"fields":[{"name":"id","type":{"kind":"scalar","name":"string"},"nullable":false},{"name":"title","type":{"kind":"scalar","name":"string"},"nullable":false},{"name":"note","type":{"kind":"scalar","name":"string"},"nullable":true}]}]},"loaders":["Task"],"mutations":[{"name":"edit","version":1,"slots":[{"name":"task","model":"Task","operation":"update","cardinality":"single","allowedPatchFields":["title"]}]}]})
}
#[test]
fn ordered_slot_decodes_known_fields_and_ignores_new_fields() {
    let args=ahead_server::decode_arguments(&config(),&json!({"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a","future":1},"values":{"title":"hi","future":true}}]})).unwrap();
    assert_eq!(
        args,
        json!({"task":{"identity":{"id":"a"},"patch":{"title":"hi"}}})
    );
}
#[test]
fn known_disallowed_patch_is_explicit_refusal() {
    let err=ahead_server::decode_arguments(&config(),&json!({"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a"},"values":{"note":"x"}}]})).unwrap_err();
    assert_eq!(err.code, "edit.not_allowed");
}
#[test]
fn undeclared_operation_is_invalid() {
    assert_eq!(ahead_server::decode_arguments(&config(),&json!({"name":"edit","operations":[{"model":"Task","op":"delete","identity":{"id":"a"}}]})).unwrap_err().code,"mutation.invalid");
}
#[test]
fn create_binding_mismatch_refuses_the_whole_act() {
    let mut c = config();
    c["mutations"] = json!([{"name":"createPair","version":1,"slots":[{"name":"parent","model":"Task","operation":"delete","cardinality":"single"},{"name":"child","model":"Task","operation":"create","cardinality":"single","bindings":[{"relation":"parent","fields":["note"],"slot":"parent"}]}]}]);
    let body = json!({"name":"createPair","operations":[{"model":"Task","op":"delete","identity":{"id":"a"}},{"model":"Task","op":"create","identity":{"id":"b"},"values":{"title":"child","note":"other"}}]});
    assert_eq!(
        ahead_server::decode_arguments(&c, &body).unwrap_err().code,
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
    let result = ahead_server::decode_arguments(
        &c,
        &json!({"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a"},"values":{"title":"valid","note":"disallowed"}}]}),
    );
    assert_eq!(result.unwrap_err().code, "edit.not_allowed");
}

#[test]
fn live_subscribe_requires_one_subscribe_frame_and_normalizes_scopes() {
    let decoded = ahead_server::live::decode_subscribe(
        br#"{"type":"subscribe","scopes":["shared","alice","shared"]}"#,
    )
    .unwrap();
    assert_eq!(decoded, vec!["alice", "shared"]);
    assert!(ahead_server::live::decode_subscribe(br#"{"type":"other","scopes":["a"]}"#).is_err());
    assert!(ahead_server::live::decode_subscribe(br#"{"type":"subscribe","scopes":[]}"#).is_err());
}

#[test]
fn live_page_progression_uses_wire_cursor_and_fifty_row_boundary() {
    let full = json!({
        "scope":"shared", "fromCursor":7, "toCursor":57,
        "changes": (8..=57).map(|sync_id| json!({
            "syncId":sync_id,"model":"Task","identity":{"id":sync_id},"stamp":sync_id,"state":null
        })).collect::<Vec<_>>()
    });
    let progress = ahead_server::live::page_progress(&full.to_string(), "shared", 7).unwrap();
    assert_eq!(progress.to_cursor, 57);
    assert!(progress.continues);

    let tail = json!({"scope":"shared","fromCursor":57,"toCursor":60,"changes":[]});
    let progress = ahead_server::live::page_progress(&tail.to_string(), "shared", 57).unwrap();
    assert_eq!(progress.to_cursor, 60);
    assert!(!progress.continues);
}
#[test]
fn startup_rejects_invalid_patch_capabilities() {
    for fields in [json!(["id"]), json!(["missing"]), json!(["title", "title"])] {
        let mut c = config();
        c["mutations"][0]["slots"][0]["allowedPatchFields"] = fields;
        assert!(ahead_server::Config::decode(c).is_err());
    }
    let mut c = config();
    c["mutations"][0]["slots"][0]["operation"] = json!("delete");
    assert!(ahead_server::Config::decode(c).is_err());
}

/// A host whose `claim` answers with the given owner and last sequence and
/// which records every `handle` call, for asserting protocol refusals in
/// process without a database.
mod refusals {
    use ahead_server::{Host, HostResult, code};
    use serde_json::{Value, json};
    use std::{
        future::Future,
        pin::Pin,
        sync::Mutex,
        task::{Context, Poll, Waker},
    };

    fn run<T>(future: impl Future<Output = T>) -> T {
        let mut f = std::pin::pin!(future);
        let mut cx = Context::from_waker(Waker::noop());
        loop {
            if let Poll::Ready(result) = f.as_mut().poll(&mut cx) {
                return result;
            }
        }
    }
    struct Claimed {
        owner: &'static str,
        sequence: u64,
        handled: Mutex<Vec<Value>>,
    }
    impl Host for Claimed {
        fn call(&self, r: Value) -> Pin<Box<dyn Future<Output = HostResult<Value>> + Send + '_>> {
            Box::pin(async move {
                Ok(match r["op"].as_str().unwrap() {
                    "claim" => json!({
                        "clientId": r["clientId"], "owner": self.owner,
                        "sequence": self.sequence, "receipt": "{}"
                    }),
                    "handle" => {
                        self.handled.lock().unwrap().push(r.clone());
                        json!({"channel":"a"})
                    }
                    "head" => json!(0),
                    "savepoint" | "rollback" | "release" | "saveReceipt" => Value::Null,
                    other => return Err(format!("unsupported {other}")),
                })
            })
        }
    }
    fn claimed(owner: &'static str, sequence: u64) -> Claimed {
        Claimed {
            owner,
            sequence,
            handled: Mutex::new(vec![]),
        }
    }
    fn push(sequence: u64, version: Option<u64>) -> Vec<u8> {
        let mut mutation = json!({"ordinal":1,"name":"edit","operations":[{"model":"Task","op":"update","identity":{"id":"a"},"values":{"title":"t"}}]});
        if let Some(v) = version {
            mutation["version"] = json!(v);
        }
        json!({"clientId":"c","batchSequence":sequence,"mutations":[mutation]})
            .to_string()
            .into_bytes()
    }
    fn config() -> ahead_server::Config {
        ahead_server::Config::decode(super::config()).unwrap()
    }

    #[test]
    fn push_refusals_carry_stable_codes_and_run_no_handler() {
        // (claimed owner, last accepted sequence, batch sequence, version, expected code)
        let cases: [(&str, u64, u64, Option<u64>, &str); 4] = [
            ("alice", 1, 3, None, code::GAP),
            ("alice", 2, 1, None, code::OVERLAP),
            ("bob", 0, 1, None, code::OWNER_MISMATCH),
            ("alice", 0, 1, Some(2), code::MUTATION_VERSION_UNSUPPORTED),
        ];
        for (owner, last, batch, version, expected) in cases {
            let host = claimed(owner, last);
            let err = run(ahead_server::process_push(
                &config(),
                "alice",
                &push(batch, version),
                &host,
            ))
            .unwrap_err();
            assert_eq!(err.code, expected, "{err}");
            assert!(
                host.handled.lock().unwrap().is_empty(),
                "{expected} ran a handler"
            );
        }
        let host = claimed("alice", 0);
        let err = run(ahead_server::process_push(
            &config(),
            "alice",
            &push(1, Some(2)),
            &host,
        ))
        .unwrap_err();
        assert_eq!(err.details, json!({"ordinal":1,"name":"edit","version":2}));
        assert_ne!(err.message, err.code, "the message explains the refusal");
        let accepted = run(ahead_server::process_push(
            &config(),
            "alice",
            &push(1, None),
            &host,
        ))
        .unwrap();
        assert!(accepted.contains("requiredCheckpoints"));
        assert_eq!(host.handled.lock().unwrap().len(), 1);
    }

    #[test]
    fn malformed_requests_and_blank_owners_are_refused_with_codes() {
        let host = claimed("alice", 0);
        let err = run(ahead_server::process_push(&config(), "alice", b"{", &host)).unwrap_err();
        assert_eq!(err.code, code::REQUEST_INVALID);
        let err = run(ahead_server::process_pull(&config(), "alice", b"[]", &host)).unwrap_err();
        assert_eq!(err.code, code::REQUEST_INVALID);
        let ahead = json!({"clientId":"c","scope":"a","fromCursor":7}).to_string();
        let err = run(ahead_server::process_pull(
            &config(),
            "alice",
            ahead.as_bytes(),
            &host,
        ))
        .unwrap_err();
        assert_eq!(err.code, code::REQUEST_INVALID);
        assert!(err.message.contains("ahead of head"));
        let err = run(ahead_server::process_push(
            &config(),
            " ",
            &push(1, None),
            &host,
        ))
        .unwrap_err();
        assert_eq!(err.code, code::PRINCIPAL_INVALID);
        let err = ahead_server::live::decode_subscribe(br#"{"type":"other","scopes":["a"]}"#)
            .unwrap_err();
        assert_eq!(err.code, code::REQUEST_INVALID);
    }

    #[test]
    fn host_failures_keep_their_message_under_the_host_code() {
        struct Failing;
        impl Host for Failing {
            fn call(
                &self,
                _: Value,
            ) -> Pin<Box<dyn Future<Output = HostResult<Value>> + Send + '_>> {
                Box::pin(async { Err("connection reset by peer".to_string()) })
            }
        }
        let err = run(ahead_server::process_push(
            &config(),
            "alice",
            &push(1, None),
            &Failing,
        ))
        .unwrap_err();
        assert_eq!(err.code, code::HOST);
        assert_eq!(err.message, "connection reset by peer");
        assert_eq!(err.to_string(), "host: connection reset by peer");
        let round_trip: ahead_server::Error =
            serde_json::from_str(&serde_json::to_string(&err).unwrap()).unwrap();
        assert_eq!(round_trip, err);
        assert!(!serde_json::to_string(&err).unwrap().contains("details"));
    }
}
