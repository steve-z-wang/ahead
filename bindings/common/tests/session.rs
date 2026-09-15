use ahead_binding::RuntimeHost;
use serde_json::{Value, json};
#[test]
fn language_commands_preserve_transaction_isolation_and_closed_handles() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    let opened = host
        .call(json!({"op":"open","path":dir.path().join("db"),"schema":schema,"owner":"u"}))
        .unwrap();
    let id = opened["value"]["handle"].clone();
    host.call(json!({"op":"begin","handle":id})).unwrap();
    host.call(json!({"op":"direct","handle":id,"operation":{"model":"Entry","op":"create","identity":{"id":"e"},"values":{"text":"hi"}}})).unwrap();
    let row = host
        .call(json!({"op":"read","handle":id,"key":{"model":"Entry","identity":{"id":"e"}}}))
        .unwrap();
    assert_eq!(row["value"]["text"], "hi");
    assert_eq!(row["changed"], false);
    host.call(json!({"op":"rollback","handle":id})).unwrap();
    let row = host
        .call(json!({"op":"read","handle":id,"key":{"model":"Entry","identity":{"id":"e"}}}))
        .unwrap();
    assert!(row["value"].is_null());
    host.call(json!({"op":"close","handle":id})).unwrap();
    assert!(host.call(json!({"op":"status","handle":id})).is_err());
}
#[test]
fn rust_selects_transport_actions_and_reuses_frozen_request_on_retry() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    let id = host
        .call(json!({"op":"open","path":dir.path().join("db"),"schema":schema,"owner":"u"}))
        .unwrap()["value"]["handle"]
        .clone();
    host.call(json!({"op":"channel","handle":id,"channel":"book","subscribed":true}))
        .unwrap();
    host.call(json!({"op":"startSync","handle":id})).unwrap();
    let action = host.call(json!({"op":"next","handle":id})).unwrap()["value"].clone();
    assert_eq!(action["kind"], "pull");
    host.call(json!({"op":"complete","handle":id,"response":{"scope":"book","fromCursor":0,"toCursor":1,"changes":[{"syncId":1,"model":"Entry","identity":{"id":"e"},"stamp":1,"state":{"text":"A","note":null}}]}})).unwrap();
    assert!(host.call(json!({"op":"next","handle":id})).unwrap()["value"].is_null());
    host.call(json!({"op":"enqueue","handle":id,"mutation":{"name":"Edit","operations":[{"model":"Entry","op":"update","identity":{"id":"e"},"values":{"text":"B"}}]}})).unwrap();
    host.call(json!({"op":"startSync","handle":id})).unwrap();
    let action = host.call(json!({"op":"next","handle":id})).unwrap()["value"].clone();
    assert_eq!(action["kind"], "push");
    assert_eq!(
        host.call(json!({"op":"next","handle":id})).unwrap()["value"],
        action
    );
    host.call(json!({"op":"complete","handle":id,"response":{"requiredScope":"book","requiredSyncId":2,"requiredCheckpoints":[{"scope":"book","syncId":2}],"rejections":[]}})).unwrap();
    assert_eq!(
        host.call(json!({"op":"next","handle":id})).unwrap()["value"]["kind"],
        "pull"
    );
}

#[test]
fn live_push_cycle_keeps_receipts_but_leaves_reads_to_the_stream() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    let id = host
        .call(json!({"op":"open","path":dir.path().join("db"),"schema":schema}))
        .unwrap()["value"]["handle"]
        .clone();
    host.call(json!({"op":"channel","handle":id,"channel":"book","subscribed":true}))
        .unwrap();
    host.call(json!({"op":"startSync","handle":id,"pushOnly":true}))
        .unwrap();
    assert!(host.call(json!({"op":"next","handle":id})).unwrap()["value"].is_null());
    host.call(json!({"op":"enqueue","handle":id,"mutation":{"name":"Create","operations":[{"model":"Entry","op":"create","identity":{"id":"e"},"values":{"text":"B","note":null}}]}})).unwrap();
    host.call(json!({"op":"startSync","handle":id,"pushOnly":true}))
        .unwrap();
    let action = host.call(json!({"op":"next","handle":id})).unwrap()["value"].clone();
    assert_eq!(action["kind"], "push");
    host.call(json!({"op":"startSync","handle":id,"pushOnly":true}))
        .unwrap();
    assert_eq!(
        host.call(json!({"op":"next","handle":id})).unwrap()["value"],
        action
    );
    host.call(json!({"op":"complete","handle":id,"response":{"requiredScope":"book","requiredSyncId":1,"rejections":[]}})).unwrap();
    assert!(host.call(json!({"op":"next","handle":id})).unwrap()["value"].is_null());
    assert_eq!(
        host.call(json!({"op":"status","handle":id})).unwrap()["value"]["pending"],
        1
    );
    host.call(json!({"op":"pull","handle":id,"page":{"scope":"book","fromCursor":0,"toCursor":1,"changes":[{"syncId":1,"model":"Entry","identity":{"id":"e"},"stamp":1,"state":{"text":"normalized","note":null}}]}})).unwrap();
    assert_eq!(
        host.call(json!({"op":"status","handle":id})).unwrap()["value"]["pending"],
        0
    );
    host.call(json!({"op":"startSync","handle":id})).unwrap();
    assert_eq!(
        host.call(json!({"op":"next","handle":id})).unwrap()["value"]["kind"],
        "pull"
    );
}

