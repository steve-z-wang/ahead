//! Pull copies the invalidation row's stamp; publish accepts `{cursor, stamp}`.
use otter_server::{Config, Host};
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
fn config() -> Config {
    Config::decode(json!({
        "schema":{"enums":[],"models":[{"name":"Entry","identity":["id"],"fields":[
            {"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},
            {"name":"text","nullable":false,"type":{"kind":"scalar","name":"string"}}]}]},
        "loaders":["Entry"],
        "mutations":[]
    }))
    .unwrap()
}
/// `scan` returns the given rows; `publish` returns the given value.
struct Fixed {
    scan: Value,
    publish: Value,
    published: Mutex<Vec<Value>>,
}
impl Fixed {
    fn new(scan: Value, publish: Value) -> Self {
        Self {
            scan,
            publish,
            published: Mutex::new(vec![]),
        }
    }
}
impl Host for Fixed {
    fn call(
        &self,
        r: Value,
    ) -> Pin<Box<dyn Future<Output = otter_server::Result<Value>> + Send + '_>> {
        Box::pin(async move {
            Ok(match r["op"].as_str().unwrap() {
                "head" => json!(5),
                "scan" => self.scan.clone(),
                "load" => json!([{"id":"e","text":"t"}]),
                "publish" => {
                    self.published.lock().unwrap().push(r.clone());
                    self.publish.clone()
                }
                other => return Err(format!("unsupported {other}")),
            })
        })
    }
}
fn pull_body() -> Vec<u8> {
    otter_core::PullRequest {
        client_id: "c".into(),
        channel: "a".into(),
        from_cursor: 0,
    }
    .encode()
    .unwrap()
}
fn row(stamp: Value) -> Value {
    let mut row = json!({"channel":"a","cursor":1,"model":"Entry","identity":{"id":"e"},"identityKey":"{\"id\":\"e\"}"});
    if !stamp.is_null() {
        row["stamp"] = stamp;
    }
    json!([row])
}

#[test]
fn pull_copies_the_row_stamp_into_the_change() {
    let host = Fixed::new(row(json!(7)), Value::Null);
    let text = run(otter_server::process_pull(
        &config(),
        "u",
        &pull_body(),
        &host,
    ))
    .unwrap();
    let page = otter_core::PullPage::decode(text.as_bytes()).unwrap();
    assert_eq!(page.changes[0].stamp, 7);
}

#[test]
fn pull_rejects_rows_without_a_positive_stamp() {
    for bad in [Value::Null, json!(0), json!(-1), json!(9007199254740992u64)] {
        let host = Fixed::new(row(bad.clone()), Value::Null);
        let err = run(otter_server::process_pull(
            &config(),
            "u",
            &pull_body(),
            &host,
        ))
        .unwrap_err();
        assert!(err.contains("stamp"), "{bad}: {err}");
    }
}

#[test]
fn publish_requires_cursor_and_stamp_from_the_host() {
    let changes = json!([{"model":"Entry","identity":{"id":"e"}}]);
    let channels = json!(["a"]);
    let ok = Fixed::new(json!([]), json!({"cursor":3,"stamp":9}));
    run(otter_server::publish(&config(), &changes, &channels, &ok)).unwrap();
    assert_eq!(ok.published.lock().unwrap().len(), 1);
    for bad in [json!(3), json!({"cursor":3}), json!({"cursor":3,"stamp":0})] {
        let host = Fixed::new(json!([]), bad.clone());
        let err = run(otter_server::publish(&config(), &changes, &channels, &host)).unwrap_err();
        assert!(!err.is_empty(), "{bad} must be rejected");
    }
}
