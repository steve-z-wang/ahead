#![allow(dead_code)]
//! Helpers shared by every client-facing integration test in this crate.
use ahead_client::*;
use ahead_sqlite::SqliteStore;
use serde_json::{Value, json};

pub fn schema() -> Schema {
    Schema::from_value(
        serde_json::from_str(include_str!("../../../../fixtures/schemas/entry.json")).unwrap(),
    )
    .unwrap()
}
pub fn open(path: &std::path::Path) -> Client<SqliteStore> {
    Client::open(SqliteStore::open(path).unwrap(), schema()).unwrap()
}
pub fn key() -> RecordKey {
    schema().record_key("Entry", &json!({"id":"e"})).unwrap()
}
pub fn update(text: &str) -> Operation {
    Operation {
        model: "Entry".into(),
        op: OperationKind::Update,
        identity: json!({"id":"e"}),
        values: Some(json!({ "text": text })),
    }
}
pub fn mutation(text: &str) -> Mutation {
    Mutation::new("Edit", vec![update(text)])
}
pub fn page(channel: &str, from: u64, to: u64, text: Option<&str>) -> PullPage {
    PullPage {
        channel: channel.into(),
        from_cursor: from,
        to_cursor: to,
        changes: vec![RecordChange {
            cursor: to,
            model: "Entry".into(),
            identity: json!({"id":"e"}),
            stamp: to,
            state: text
                .map(|t| json!({"text":t,"note":null}))
                .unwrap_or(Value::Null),
        }],
    }
}
/// Only a subscribed channel may be pulled: `apply_page` drops a page for any other.
pub fn subscribe(c: &mut Client<SqliteStore>, channel: &str) {
    c.transaction(|tx| tx.set_channel(channel.into(), true))
        .unwrap();
}
pub fn seed(c: &mut Client<SqliteStore>, text: &str) {
    c.transaction(|tx| {
        tx.direct(Operation {
            model: "Entry".into(),
            op: OperationKind::Create,
            identity: json!({"id":"e"}),
            values: Some(json!({"text":text,"note":null})),
        })
    })
    .unwrap();
}
pub fn family_schema() -> Schema {
    Schema::from_value(json!({"enums":[],"models":[
 {"name":"Book","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"title","nullable":false,"type":{"kind":"scalar","name":"string"}}]},
 {"name":"Comment","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"bookId","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"text","nullable":false,"type":{"kind":"scalar","name":"string"}}],"relations":[{"name":"book","target":"Book","fields":["bookId"],"targetFields":["id"],"onDelete":"delete"}],"unique":[["bookId","text"]]}
]})).unwrap()
}
pub fn create(model: &str, id: &str, values: Value) -> Operation {
    Operation {
        model: model.into(),
        op: OperationKind::Create,
        identity: json!({ "id": id }),
        values: Some(values),
    }
}
pub fn table_count(c: &mut Client<SqliteStore>, table: &str) -> u64 {
    c.read_sql(&format!("SELECT COUNT(*) AS n FROM \"{table}\""), &[])
        .unwrap()[0]["n"]
        .as_u64()
        .unwrap()
}