#[test]
fn live_and_push_drivers_have_independent_lifecycle_and_retry_state() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    let id = host
        .call(json!({"op":"open","path":dir.path().join("db"),"schema":schema}))
        .unwrap()["value"]["handle"]
        .clone();
    for lane in [json!(null), json!(false), json!(123), json!("unknown")] {
        assert!(
            host.call(json!({"op":"connection","handle":id,"lane":lane,"event":"start","now":0}))
                .is_err()
        );
    }
    for lane in ["push", "live"] {
        host.call(json!({"op":"connection","handle":id,"lane":lane,"event":"start","now":0}))
            .unwrap();
        assert_eq!(
            host.call(json!({"op":"connection","handle":id,"lane":lane,"event":"next","now":0}))
                .unwrap()["value"]["type"],
            "sync"
        );
    }
    host.call(json!({"op":"connection","handle":id,"lane":"live","event":"failure","now":0}))
        .unwrap();
    host.call(json!({"op":"connection","handle":id,"event":"success","now":0}))
        .unwrap();
    assert_eq!(
        host.call(json!({"op":"connection","handle":id,"lane":"live","event":"next","now":0}))
            .unwrap()["value"]["type"],
        "wait"
    );
    assert_eq!(
        host.call(json!({"op":"connection","handle":id,"event":"next","now":0}))
            .unwrap()["value"]["type"],
        "idle"
    );
}

#[test]
fn incoming_pages_share_cursor_policy_and_do_not_overwrite_push_cycle() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    let id = host
        .call(json!({"op":"open","path":dir.path().join("db"),"schema":schema}))
        .unwrap()["value"]["handle"]
        .clone();
    host.call(json!({"op":"channel","handle":id,"channel":"book","subscribed":true}))
        .unwrap();
    let request = host
        .call(json!({"op":"downlinkRequest","handle":id,"scope":"book"}))
        .unwrap()["value"]
        .clone();
    assert_eq!(
        serde_json::from_str::<Value>(request.as_str().unwrap()).unwrap()["fromCursor"],
        0
    );
    let page = json!({"scope":"book","fromCursor":0,"toCursor":1,"changes":[{"syncId":1,"model":"Entry","identity":{"id":"e"},"stamp":1,"state":{"text":"A","note":null}}]});
    assert_eq!(
        host.call(json!({"op":"downlinkPage","handle":id,"request":request,"page":page}))
            .unwrap()["value"]["continues"],
        false
    );
    assert_eq!(
        host.call(json!({"op":"downlinkPage","handle":id,"page":page}))
            .unwrap()["value"]["disposition"],
        "covered"
    );
    let gap = json!({"scope":"book","fromCursor":2,"toCursor":3,"changes":[]});
    assert_eq!(
        host.call(json!({"op":"downlinkPage","handle":id,"page":gap}))
            .unwrap()["value"]["disposition"],
        "recover"
    );
    host.call(json!({"op":"enqueue","handle":id,"mutation":{"name":"Edit","operations":[{"model":"Entry","op":"update","identity":{"id":"e"},"values":{"text":"B"}}]}})).unwrap();
    host.call(json!({"op":"startSync","handle":id,"pushOnly":true}))
        .unwrap();
    let push = host.call(json!({"op":"next","handle":id})).unwrap()["value"].clone();
    let request = host
        .call(json!({"op":"downlinkRequest","handle":id,"scope":"book"}))
        .unwrap()["value"]
        .clone();
    let page = json!({"scope":"book","fromCursor":1,"toCursor":1,"changes":[]});
    host.call(json!({"op":"downlinkPage","handle":id,"request":request,"page":page}))
        .unwrap();
    assert_eq!(
        host.call(json!({"op":"next","handle":id})).unwrap()["value"],
        push
    );
    assert_eq!(push["kind"], "push");
}

