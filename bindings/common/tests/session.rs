use savoia_binding::RuntimeHost;
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
