//! Cross-runtime scenarios. Host persistence is deliberately simple; real database contracts live in integration/persistence.
use otter_client::{Client, Mutation, Operation, OperationKind};
use otter_core::{PullPage, PullRequest, PushReceipt, Schema};
use otter_server::{Config, Host};
use otter_sqlite::SqliteStore;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
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
fn schema() -> Schema {
    Schema::from_value(
        serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap(),
    )
    .unwrap()
}
fn config() -> Config {
    Config::decode(json!({"schema":schema(),"loaders":["Entry"],"mutations":[{"name":"Edit","version":1,"slots":[{"name":"entry","model":"Entry","operation":"update","cardinality":"single","allowedPatchFields":["text"]}]}]})).unwrap()
}
#[derive(Clone)]
struct Database {
    head: u64,
    text: String,
    clients: BTreeMap<String, Value>,
    calls: usize,
}
struct Backend(Mutex<Database>);
impl Backend {
    fn new() -> Self {
        Self(Mutex::new(Database {
            head: 1,
            text: "initial".into(),
            clients: BTreeMap::new(),
            calls: 0,
        }))
    }
    fn push(&self, body: &[u8]) -> String {
        let before = self.0.lock().unwrap().clone();
        match run(otter_server::process_push(&config(), "u", body, self)) {
            Ok(r) => r,
            Err(e) => {
                *self.0.lock().unwrap() = before;
                panic!("{e}")
            }
        }
    }
    fn pull(&self, client: &mut Client<SqliteStore>) -> PullPage {
        let body = PullRequest {
            channel: "book".into(),
            client_id: client.client_id().into(),
            from_cursor: client.cursor("book").unwrap(),
        }
        .encode()
        .unwrap();
        PullPage::decode(
            run(otter_server::process_pull(&config(), "u", &body, self))
                .unwrap()
                .as_bytes(),
        )
        .unwrap()
    }
}
impl Host for Backend {
    fn call(
        &self,
        r: Value,
    ) -> Pin<Box<dyn Future<Output = otter_server::Result<Value>> + Send + '_>> {
        Box::pin(async move {
            let mut db = self.0.lock().unwrap();
            Ok(match r["op"].as_str().unwrap(){
 "claim"=>db.clients.entry(r["clientId"].as_str().unwrap().into()).or_insert_with(||json!({"clientId":r["clientId"],"owner":r["owner"],"sequence":0,"receipt":null})).clone(),
 "saveReceipt"=>{db.clients.insert(r["clientId"].as_str().unwrap().into(),json!({"clientId":r["clientId"],"owner":r["owner"],"sequence":r["sequence"],"receipt":r["receipt"]}));Value::Null},
 "head"=>json!(db.head),"authorize"=>json!(true),"savepoint"|"release"|"rollback"=>Value::Null,
 "handle"=>{db.calls+=1;let text=r["arguments"]["entry"]["patch"]["text"].as_str().unwrap();if text=="reject"{json!({"rejection":"entry.denied"})}else{db.text=text.trim().into();db.head+=1;json!({"channel":"book"})}},
 "scan"=>if r["after"].as_u64().unwrap()<db.head{json!([{"channel":"book","cursor":db.head,"model":"Entry","identity":{"id":"e"},"identityKey":"{\"id\":\"e\"}","stamp":db.head}])}else{json!([])},
 "load"=>json!([{"id":"e","text":db.text,"note":null}]),other=>return Err(format!("unsupported {other}"))
 })
        })
    }
}
fn open(path: &std::path::Path) -> Client<SqliteStore> {
    let mut client = Client::open(SqliteStore::open(path).unwrap(), schema()).unwrap();
    // Only a subscribed channel is pulled and applied. A reopen keeps the row, so
    // this is one write per database; the repeat call finds the row and does nothing.
    client
        .transaction(|tx| tx.set_channel("book".into(), true))
        .unwrap();
    client
}
fn edit(client: &mut Client<SqliteStore>, text: &str) {
    client
        .transaction(|tx| {
            tx.enqueue(Mutation::new(
                "Edit",
                vec![Operation {
                    model: "Entry".into(),
                    op: OperationKind::Update,
                    identity: json!({"id":"e"}),
                    values: Some(json!({"text":text})),
                }],
            ))?;
            Ok(())
        })
        .unwrap();
}
fn visible(client: &mut Client<SqliteStore>) -> String {
    client
        .read(&schema().record_key("Entry", &json!({"id":"e"})).unwrap())
        .unwrap()
        .unwrap()["text"]
        .as_str()
        .unwrap()
        .into()
}
#[test]
fn deterministic_interleavings_preserve_local_priority_and_eventually_converge() {
    for seed in 0..64u64 {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("client.sqlite");
        let server = Backend::new();
        let mut client = open(&path);
        let page = server.pull(&mut client);
        client.apply_page(page).unwrap();
        edit(&mut client, "  first  ");
        let request = client.freeze().unwrap().unwrap();
        let receipt = server.push(&request);
        let calls = server.0.lock().unwrap().calls;
        if seed & 1 != 0 {
            drop(client);
            client = open(&path);
            assert_eq!(client.freeze().unwrap().unwrap(), request);
            assert_eq!(server.push(&request), receipt);
            assert_eq!(server.0.lock().unwrap().calls, calls);
        }
        if seed & 2 != 0 {
            edit(&mut client, "  second  ");
        }
        let ack = PushReceipt::decode(receipt.as_bytes()).unwrap();
        let page = server.pull(&mut client);
        if seed & 4 != 0 {
            client.apply_page(page).unwrap();
            if seed & 8 != 0 {
                drop(client);
                client = open(&path);
            }
            client.acknowledge(1, ack).unwrap();
        } else {
            client.acknowledge(1, ack).unwrap();
            if seed & 8 != 0 {
                drop(client);
                client = open(&path);
            }
            client.apply_page(page).unwrap();
        }
        let expected = if seed & 2 != 0 { "  second  " } else { "first" };
        assert_eq!(visible(&mut client), expected, "seed {seed}");
        if seed & 2 != 0 {
            let body = client.freeze().unwrap().unwrap();
            let receipt = server.push(&body);
            client
                .acknowledge(2, PushReceipt::decode(receipt.as_bytes()).unwrap())
                .unwrap();
            let page = server.pull(&mut client);
            client.apply_page(page).unwrap();
            assert_eq!(visible(&mut client), "second");
        }
        if seed & 16 != 0 {
            edit(&mut client, "reject");
            let body = client.freeze().unwrap().unwrap();
            let seq = otter_core::PushRequest::decode(&body)
                .unwrap()
                .batch_sequence;
            let ack = server.push(&body);
            client
                .acknowledge(seq, PushReceipt::decode(ack.as_bytes()).unwrap())
                .unwrap();
            assert_eq!(client.rejections().unwrap().len(), 1);
        }
        if seed & 32 != 0 {
            drop(client);
            client = open(&path);
        }
        assert_eq!(client.pending_count().unwrap(), 0, "seed {seed}");
        assert_eq!(client.before_image_count().unwrap(), 0);
        assert_eq!(visible(&mut client), server.0.lock().unwrap().text);
    }
}