#[test]
fn incoming_overlap_is_identical_with_or_without_http_request_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    for with_request in [false, true] {
        let id=host.call(json!({"op":"open","path":dir.path().join(if with_request {"http"} else {"ws"}),"schema":schema})).unwrap()["value"]["handle"].clone();
        host.call(json!({"op":"channel","handle":id,"channel":"book","subscribed":true}))
            .unwrap();
        let request = host
            .call(json!({"op":"downlinkRequest","handle":id,"scope":"book"}))
            .unwrap()["value"]
            .clone();
        let first = json!({"scope":"book","fromCursor":0,"toCursor":1,"changes":[{"syncId":1,"model":"Entry","identity":{"id":"e"},"stamp":1,"state":{"text":"first","note":null}}]});
        host.call(json!({"op":"downlinkPage","handle":id,"page":first}))
            .unwrap();
        let overlap = json!({"scope":"book","fromCursor":0,"toCursor":2,"changes":[{"syncId":1,"model":"Entry","identity":{"id":"e"},"stamp":1,"state":{"text":"covered conflicting content","note":null}},{"syncId":2,"model":"Entry","identity":{"id":"e"},"stamp":2,"state":{"text":"incoming overlap","note":null}}]});
        let mut incoming = json!({"op":"downlinkPage","handle":id,"page":overlap});
        if with_request {
            incoming["request"] = request.clone();
        }
        assert_eq!(
            host.call(incoming.clone()).unwrap()["value"],
            json!({"disposition":"applied","continues":false})
        );
        assert_eq!(
            host.call(incoming.clone()).unwrap()["value"]["disposition"],
            "covered"
        );
        assert_eq!(
            host.call(json!({"op":"status","handle":id})).unwrap()["value"]["cursors"]["book"],
            2
        );
        assert_eq!(
            host.call(
                json!({"op":"read","handle":id,"key":{"model":"Entry","identity":{"id":"e"}}})
            )
            .unwrap()["value"]["text"],
            "incoming overlap"
        );
        for invalid in [
            json!({"scope":"other","fromCursor":0,"toCursor":2,"changes":[]}),
            json!({"scope":"book","fromCursor":1,"toCursor":2,"changes":[]}),
        ] {
            assert!(
                host.call(
                    json!({"op":"downlinkPage","handle":id,"request":request,"page":invalid})
                )
                .is_err()
            );
        }
        for old in ["downlinkComplete", "downlinkLive"] {
            assert!(
                host.call(json!({"op":old,"handle":id,"request":request,"page":overlap}))
                    .is_err()
            );
        }
    }
}

/// The two refusals every language binding relies on to keep its transaction
/// object honest: a transaction-scoped command after the session ended is
/// `transaction_closed`, and a sync command while a session is open is refused
/// as `client transaction active`. Both are asserted directly here; the JS and
/// Dart suites see them only as thrown errors.
#[test]
fn transaction_scoped_commands_and_sync_commands_are_refused_by_code() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = RuntimeHost::default();
    let schema: Value =
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap();
    let opened = host
        .call(json!({"op":"open","path":dir.path().join("db"),"schema":schema,"owner":"u"}))
        .unwrap();
    let id = opened["value"]["handle"].clone();
    let key = json!({"model":"Entry","identity":{"id":"e"}});
    // No session yet: a transaction-scoped read is refused, a plain one is served.
    let refused = host
        .call(json!({"op":"read","handle":id,"key":key,"transaction":true}))
        .unwrap_err();
    assert_eq!(refused.to_string(), "transaction_closed");
    assert!(
        host.call(json!({"op":"read","handle":id,"key":key}))
            .unwrap()["value"]
            .is_null()
    );
    host.call(json!({"op":"begin","handle":id})).unwrap();
    host.call(json!({"op":"direct","handle":id,"transaction":true,"operation":{"model":"Entry","op":"create","identity":{"id":"e"},"values":{"text":"hi"}}})).unwrap();
    // While the session is open, sync commands are refused and change nothing.
    for op in ["freeze", "status", "tasks"] {
        let e = host.call(json!({"op":op,"handle":id})).unwrap_err();
        assert_eq!(e.to_string(), "client transaction active", "{op}");
    }
    host.call(json!({"op":"commit","handle":id})).unwrap();
    // After the commit the same transaction-scoped read is closed again, the
    // committed row is visible to a plain read, and sync commands work.
    let refused = host
        .call(json!({"op":"read","handle":id,"key":key,"transaction":true}))
        .unwrap_err();
    assert_eq!(refused.to_string(), "transaction_closed");
    assert_eq!(
        host.call(json!({"op":"read","handle":id,"key":key}))
            .unwrap()["value"]["text"],
        "hi"
    );
    assert_eq!(
        host.call(json!({"op":"status","handle":id})).unwrap()["value"]["pending"],
        0
    );
    host.call(json!({"op":"close","handle":id})).unwrap();
    assert_eq!(
        host.call(json!({"op":"status","handle":id}))
            .unwrap_err()
            .to_string(),
        "client_closed"
    );
}
