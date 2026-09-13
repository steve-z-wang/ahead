# Client Storage Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the JSON-document client store and the in-memory `ClientState` with per-model SQLite tables, `otter_` framework tables, and an engine that works row by row inside SQLite transactions.

**Architecture:** `otter-client` owns the schema of the local database (DDL, reconciliation, every SQL statement) and talks to storage through a small `ClientStore` trait that is only a SQL executor with transaction, savepoint, writer and reader methods. `otter-sqlite` implements that trait with two rusqlite connections. The engine is split into data-access modules (`rows`, `ledger`, `queue`) and behavior modules (`mutate`, `downlink`, `push`, `query`) that all operate on an `Engine` handle bound to one open transaction. No state lives in memory between calls except the client id, the generation counter and the watcher list.

**Tech Stack:** Rust 2024, rusqlite 0.38 (bundled), serde_json, otter-core schema/protocol types. Tests run with `cargo test --workspace --locked`; the full gate is `bash scripts/test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-12-client-storage-design.md`

## Global Constraints

- Model tables are named exactly as the model (`Task`); framework tables carry the `otter_` prefix; before tables are `otter_before_<Model>`. A model named `otter_*` is rejected by `Schema::validate`.
- Storage types: `Boolean`, `Int` → `INTEGER`; `Float` → `REAL`; everything else → `TEXT`. Booleans stored as 0/1, scalar lists as JSON text. No framework columns on model tables. No foreign keys between model tables.
- Framework table set is fixed: `otter_client`, `otter_record`, `otter_claim`, `otter_subscription`, `otter_mutation`, `otter_mutation_operation`, `otter_mutation_dependency`, `otter_mutation_prerequisite`, `otter_push_checkpoint`, `otter_rejection`. No `otter_push`, no `otter_readiness`, no stored request, no stored receipt, no owner, no stored schema.
- Identity in framework tables is the canonical JSON of the identity object (`RecordKey::encoded_identity()`).
- A before row exists iff the main row diverges from server truth.
- Every write transaction ends with `UPDATE otter_client SET generation = generation + 1 WHERE generation = ?` affecting exactly one row; otherwise it rolls back with `stale client writer; reopen runtime`.
- Reads outside a transaction use the reader connection (`PRAGMA query_only = ON`) and see committed state only.
- Wire protocol is unchanged except: `RecordChange` gains an optional `stamp` (issue #8 makes it required later), and the server deduplicates pushes by `(clientId, sequence)` only.
- `Mutation.subscribe` / `Mutation.unsubscribe`, `SchemaMigration`, `open_with_migration`, `ClientState`, `TransactionSession`, `subscribe() -> Receiver<u64>` are removed with no aliases.
- Interim stamp rule until #8: a change without `stamp` is applied as if newer than local; a change with `stamp` follows the spec's comparison rules.
- Commits: one per task, message prefix `feat(client):`, `refactor(server):`, `docs:` as appropriate, ending with the attribution lines from the session reminder.

---

## File structure

| File | Responsibility |
| --- | --- |
| `crates/core/src/schema.rs` (modify) | `FieldDescriptor.default`, `otter_` name rejection |
| `crates/core/src/protocol.rs` (modify) | `RecordChange.stamp: Option<u64>` |
| `crates/server/src/lib.rs` (modify) | push dedup by sequence only |
| `packages/persistence-prisma/{index.mts,migration.sql}` (modify) | drop `request_hash` |
| `crates/client/src/store.rs` (create) | `ClientStore` trait, `SqlRows` |
| `crates/client/src/ddl.rs` (create) | table naming, DDL, reconciliation on open |
| `crates/client/src/engine.rs` (create) | `Engine` handle: `rows`, `exec`, changed-table tracking |
| `crates/client/src/rows.rs` (create) | JSON ↔ row codec; model and before table operations |
| `crates/client/src/ledger.rs` (create) | `otter_record`, `otter_claim`, `otter_subscription` |
| `crates/client/src/queue.rs` (create) | mutation, operation, dependency, prerequisite, checkpoint, rejection tables |
| `crates/client/src/mutate.rs` (create) | apply-to-row, rebuild, enqueue, direct writes, authority, cascade |
| `crates/client/src/policies.rs` (rewrite) | schema-declared dependencies, over `Engine` |
| `crates/client/src/downlink.rs` (create) | `apply_page` with stamps and tombstones |
| `crates/client/src/push.rs` (create) | freeze, acknowledge, settle, rejections, readiness |
| `crates/client/src/query.rs` (rewrite) | `QuerySpec` evaluation over tables, related, referencing, read-only SQL |
| `crates/client/src/lib.rs` (rewrite) | public types, `Client`, `ClientTransaction`, sessions, watch |
| `crates/client/src/transport.rs` (modify) | use `checkpoint_channels()` and `subscriptions()` |
| `crates/client/src/{cascade.rs,migration.rs}` (delete) | folded into `mutate.rs`; migration replaced by reconciliation |
| `crates/sqlite/src/lib.rs` (rewrite) | `SqliteStore`: writer + reader connections |
| `crates/sqlite/src/query.rs` (delete) | per-query materialization removed |
| `crates/sqlite/tests/{store.rs,ddl.rs,engine.rs,downlink.rs,push.rs,query.rs}` (create) | tests per module, through `SqliteStore` |
| `crates/sqlite/tests/client.rs` (delete) | replaced by the files above |
| `bindings/common/src/lib.rs` (modify) | sessions as real transactions, `changedTables`, `watch` |
| `integration/rust/tests/scenarios.rs` (modify) | no owner, no hash |
| `docs/architecture/{code-organization.md,compatibility-and-recovery.md}` (modify) | describe the table layout |

Tests for `otter-client` live in `crates/sqlite/tests/` because `otter-sqlite` depends on `otter-client` and a dev-dependency in the other direction would be circular.

---

### Task 1: Server deduplicates pushes by sequence only

**Files:**
- Modify: `crates/server/src/lib.rs:295-330`, `:400-408`
- Modify: `packages/persistence-prisma/index.mts:26-56`
- Modify: `packages/persistence-prisma/migration.sql:1-7`
- Modify: `integration/persistence/server/runtime.test.mjs:40`, `:46`
- Modify: `integration/rust/tests/scenarios.rs:89-90`
- Modify: `docs/architecture/compatibility-and-recovery.md` (Application recovery bullet on lost Push)

**Interfaces:**
- Produces: host op `claim` returns `{clientId, owner, sequence, receipt}`; host op `saveReceipt` takes `{owner, clientId, sequence, receipt}`. The error code `request_conflict` no longer exists.

- [ ] **Step 1: Change the Node runtime test to expect receipt replay for a changed body**

In `integration/persistence/server/runtime.test.mjs` replace line 46:

```js
 assert.equal(await backend.push('alice',push('dedup',1,[mutation(1,'changed')])),receipt);assert.equal(called,calls);
```

and replace line 40:

```js
 await reusable.bind(tx).call({op:'saveReceipt',clientId:'c',owner:'o',sequence:1,receipt:'r'});
```

- [ ] **Step 2: Run the Node test to see it fail**

Run: `bash integration/persistence/server/run.sh`
Expected: FAIL on the dedup test with `request_conflict`.

- [ ] **Step 3: Remove the hash from the Rust server**

In `crates/server/src/lib.rs` delete line 304 (`let hash = request.semantic_hash()...`) and replace lines 315-323 with:

```rust
    if request.batch_sequence == last {
        return locked["receipt"]
            .as_str()
            .map(str::to_owned)
            .ok_or("receipt missing".into());
    }
```

Replace the `saveReceipt` call at line 407 with:

```rust
    host.call(json!({"op":"saveReceipt","owner":owner,"clientId":request.client_id,"sequence":request.batch_sequence,"receipt":text})).await?;
```

- [ ] **Step 4: Remove the column from the Prisma adapter**

In `packages/persistence-prisma/migration.sql` delete the line ` request_hash text,`.

In `packages/persistence-prisma/index.mts` change the `claim` select to `SELECT client_id, owner_id, sequence, receipt FROM otter_client WHERE client_id=$1 FOR UPDATE`, drop `hash: row.request_hash,` from the returned object, and change `saveReceipt` to:

```ts
        const count = await tx.$executeRawUnsafe(
          "UPDATE otter_client SET sequence=$3, receipt=$4 WHERE client_id=$1 AND owner_id=$2",
          r.clientId,
          r.owner,
          BigInt(r.sequence),
          r.receipt,
        );
```

- [ ] **Step 5: Drop hash from the Rust scenario host**

In `integration/rust/tests/scenarios.rs` lines 89-90 remove the `"hash":null` and `"hash":r["hash"]` entries so the two ops read:

```rust
 "claim"=>db.clients.entry(r["clientId"].as_str().unwrap().into()).or_insert_with(||json!({"clientId":r["clientId"],"owner":r["owner"],"sequence":0,"receipt":null})).clone(),
 "saveReceipt"=>{db.clients.insert(r["clientId"].as_str().unwrap().into(),json!({"clientId":r["clientId"],"owner":r["owner"],"sequence":r["sequence"],"receipt":r["receipt"]}));Value::Null},
```

- [ ] **Step 6: Document the rule**

In `docs/architecture/compatibility-and-recovery.md` replace the bullet starting "A lost Push response is retried" with:

```markdown
- A lost Push response is retried by re-encoding the same push sequence from the queued operations. The backend replays the stored receipt for a repeated `(clientId, sequence)` without inspecting the body, so one client identity must never push from two databases; the second database's push would receive the first one's receipt.
```

- [ ] **Step 7: Run tests**

Run: `cargo test -p otter-server --locked && cargo test -p otter-integration --locked && bash integration/persistence/server/run.sh`
Expected: PASS. (`cargo test -p otter-integration` names the `integration/rust` crate; check its `Cargo.toml` `name` if the command fails to resolve.)

- [ ] **Step 8: Commit**

```bash
git add crates/server/src/lib.rs packages/persistence-prisma integration/persistence/server/runtime.test.mjs integration/rust/tests/scenarios.rs docs/architecture/compatibility-and-recovery.md
git commit -m "refactor(server): deduplicate pushes by client and sequence only"
```

---

### Task 2: Core schema and protocol additions

**Files:**
- Modify: `crates/core/src/schema.rs:56-61`, `:100-120`
- Modify: `crates/core/src/protocol.rs:175-182`
- Test: `crates/core/tests/contracts.rs`

**Interfaces:**
- Produces: `FieldDescriptor { name, value_type, nullable, default: Option<Value> }` (serde key `default`, omitted when `None`); `RecordChange { cursor, model, identity, stamp: Option<u64>, state }` (serde key `stamp`, omitted when `None`); `Schema::validate` rejects model names starting with `otter_`.

- [ ] **Step 1: Write the failing tests**

Append to `crates/core/tests/contracts.rs`:

```rust
#[test]
fn field_default_and_record_stamp_round_trip_and_otter_prefix_is_rejected() {
    let field: FieldDescriptor = serde_json::from_value(
        json!({"name":"rank","nullable":false,"type":{"kind":"scalar","name":"int"},"default":0}),
    )
    .unwrap();
    assert_eq!(field.default, Some(json!(0)));
    let plain: FieldDescriptor =
        serde_json::from_value(json!({"name":"t","nullable":true,"type":{"kind":"scalar","name":"string"}}))
            .unwrap();
    assert_eq!(plain.default, None);
    assert!(!serde_json::to_string(&plain).unwrap().contains("default"));
    let change = RecordChange::decode(
        br#"{"syncId":1,"model":"E","identity":{"id":"e"},"stamp":7,"state":null}"#,
    )
    .unwrap();
    assert_eq!(change.stamp, Some(7));
    let unstamped = RecordChange::decode(br#"{"syncId":1,"model":"E","identity":{"id":"e"},"state":null}"#).unwrap();
    assert_eq!(unstamped.stamp, None);
    assert!(!String::from_utf8(unstamped.encode().unwrap()).unwrap().contains("stamp"));
    let bad = Schema::from_value(json!({"enums":[],"models":[{"name":"otter_x","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}}]}]}));
    assert!(bad.is_err());
}
```

If `RecordChange` has no `decode`/`encode` of its own, use `PullPage::decode` with a one-change page and read `page.changes[0]`.

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-core --locked field_default_and_record_stamp`
Expected: FAIL to compile (`default` and `stamp` fields missing).

- [ ] **Step 3: Implement**

In `crates/core/src/schema.rs` change `FieldDescriptor`:

```rust
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FieldDescriptor {
    pub name: String,
    #[serde(rename = "type")]
    pub value_type: ValueType,
    pub nullable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<Value>,
}
```

In `Schema::validate`, inside the `for model in &self.models` loop, extend the existing invalid-model condition:

```rust
            if model.name.is_empty()
                || model.name.starts_with("otter_")
                || !names.insert(model.name.as_str())
                || model.identity.is_empty()
            {
                return Err(invalid("invalid model descriptor"));
            }
```

In `crates/core/src/protocol.rs` add to `RecordChange` after `identity`:

```rust
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stamp: Option<u64>,
```

Fix every literal `RecordChange { ... }` construction in the workspace (`grep -rn "RecordChange {" crates integration bindings`) by adding `stamp: None,`.

- [ ] **Step 4: Run tests**

Run: `cargo test --workspace --locked`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/core crates/sqlite/tests crates/server integration
git commit -m "feat(core): optional field defaults, record stamp on the wire, reserved otter_ prefix"
```

---

### Task 3: Store contract and the two-connection SQLite store

**Files:**
- Create: `crates/client/src/store.rs`
- Modify: `crates/client/src/lib.rs` (add `pub mod store; pub use store::*;` at the top; leave the rest untouched until Task 6)
- Rewrite: `crates/sqlite/src/lib.rs`
- Delete: `crates/sqlite/src/query.rs`
- Test: `crates/sqlite/tests/store.rs`

Until Task 6 replaces `lib.rs`, the old `ClientStore` trait at `crates/client/src/lib.rs:18-31` conflicts with the new one. Rename the old trait to `LegacyClientStore` in this task (the old `SqliteStore` implementation is deleted here, so nothing implements it; it is removed in Task 6).

**Interfaces:**
- Produces:

```rust
pub struct SqlRows { pub columns: Vec<String>, pub rows: Vec<Vec<Value>> }
pub trait ClientStore {
    fn begin(&mut self) -> Result<()>;                 // BEGIN IMMEDIATE
    fn commit(&mut self) -> Result<()>;
    fn rollback(&mut self) -> Result<()>;
    fn savepoint(&mut self, name: &str) -> Result<()>;
    fn release(&mut self, name: &str) -> Result<()>;
    fn rollback_to(&mut self, name: &str) -> Result<()>;
    fn execute(&mut self, sql: &str, parameters: &[Value]) -> Result<usize>;   // writer
    fn execute_batch(&mut self, sql: &str) -> Result<()>;                       // writer, several statements
    fn query(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows>;   // writer connection: sees the open transaction
    fn query_committed(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows>; // reader connection: committed state only
}
```
  Both query methods refuse statements that are not read-only or return no columns with `SQL write statements are forbidden`. Values: `INTEGER → Number`, `REAL → Number`, `TEXT → String`, `NULL → Null`, `BLOB → error`. Parameters: `Bool → 0/1`, `Array|Object → JSON text`, others as is.
- `SqliteStore::open(path) -> Result<SqliteStore>`.

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/store.rs`:

```rust
use otter_client::ClientStore;
use otter_sqlite::SqliteStore;
use serde_json::json;

fn store() -> (tempfile::TempDir, SqliteStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteStore::open(dir.path().join("db")).unwrap();
    (dir, store)
}

#[test]
fn reader_sees_only_committed_rows_and_writer_sees_its_own() {
    let (_dir, mut s) = store();
    s.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, flag INTEGER)").unwrap();
    s.begin().unwrap();
    s.execute("INSERT INTO t VALUES (?,?,?)", &[json!(1), json!("a"), json!(true)]).unwrap();
    assert_eq!(s.query("SELECT name, flag FROM t", &[]).unwrap().rows, vec![vec![json!("a"), json!(1)]]);
    assert!(s.query_committed("SELECT name FROM t", &[]).unwrap().rows.is_empty());
    s.commit().unwrap();
    let rows = s.query_committed("SELECT name, flag FROM t", &[]).unwrap();
    assert_eq!(rows.columns, vec!["name", "flag"]);
    assert_eq!(rows.rows, vec![vec![json!("a"), json!(1)]]);
}

#[test]
fn savepoints_nest_and_rollback_independently() {
    let (_dir, mut s) = store();
    s.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY)").unwrap();
    s.begin().unwrap();
    s.execute("INSERT INTO t VALUES (1)", &[]).unwrap();
    s.savepoint("a").unwrap();
    s.execute("INSERT INTO t VALUES (2)", &[]).unwrap();
    s.rollback_to("a").unwrap();
    s.savepoint("b").unwrap();
    s.execute("INSERT INTO t VALUES (3)", &[]).unwrap();
    s.release("b").unwrap();
    s.commit().unwrap();
    let ids = s.query_committed("SELECT id FROM t ORDER BY id", &[]).unwrap().rows;
    assert_eq!(ids, vec![vec![json!(1)], vec![json!(3)]]);
    s.begin().unwrap();
    s.execute("INSERT INTO t VALUES (4)", &[]).unwrap();
    s.rollback().unwrap();
    assert_eq!(s.query_committed("SELECT COUNT(*) FROM t", &[]).unwrap().rows, vec![vec![json!(2)]]);
}

#[test]
fn queries_refuse_writes_and_arrays_travel_as_json_text() {
    let (_dir, mut s) = store();
    s.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY, tags TEXT)").unwrap();
    s.execute("INSERT INTO t VALUES (?,?)", &[json!(1), json!(["x", "y"])]).unwrap();
    assert_eq!(s.query_committed("SELECT tags FROM t", &[]).unwrap().rows, vec![vec![json!("[\"x\",\"y\"]")]]);
    assert!(s.query_committed("DELETE FROM t RETURNING id", &[]).is_err());
    assert!(s.query("PRAGMA user_version=10", &[]).is_err());
    assert!(s.query_committed("INSERT INTO t VALUES (2, NULL)", &[]).is_err());
}

#[test]
fn second_writer_waits_then_fails_on_conflicting_immediate_transaction() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut a = SqliteStore::open(&path).unwrap();
    let mut b = SqliteStore::open(&path).unwrap();
    a.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY)").unwrap();
    a.begin().unwrap();
    assert!(b.begin().is_err(), "busy timeout must expire into an error, not a hang");
    a.rollback().unwrap();
    b.begin().unwrap();
    b.rollback().unwrap();
}
```

The last test takes the busy timeout to run; set it to one second in `SqliteStore::open` so the suite stays fast.

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test store`
Expected: FAIL to compile (`ClientStore` methods missing).

- [ ] **Step 3: Write the trait**

Create `crates/client/src/store.rs`:

```rust
//! Storage contract: a SQL executor with transactions. The engine owns every statement.
use otter_core::Result;
use serde_json::Value;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SqlRows {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<Value>>,
}

pub trait ClientStore {
    fn begin(&mut self) -> Result<()>;
    fn commit(&mut self) -> Result<()>;
    fn rollback(&mut self) -> Result<()>;
    fn savepoint(&mut self, name: &str) -> Result<()>;
    fn release(&mut self, name: &str) -> Result<()>;
    fn rollback_to(&mut self, name: &str) -> Result<()>;
    fn execute(&mut self, sql: &str, parameters: &[Value]) -> Result<usize>;
    fn execute_batch(&mut self, sql: &str) -> Result<()>;
    fn query(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows>;
    fn query_committed(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows>;
}
```

In `crates/client/src/lib.rs` add `pub mod store;` and `pub use store::*;` next to the other module declarations, and rename the existing `pub trait ClientStore` (line 18) to `pub trait LegacyClientStore` together with the `S: ClientStore` bounds in that file (`Client<S: ClientStore>` → `Client<S: LegacyClientStore>`, and the two in `transport.rs`).

- [ ] **Step 4: Write the SQLite store**

Replace `crates/sqlite/src/lib.rs` with:

```rust
//! SQLite implements the client's storage contract with one writer and one reader connection.
use otter_client::{ClientStore, SqlRows};
use otter_core::{Result, invalid};
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::{Connection, params_from_iter};
use serde_json::Value;
use std::path::Path;

pub struct SqliteStore {
    writer: Connection,
    reader: Connection,
}

fn db(e: rusqlite::Error) -> otter_core::Error {
    invalid(format!("sqlite: {e}"))
}

fn parameter(value: &Value) -> Result<SqlValue> {
    Ok(match value {
        Value::Null => SqlValue::Null,
        Value::Bool(v) => SqlValue::Integer(i64::from(*v)),
        Value::Number(v) => {
            if let Some(v) = v.as_i64() {
                SqlValue::Integer(v)
            } else {
                SqlValue::Real(v.as_f64().ok_or_else(|| invalid("invalid SQL number"))?)
            }
        }
        Value::String(v) => SqlValue::Text(v.clone()),
        Value::Array(_) | Value::Object(_) => SqlValue::Text(serde_json::to_string(value)?),
    })
}

fn rows(connection: &Connection, sql: &str, parameters: &[Value]) -> Result<SqlRows> {
    let mut statement = connection.prepare(sql).map_err(db)?;
    if !statement.readonly() || statement.column_count() == 0 {
        return Err(invalid("SQL write statements are forbidden"));
    }
    let columns = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let values = parameters.iter().map(parameter).collect::<Result<Vec<_>>>()?;
    let mut cursor = statement.query(params_from_iter(values)).map_err(db)?;
    let mut output = vec![];
    while let Some(row) = cursor.next().map_err(db)? {
        let mut record = Vec::with_capacity(columns.len());
        for index in 0..columns.len() {
            record.push(match row.get_ref(index).map_err(db)? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(v) => Value::from(v),
                ValueRef::Real(v) => Value::from(v),
                ValueRef::Text(v) => Value::from(
                    std::str::from_utf8(v).map_err(|_| invalid("SQL text must be UTF8"))?,
                ),
                ValueRef::Blob(_) => return Err(invalid("SQL blobs cannot cross the JSON boundary")),
            });
        }
        output.push(record);
    }
    Ok(SqlRows { columns, rows: output })
}

fn name_ok(name: &str) -> Result<()> {
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(invalid("invalid savepoint name"));
    }
    Ok(())
}

impl SqliteStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let writer = Connection::open(&path).map_err(db)?;
        writer
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000;")
            .map_err(db)?;
        let reader = Connection::open(&path).map_err(db)?;
        reader
            .execute_batch("PRAGMA query_only=ON; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000;")
            .map_err(db)?;
        Ok(Self { writer, reader })
    }
}

impl ClientStore for SqliteStore {
    fn begin(&mut self) -> Result<()> {
        self.writer.execute_batch("BEGIN IMMEDIATE").map_err(db)
    }
    fn commit(&mut self) -> Result<()> {
        self.writer.execute_batch("COMMIT").map_err(db)
    }
    fn rollback(&mut self) -> Result<()> {
        self.writer.execute_batch("ROLLBACK").map_err(db)
    }
    fn savepoint(&mut self, name: &str) -> Result<()> {
        name_ok(name)?;
        self.writer.execute_batch(&format!("SAVEPOINT {name}")).map_err(db)
    }
    fn release(&mut self, name: &str) -> Result<()> {
        name_ok(name)?;
        self.writer.execute_batch(&format!("RELEASE {name}")).map_err(db)
    }
    fn rollback_to(&mut self, name: &str) -> Result<()> {
        name_ok(name)?;
        self.writer
            .execute_batch(&format!("ROLLBACK TO {name}; RELEASE {name}"))
            .map_err(db)
    }
    fn execute(&mut self, sql: &str, parameters: &[Value]) -> Result<usize> {
        let values = parameters.iter().map(parameter).collect::<Result<Vec<_>>>()?;
        self.writer.execute(sql, params_from_iter(values)).map_err(db)
    }
    fn execute_batch(&mut self, sql: &str) -> Result<()> {
        self.writer.execute_batch(sql).map_err(db)
    }
    fn query(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows> {
        rows(&self.writer, sql, parameters)
    }
    fn query_committed(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows> {
        rows(&self.reader, sql, parameters)
    }
}
```

Delete `crates/sqlite/src/query.rs`. Delete `crates/sqlite/tests/client.rs` (its behaviors are re-created per module in Tasks 6-9; keep a copy in your scratch space to port assertions from).

- [ ] **Step 5: Run the store tests**

Run: `cargo test -p otter-sqlite --locked --test store`
Expected: PASS. Other crates (`bindings/common`, `integration/rust`) do not compile yet; that is expected until Task 10. Run only the named targets from here to Task 10.

- [ ] **Step 6: Commit**

```bash
git add crates/client/src/store.rs crates/client/src/lib.rs crates/client/src/transport.rs crates/sqlite
git commit -m "feat(client): SQL executor store contract with writer and reader connections"
```

---

### Task 4: DDL and reconciliation on open

**Files:**
- Create: `crates/client/src/ddl.rs`
- Modify: `crates/client/src/lib.rs` (add `pub mod ddl;`)
- Test: `crates/sqlite/tests/ddl.rs`

**Interfaces:**
- Produces (all `pub` so tests can call them; the engine uses them too):

```rust
pub const FRAMEWORK_TABLES: &[&str];
pub const FRAMEWORK_DDL: &str;
pub fn quote(name: &str) -> String;                       // "name" with inner quotes doubled
pub fn before_table(model: &str) -> String;               // otter_before_<model>
pub fn storage_type(value_type: &ValueType) -> &'static str;
pub fn model_ddl(model: &ModelDescriptor) -> Vec<String>;  // CREATE TABLE IF NOT EXISTS main, before, unique indexes
pub fn reconcile<S: ClientStore>(store: &mut S, schema: &Schema) -> Result<()>; // caller holds the transaction
```

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/ddl.rs`:

```rust
use otter_client::ddl::{FRAMEWORK_DDL, FRAMEWORK_TABLES, reconcile};
use otter_client::ClientStore;
use otter_core::Schema;
use otter_sqlite::SqliteStore;
use serde_json::{Value, json};

fn schema(fields: Value) -> Schema {
    Schema::from_value(json!({"enums":[],"models":[{"name":"Task","identity":["id"],"fields":fields,"unique":[["title"]]}]})).unwrap()
}
fn base() -> Value {
    json!([{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},
           {"name":"title","nullable":false,"type":{"kind":"scalar","name":"string"}},
           {"name":"done","nullable":false,"type":{"kind":"scalar","name":"boolean"}}])
}
fn columns(s: &mut SqliteStore, table: &str) -> Vec<(String, String, i64)> {
    s.query_committed(&format!("PRAGMA table_info(\"{table}\")"), &[]).unwrap().rows.into_iter()
        .map(|r| (r[1].as_str().unwrap().into(), r[2].as_str().unwrap().into(), r[5].as_i64().unwrap()))
        .collect()
}
fn open(dir: &tempfile::TempDir, schema: &Schema) -> otter_core::Result<SqliteStore> {
    let mut s = SqliteStore::open(dir.path().join("db")).unwrap();
    s.execute_batch(FRAMEWORK_DDL).unwrap();
    s.begin().unwrap();
    match reconcile(&mut s, schema) {
        Ok(()) => { s.commit().unwrap(); Ok(s) }
        Err(e) => { s.rollback().unwrap(); Err(e) }
    }
}

#[test]
fn creates_model_before_and_framework_tables() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = open(&dir, &schema(base())).unwrap();
    assert_eq!(columns(&mut s, "Task"), vec![("id".into(), "TEXT".into(), 1), ("title".into(), "TEXT".into(), 0), ("done".into(), "INTEGER".into(), 0)]);
    assert_eq!(columns(&mut s, "otter_before_Task"), columns(&mut s, "Task"));
    for table in FRAMEWORK_TABLES {
        assert!(!columns(&mut s, table).is_empty(), "{table}");
    }
    let indexes = s.query_committed("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='Task' AND name='Task_title_unique'", &[]).unwrap();
    assert_eq!(indexes.rows.len(), 1);
    assert!(s.execute("INSERT INTO \"Task\" VALUES ('a','same',0)", &[]).is_ok());
    assert!(s.execute("INSERT INTO \"Task\" VALUES ('b','same',0)", &[]).is_err());
}

#[test]
fn adds_missing_columns_to_both_tables_and_keeps_unknown_ones() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = open(&dir, &schema(base())).unwrap();
    s.execute("INSERT INTO \"Task\" VALUES ('a','t',1)", &[]).unwrap();
    s.execute_batch("ALTER TABLE \"Task\" ADD COLUMN legacy TEXT").unwrap();
    drop(s);
    let mut fields = base().as_array().unwrap().clone();
    fields.push(json!({"name":"note","nullable":true,"type":{"kind":"scalar","name":"string"}}));
    fields.push(json!({"name":"rank","nullable":false,"type":{"kind":"scalar","name":"int"},"default":3}));
    let mut s = open(&dir, &schema(Value::Array(fields))).unwrap();
    let names: Vec<String> = columns(&mut s, "Task").into_iter().map(|c| c.0).collect();
    assert_eq!(names, vec!["id", "title", "done", "legacy", "note", "rank"]);
    let before: Vec<String> = columns(&mut s, "otter_before_Task").into_iter().map(|c| c.0).collect();
    assert_eq!(before, vec!["id", "title", "done", "note", "rank"]);
    assert_eq!(s.query_committed("SELECT rank, note FROM \"Task\"", &[]).unwrap().rows, vec![vec![json!(3), Value::Null]]);
}

#[test]
fn rejects_non_nullable_column_without_default_identity_change_and_type_change() {
    let dir = tempfile::tempdir().unwrap();
    drop(open(&dir, &schema(base())).unwrap());
    let mut fields = base().as_array().unwrap().clone();
    fields.push(json!({"name":"rank","nullable":false,"type":{"kind":"scalar","name":"int"}}));
    assert!(open(&dir, &schema(Value::Array(fields))).is_err());
    let retyped = json!([{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},
                         {"name":"title","nullable":false,"type":{"kind":"scalar","name":"string"}},
                         {"name":"done","nullable":false,"type":{"kind":"scalar","name":"string"}}]);
    assert!(open(&dir, &schema(retyped)).is_err());
    let composite = Schema::from_value(json!({"enums":[],"models":[{"name":"Task","identity":["id","title"],"fields":base()}]})).unwrap();
    assert!(open(&dir, &composite).is_err());
    let mut s = SqliteStore::open(dir.path().join("db")).unwrap();
    assert_eq!(columns(&mut s, "Task").len(), 3, "a failed reconciliation changes nothing");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test ddl`
Expected: FAIL to compile (`otter_client::ddl` missing).

- [ ] **Step 3: Implement `ddl.rs`**

Create `crates/client/src/ddl.rs`:

```rust
//! The tables are the schema record. Reconciliation makes them match the compiled schema or fails.
use crate::store::ClientStore;
use otter_core::{FieldDescriptor, ModelDescriptor, Result, ScalarType, Schema, ValueType, invalid};
use serde_json::Value;
use std::collections::BTreeMap;

pub const FRAMEWORK_TABLES: &[&str] = &[
    "otter_client",
    "otter_record",
    "otter_claim",
    "otter_subscription",
    "otter_mutation",
    "otter_mutation_operation",
    "otter_mutation_dependency",
    "otter_mutation_prerequisite",
    "otter_push_checkpoint",
    "otter_rejection",
];

pub const FRAMEWORK_DDL: &str = "
CREATE TABLE IF NOT EXISTS otter_client (
  client_id    TEXT PRIMARY KEY,
  next_ordinal INTEGER NOT NULL,
  next_push    INTEGER NOT NULL,
  generation   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS otter_record (
  model TEXT NOT NULL, identity TEXT NOT NULL, stamp INTEGER NOT NULL,
  PRIMARY KEY (model, identity)
);
CREATE TABLE IF NOT EXISTS otter_claim (
  channel TEXT NOT NULL, model TEXT NOT NULL, identity TEXT NOT NULL,
  PRIMARY KEY (channel, model, identity)
);
CREATE INDEX IF NOT EXISTS otter_claim_record ON otter_claim (model, identity);
CREATE TABLE IF NOT EXISTS otter_subscription (
  channel TEXT PRIMARY KEY, cursor INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS otter_mutation (
  ordinal INTEGER PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL, push INTEGER
);
CREATE TABLE IF NOT EXISTS otter_mutation_operation (
  ordinal INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('wire','companion','effect')),
  model TEXT NOT NULL, identity TEXT NOT NULL,
  op TEXT NOT NULL CHECK (op IN ('create','update','delete')),
  \"values\" TEXT,
  PRIMARY KEY (ordinal, position)
);
CREATE INDEX IF NOT EXISTS otter_mutation_operation_record ON otter_mutation_operation (model, identity, ordinal, position);
CREATE TABLE IF NOT EXISTS otter_mutation_dependency (
  ordinal INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  depends_on INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('lifecycle','sequence')),
  PRIMARY KEY (ordinal, depends_on),
  CHECK (depends_on < ordinal)
);
CREATE TABLE IF NOT EXISTS otter_mutation_prerequisite (
  ordinal INTEGER NOT NULL REFERENCES otter_mutation(ordinal) ON DELETE CASCADE,
  key TEXT NOT NULL, error TEXT,
  PRIMARY KEY (ordinal, key)
);
CREATE TABLE IF NOT EXISTS otter_push_checkpoint (
  push INTEGER NOT NULL, channel TEXT NOT NULL, cursor INTEGER NOT NULL,
  PRIMARY KEY (push, channel)
);
CREATE TABLE IF NOT EXISTS otter_rejection (
  ordinal INTEGER PRIMARY KEY, name TEXT NOT NULL, code TEXT NOT NULL, detail TEXT
);
";

pub fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

pub fn before_table(model: &str) -> String {
    format!("otter_before_{model}")
}

pub fn storage_type(value_type: &ValueType) -> &'static str {
    match value_type {
        ValueType::Scalar { name: ScalarType::Boolean | ScalarType::Int } => "INTEGER",
        ValueType::Scalar { name: ScalarType::Float } => "REAL",
        _ => "TEXT",
    }
}

fn literal(field: &FieldDescriptor) -> Result<String> {
    let value = field
        .default
        .as_ref()
        .ok_or_else(|| invalid(format!("column {} is not nullable and has no default", field.name)))?;
    Ok(match value {
        Value::Bool(b) => i64::from(*b).to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => format!("'{}'", s.replace('\'', "''")),
        Value::Null => return Err(invalid(format!("column {} default cannot be null", field.name))),
        other => format!("'{}'", serde_json::to_string(other)?.replace('\'', "''")),
    })
}

fn column(field: &FieldDescriptor) -> String {
    let null = if field.nullable { "" } else { " NOT NULL" };
    format!("{} {}{null}", quote(&field.name), storage_type(&field.value_type))
}

fn table_ddl(table: &str, model: &ModelDescriptor) -> String {
    let columns = model.fields.iter().map(column).collect::<Vec<_>>().join(", ");
    let key = model.identity.iter().map(|f| quote(f)).collect::<Vec<_>>().join(", ");
    format!("CREATE TABLE IF NOT EXISTS {} ({columns}, PRIMARY KEY ({key}))", quote(table))
}

pub fn model_ddl(model: &ModelDescriptor) -> Vec<String> {
    let mut statements = vec![
        table_ddl(&model.name, model),
        table_ddl(&before_table(&model.name), model),
    ];
    for fields in &model.unique {
        let name = format!("{}_{}_unique", model.name, fields.join("_"));
        let columns = fields.iter().map(|f| quote(f)).collect::<Vec<_>>().join(", ");
        statements.push(format!(
            "CREATE UNIQUE INDEX IF NOT EXISTS {} ON {} ({columns})",
            quote(&name),
            quote(&model.name)
        ));
    }
    statements
}

struct Existing {
    columns: BTreeMap<String, String>, // name -> declared type
    identity: Vec<String>,              // pk columns in key order
}

fn existing<S: ClientStore>(store: &mut S, table: &str) -> Result<Option<Existing>> {
    let rows = store.query(&format!("PRAGMA table_info({})", quote(table)), &[])?;
    if rows.rows.is_empty() {
        return Ok(None);
    }
    let mut columns = BTreeMap::new();
    let mut keyed = vec![];
    for row in rows.rows {
        let name = row[1].as_str().ok_or_else(|| invalid("table_info name"))?.to_string();
        let ty = row[2].as_str().unwrap_or("").to_ascii_uppercase();
        let pk = row[5].as_i64().unwrap_or(0);
        if pk > 0 {
            keyed.push((pk, name.clone()));
        }
        columns.insert(name, ty);
    }
    keyed.sort();
    Ok(Some(Existing { columns, identity: keyed.into_iter().map(|(_, n)| n).collect() }))
}

pub fn reconcile<S: ClientStore>(store: &mut S, schema: &Schema) -> Result<()> {
    for model in &schema.models {
        let Some(current) = existing(store, &model.name)? else {
            for statement in model_ddl(model) {
                store.execute(&statement, &[])?;
            }
            continue;
        };
        if current.identity != model.identity {
            return Err(invalid(format!("identity columns of {} changed; cannot open", model.name)));
        }
        for field in &model.fields {
            match current.columns.get(&field.name) {
                Some(ty) if ty == storage_type(&field.value_type) => {}
                Some(ty) => {
                    return Err(invalid(format!(
                        "column {}.{} is {ty} in the database but {} in the schema",
                        model.name,
                        field.name,
                        storage_type(&field.value_type)
                    )));
                }
                None => {
                    let mut definition = column(field);
                    if !field.nullable {
                        definition.push_str(&format!(" DEFAULT {}", literal(field)?));
                    }
                    for table in [model.name.clone(), before_table(&model.name)] {
                        store.execute(&format!("ALTER TABLE {} ADD COLUMN {definition}", quote(&table)), &[])?;
                    }
                }
            }
        }
        for statement in model_ddl(model).into_iter().skip(2) {
            store.execute(&statement, &[])?;
        }
    }
    Ok(())
}
```

Note `existing()` uses `store.query` (writer) so it sees tables created earlier in the same transaction.

- [ ] **Step 4: Run the DDL tests**

Run: `cargo test -p otter-sqlite --locked --test ddl`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/client/src/ddl.rs crates/client/src/lib.rs crates/sqlite/tests/ddl.rs
git commit -m "feat(client): per-model table DDL and reconciliation on open"
```

---

### Task 5: Engine handle and data-access modules

**Files:**
- Create: `crates/client/src/engine.rs`, `crates/client/src/rows.rs`, `crates/client/src/ledger.rs`, `crates/client/src/queue.rs`
- Modify: `crates/client/src/lib.rs` (add `pub mod engine; pub mod rows; pub mod ledger; pub mod queue;`; `Operation`, `OperationKind`, `Mutation` already live in `lib.rs`, `Rejection` comes from `otter_core`)
- Test: `crates/sqlite/tests/engine.rs`

These modules are `pub` so the tests in `crates/sqlite/tests` can drive them through `SqliteStore`.

**Interfaces:**
- Produces (`engine.rs`):

```rust
pub struct Engine<'a, S: ClientStore> {
    pub store: &'a mut S,
    pub schema: &'a Schema,
    pub changed: &'a mut BTreeSet<String>,
    pub committed: bool,   // true: reads use query_committed (reader); false: query (writer)
}
impl<'a, S: ClientStore> Engine<'a, S> {
    pub fn new(store: &'a mut S, schema: &'a Schema, changed: &'a mut BTreeSet<String>, committed: bool) -> Self;
    pub fn rows(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows>;
    pub fn exec(&mut self, table: &str, sql: &str, parameters: &[Value]) -> Result<usize>; // records `table` in `changed`
    pub fn scalar(&mut self, sql: &str, parameters: &[Value]) -> Result<Option<Value>>;   // first column of first row
}
pub(crate) fn as_u64(value: &Value) -> Result<u64>;
```
- Produces (`rows.rs`):

```rust
pub fn columns_sql(model: &ModelDescriptor) -> String;                 // "a","b","c"
pub fn identity_where(model: &ModelDescriptor) -> String;              // "a"=? AND "b"=?
pub fn identity_params(model: &ModelDescriptor, identity: &Value) -> Vec<Value>;
pub fn decode_row(model: &ModelDescriptor, columns: &[String], row: &[Value]) -> Result<Value>; // JSON row; booleans and lists decoded
pub fn merge_identity(identity: &Value, state: &Value) -> Value;      // identity fields ∪ state fields
impl Engine {
    pub fn row_get(&mut self, table: &str, model: &ModelDescriptor, identity: &Value) -> Result<Option<Value>>;
    pub fn row_insert(&mut self, table: &str, model: &ModelDescriptor, row: &Value) -> Result<()>;   // fails if the key exists
    pub fn row_upsert(&mut self, table: &str, model: &ModelDescriptor, row: &Value) -> Result<()>;
    pub fn row_delete(&mut self, table: &str, model: &ModelDescriptor, identity: &Value) -> Result<()>;
    pub fn rows_where(&mut self, table: &str, model: &ModelDescriptor, filter: &[(String, Value)]) -> Result<Vec<Value>>;
    pub fn identities_where(&mut self, table: &str, model: &ModelDescriptor, filter: &[(String, Value)]) -> Result<Vec<Value>>;
    pub fn copy_aside(&mut self, model: &ModelDescriptor, identity: &Value) -> Result<()>;  // INSERT OR IGNORE INTO before SELECT ... FROM main
    pub fn count(&mut self, table: &str) -> Result<u64>;
}
```
- Produces (`ledger.rs`, `impl Engine`):

```rust
pub fn record_stamp(&mut self, key: &RecordKey) -> Result<u64>;        // 0 when absent
pub fn set_record_stamp(&mut self, key: &RecordKey, stamp: u64) -> Result<()>;
pub fn drop_record(&mut self, key: &RecordKey) -> Result<()>;
pub fn claim_add(&mut self, channel: &str, key: &RecordKey) -> Result<()>;
pub fn claim_remove(&mut self, channel: &str, key: &RecordKey) -> Result<()>;
pub fn claims(&mut self, key: &RecordKey) -> Result<Vec<String>>;
pub fn claims_remove_all(&mut self, key: &RecordKey) -> Result<()>;
pub fn claimed_by(&mut self, channel: &str) -> Result<Vec<RecordKey>>;
pub fn cursor(&mut self, channel: &str) -> Result<Option<u64>>;
pub fn set_cursor(&mut self, channel: &str, cursor: u64) -> Result<()>; // upsert
pub fn delete_subscription(&mut self, channel: &str) -> Result<()>;
pub fn subscriptions(&mut self) -> Result<Vec<(String, u64)>>;
```
- Produces (`queue.rs`):

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OpKind { Wire, Companion, Effect }
#[derive(Clone, Debug)]
pub struct QueuedOp { pub ordinal: u64, pub position: u64, pub kind: OpKind, pub op: Operation }
#[derive(Clone, Debug)]
pub struct Queued { pub ordinal: u64, pub push: Option<u64>, pub mutation: Mutation }
impl Engine {
    pub fn allocate_ordinal(&mut self) -> Result<u64>;
    pub fn allocate_push(&mut self) -> Result<u64>;
    pub fn insert_mutation(&mut self, ordinal: u64, mutation: &Mutation) -> Result<()>;  // all child rows, push NULL
    pub fn add_effect(&mut self, ordinal: u64, op: &Operation) -> Result<()>;
    pub fn queued(&mut self) -> Result<Vec<Queued>>;                     // ordinal order
    pub fn queued_one(&mut self, ordinal: u64) -> Result<Option<Queued>>;
    pub fn ops_for(&mut self, key: &RecordKey) -> Result<Vec<QueuedOp>>; // (ordinal, position) order
    pub fn dirty(&mut self, key: &RecordKey) -> Result<bool>;
    pub fn delete_mutations(&mut self, ordinals: &[u64]) -> Result<()>;
    pub fn assign_push(&mut self, ordinals: &[u64], push: u64) -> Result<()>;
    pub fn pushes(&mut self) -> Result<Vec<u64>>;                        // distinct ascending, mutations ∪ checkpoints
    pub fn prerequisite_keys(&mut self) -> Result<Vec<(String, Option<String>)>>;
    pub fn resolve_prerequisite(&mut self, key: &str) -> Result<usize>;  // delete rows
    pub fn fail_prerequisite(&mut self, key: &str, error: &str) -> Result<usize>;
    pub fn reset_prerequisite(&mut self, key: &str) -> Result<usize>;    // error = NULL
    pub fn checkpoints(&mut self, push: u64) -> Result<Vec<ChannelCheckpoint>>;
    pub fn insert_checkpoints(&mut self, push: u64, checkpoints: &[ChannelCheckpoint]) -> Result<()>;
    pub fn delete_checkpoints(&mut self, push: u64) -> Result<()>;
    pub fn checkpoint_channels(&mut self) -> Result<BTreeSet<String>>;
    pub fn insert_rejection(&mut self, ordinal: u64, name: &str, code: &str, detail: &Value) -> Result<()>;
    pub fn rejections(&mut self) -> Result<Vec<Rejection>>;
    pub fn rejection_details(&mut self) -> Result<Vec<Value>>;
    pub fn delete_rejection(&mut self, ordinal: u64) -> Result<()>;
}
```

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/engine.rs`:

```rust
use otter_client::ddl::{FRAMEWORK_DDL, reconcile};
use otter_client::engine::Engine;
use otter_client::queue::OpKind;
use otter_client::rows::{decode_row, merge_identity};
use otter_client::{ClientStore, Mutation, Operation, OperationKind};
use otter_core::{ChannelCheckpoint, RecordKey, Schema};
use otter_sqlite::SqliteStore;
use serde_json::{Value, json};
use std::collections::BTreeSet;

fn schema() -> Schema {
    Schema::from_value(json!({"enums":[],"models":[{"name":"Task","identity":["id"],"fields":[
        {"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},
        {"name":"title","nullable":false,"type":{"kind":"scalar","name":"string"}},
        {"name":"done","nullable":false,"type":{"kind":"scalar","name":"boolean"}},
        {"name":"tags","nullable":true,"type":{"kind":"list","element":{"kind":"scalar","name":"string"}}}]}]})).unwrap()
}
fn store() -> (tempfile::TempDir, SqliteStore) {
    let dir = tempfile::tempdir().unwrap();
    let mut s = SqliteStore::open(dir.path().join("db")).unwrap();
    s.execute_batch(FRAMEWORK_DDL).unwrap();
    s.execute("INSERT INTO otter_client VALUES ('c', 1, 1, 1)", &[]).unwrap();
    s.begin().unwrap();
    reconcile(&mut s, &schema()).unwrap();
    s.commit().unwrap();
    (dir, s)
}
fn key(id: &str) -> RecordKey {
    schema().record_key("Task", &json!({"id":id})).unwrap()
}
fn row(id: &str, title: &str) -> Value {
    json!({"id":id,"title":title,"done":false,"tags":["a","b"]})
}

#[test]
fn model_rows_round_trip_booleans_lists_and_copy_aside() {
    let (_d, mut s) = store();
    let schema = schema();
    let model = schema.model("Task").unwrap();
    let mut changed = BTreeSet::new();
    s.begin().unwrap();
    let mut e = Engine::new(&mut s, &schema, &mut changed, false);
    e.row_insert("Task", model, &row("t1", "A")).unwrap();
    assert!(e.row_insert("Task", model, &row("t1", "A")).is_err());
    e.row_upsert("Task", model, &row("t1", "B")).unwrap();
    assert_eq!(e.row_get("Task", model, &json!({"id":"t1"})).unwrap(), Some(row("t1", "B")));
    e.copy_aside(model, &json!({"id":"t1"})).unwrap();
    e.copy_aside(model, &json!({"id":"missing"})).unwrap();
    assert_eq!(e.row_get("otter_before_Task", model, &json!({"id":"t1"})).unwrap(), Some(row("t1", "B")));
    assert_eq!(e.count("otter_before_Task").unwrap(), 1);
    assert_eq!(e.identities_where("Task", model, &[("done".into(), json!(false))]).unwrap(), vec![json!({"id":"t1"})]);
    assert!(e.identities_where("Task", model, &[("title".into(), json!("nope"))]).unwrap().is_empty());
    e.row_delete("Task", model, &json!({"id":"t1"})).unwrap();
    assert_eq!(e.row_get("Task", model, &json!({"id":"t1"})).unwrap(), None);
    assert_eq!(changed, BTreeSet::from(["Task".to_string(), "otter_before_Task".to_string()]));
    s.rollback().unwrap();
    assert_eq!(decode_row(model, &["done".into(), "tags".into()], &[json!(1), json!("[\"x\"]")]).unwrap(), json!({"done":true,"tags":["x"]}));
    assert_eq!(merge_identity(&json!({"id":"t1"}), &json!({"title":"T"})), json!({"id":"t1","title":"T"}));
}

#[test]
fn ledger_tracks_stamps_claims_and_subscriptions() {
    let (_d, mut s) = store();
    let schema = schema();
    let mut changed = BTreeSet::new();
    s.begin().unwrap();
    let mut e = Engine::new(&mut s, &schema, &mut changed, false);
    assert_eq!(e.record_stamp(&key("t1")).unwrap(), 0);
    e.set_record_stamp(&key("t1"), 7).unwrap();
    e.set_record_stamp(&key("t1"), 9).unwrap();
    assert_eq!(e.record_stamp(&key("t1")).unwrap(), 9);
    e.claim_add("a", &key("t1")).unwrap();
    e.claim_add("a", &key("t1")).unwrap();
    e.claim_add("b", &key("t1")).unwrap();
    assert_eq!(e.claims(&key("t1")).unwrap(), vec!["a", "b"]);
    assert_eq!(e.claimed_by("b").unwrap(), vec![key("t1")]);
    e.claim_remove("a", &key("t1")).unwrap();
    assert_eq!(e.claims(&key("t1")).unwrap(), vec!["b"]);
    e.claims_remove_all(&key("t1")).unwrap();
    assert!(e.claims(&key("t1")).unwrap().is_empty());
    e.drop_record(&key("t1")).unwrap();
    assert_eq!(e.record_stamp(&key("t1")).unwrap(), 0);
    assert_eq!(e.cursor("x").unwrap(), None);
    e.set_cursor("x", 0).unwrap();
    e.set_cursor("x", 4).unwrap();
    e.set_cursor("y", 2).unwrap();
    assert_eq!(e.subscriptions().unwrap(), vec![("x".to_string(), 4), ("y".to_string(), 2)]);
    e.delete_subscription("x").unwrap();
    assert_eq!(e.cursor("x").unwrap(), None);
    s.rollback().unwrap();
}

#[test]
fn queue_rows_reconstruct_mutations_and_cascade_on_delete() {
    let (_d, mut s) = store();
    let schema = schema();
    let mut changed = BTreeSet::new();
    s.begin().unwrap();
    let mut e = Engine::new(&mut s, &schema, &mut changed, false);
    let first = e.allocate_ordinal().unwrap();
    assert_eq!(first, 1);
    e.insert_mutation(first, &Mutation::new("First", vec![Operation { model: "Task".into(), op: OperationKind::Create, identity: json!({"id":"t3"}), values: Some(row("t3", "C")) }])).unwrap();
    let mut m = Mutation::new("Edit", vec![Operation { model: "Task".into(), op: OperationKind::Update, identity: json!({"id":"t1"}), values: Some(json!({"title":"B"})) }]);
    m.companion.push(Operation { model: "Task".into(), op: OperationKind::Delete, identity: json!({"id":"t2"}), values: None });
    m.prerequisites.push("upload:1".into());
    m.lifecycle_dependencies.push(first);
    let ordinal = e.allocate_ordinal().unwrap();
    assert_eq!(ordinal, 2);
    e.insert_mutation(ordinal, &m).unwrap();
    e.add_effect(ordinal, &Operation { model: "Task".into(), op: OperationKind::Delete, identity: json!({"id":"t9"}), values: None }).unwrap();
    let queued = e.queued().unwrap();
    assert_eq!(queued.len(), 2);
    let q = &queued[1];
    assert_eq!((q.ordinal, q.push, q.mutation.name.as_str()), (2, None, "Edit"));
    assert_eq!(q.mutation.operations.len(), 1);
    assert_eq!(q.mutation.companion.len(), 1);
    assert_eq!(q.mutation.effects[0].identity, json!({"id":"t9"}));
    assert_eq!(q.mutation.prerequisites, vec!["upload:1"]);
    assert_eq!(q.mutation.lifecycle_dependencies, vec![1]);
    let ops = e.ops_for(&key("t2")).unwrap();
    assert_eq!((ops[0].ordinal, ops[0].kind), (2, OpKind::Companion));
    assert!(e.dirty(&key("t9")).unwrap());
    assert!(!e.dirty(&key("t8")).unwrap());
    assert_eq!(e.prerequisite_keys().unwrap(), vec![("upload:1".to_string(), None)]);
    e.fail_prerequisite("upload:1", "timeout").unwrap();
    assert_eq!(e.prerequisite_keys().unwrap(), vec![("upload:1".to_string(), Some("timeout".to_string()))]);
    e.reset_prerequisite("upload:1").unwrap();
    assert_eq!(e.resolve_prerequisite("upload:1").unwrap(), 1);
    assert!(e.prerequisite_keys().unwrap().is_empty());
    let push = e.allocate_push().unwrap();
    assert_eq!(push, 1);
    e.assign_push(&[1, 2], push).unwrap();
    assert_eq!(e.queued_one(2).unwrap().unwrap().push, Some(1));
    e.insert_checkpoints(push, &[ChannelCheckpoint { channel: "a".into(), cursor: 5 }]).unwrap();
    assert_eq!(e.checkpoints(push).unwrap(), vec![ChannelCheckpoint { channel: "a".into(), cursor: 5 }]);
    assert_eq!(e.checkpoint_channels().unwrap(), BTreeSet::from(["a".to_string()]));
    assert_eq!(e.pushes().unwrap(), vec![1]);
    e.insert_rejection(2, "Edit", "denied", &json!({"records":[]})).unwrap();
    assert_eq!(e.rejections().unwrap()[0].code, "denied");
    assert_eq!(e.rejection_details().unwrap()[0]["records"], json!([]));
    e.delete_mutations(&[2]).unwrap();
    assert!(e.ops_for(&key("t2")).unwrap().is_empty(), "operations cascade with the mutation");
    assert!(e.queued_one(2).unwrap().is_none());
    e.delete_checkpoints(push).unwrap();
    e.delete_rejection(2).unwrap();
    assert!(e.rejections().unwrap().is_empty());
    s.rollback().unwrap();
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test engine`
Expected: FAIL to compile.

- [ ] **Step 3: Write `engine.rs`**

```rust
//! One handle per open transaction. Every module adds methods to it.
use crate::store::{ClientStore, SqlRows};
use otter_core::{Result, Schema, invalid};
use serde_json::Value;
use std::collections::BTreeSet;

pub struct Engine<'a, S: ClientStore> {
    pub store: &'a mut S,
    pub schema: &'a Schema,
    pub changed: &'a mut BTreeSet<String>,
    pub committed: bool,
}

impl<'a, S: ClientStore> Engine<'a, S> {
    pub fn new(store: &'a mut S, schema: &'a Schema, changed: &'a mut BTreeSet<String>, committed: bool) -> Self {
        Self { store, schema, changed, committed }
    }
    pub fn rows(&mut self, sql: &str, parameters: &[Value]) -> Result<SqlRows> {
        if self.committed {
            self.store.query_committed(sql, parameters)
        } else {
            self.store.query(sql, parameters)
        }
    }
    pub fn exec(&mut self, table: &str, sql: &str, parameters: &[Value]) -> Result<usize> {
        self.changed.insert(table.to_string());
        self.store.execute(sql, parameters)
    }
    pub fn scalar(&mut self, sql: &str, parameters: &[Value]) -> Result<Option<Value>> {
        Ok(self.rows(sql, parameters)?.rows.into_iter().next().and_then(|r| r.into_iter().next()))
    }
}

pub(crate) fn as_u64(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|v| u64::try_from(v).ok()))
        .ok_or_else(|| invalid("expected an unsigned integer"))
}
```

- [ ] **Step 4: Write `rows.rs`**

```rust
//! JSON ↔ SQL row codec and operations on a model's main and before tables.
use crate::ddl::{before_table, quote};
use crate::engine::{Engine, as_u64};
use crate::store::ClientStore;
use otter_core::{ModelDescriptor, Result, ScalarType, ValueType, invalid};
use serde_json::{Map, Value};

pub fn columns_sql(model: &ModelDescriptor) -> String {
    model.fields.iter().map(|f| quote(&f.name)).collect::<Vec<_>>().join(",")
}
pub fn identity_where(model: &ModelDescriptor) -> String {
    model.identity.iter().map(|f| format!("{}=?", quote(f))).collect::<Vec<_>>().join(" AND ")
}
pub fn identity_params(model: &ModelDescriptor, identity: &Value) -> Vec<Value> {
    model.identity.iter().map(|f| identity[f].clone()).collect()
}
fn row_params(model: &ModelDescriptor, row: &Value) -> Vec<Value> {
    model.fields.iter().map(|f| row.get(&f.name).cloned().unwrap_or(Value::Null)).collect()
}
fn decode_value(value_type: &ValueType, value: &Value) -> Result<Value> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    Ok(match value_type {
        ValueType::Scalar { name: ScalarType::Boolean } => Value::Bool(value.as_i64().unwrap_or(0) != 0),
        ValueType::List { .. } => serde_json::from_str(value.as_str().ok_or_else(|| invalid("list column must be text"))?)?,
        _ => value.clone(),
    })
}
pub fn decode_row(model: &ModelDescriptor, columns: &[String], row: &[Value]) -> Result<Value> {
    let mut object = Map::new();
    for (column, value) in columns.iter().zip(row) {
        let field = model
            .fields
            .iter()
            .find(|f| &f.name == column)
            .ok_or_else(|| invalid(format!("unknown column {column}")))?;
        object.insert(column.clone(), decode_value(&field.value_type, value)?);
    }
    Ok(Value::Object(object))
}
pub fn merge_identity(identity: &Value, state: &Value) -> Value {
    let mut object = identity.as_object().cloned().unwrap_or_default();
    for (k, v) in state.as_object().into_iter().flatten() {
        object.insert(k.clone(), v.clone());
    }
    Value::Object(object)
}
fn filter_sql(filter: &[(String, Value)]) -> (String, Vec<Value>) {
    if filter.is_empty() {
        return ("1".into(), vec![]);
    }
    let mut clauses = vec![];
    let mut params = vec![];
    for (field, value) in filter {
        if value.is_null() {
            clauses.push(format!("{} IS NULL", quote(field)));
        } else {
            clauses.push(format!("{}=?", quote(field)));
            params.push(value.clone());
        }
    }
    (clauses.join(" AND "), params)
}

impl<S: ClientStore> Engine<'_, S> {
    pub fn row_get(&mut self, table: &str, model: &ModelDescriptor, identity: &Value) -> Result<Option<Value>> {
        let sql = format!("SELECT {} FROM {} WHERE {}", columns_sql(model), quote(table), identity_where(model));
        let rows = self.rows(&sql, &identity_params(model, identity))?;
        rows.rows.first().map(|r| decode_row(model, &rows.columns, r)).transpose()
    }
    pub fn row_insert(&mut self, table: &str, model: &ModelDescriptor, row: &Value) -> Result<()> {
        let placeholders = vec!["?"; model.fields.len()].join(",");
        let sql = format!("INSERT INTO {} ({}) VALUES ({placeholders})", quote(table), columns_sql(model));
        self.exec(table, &sql, &row_params(model, row))?;
        Ok(())
    }
    pub fn row_upsert(&mut self, table: &str, model: &ModelDescriptor, row: &Value) -> Result<()> {
        let placeholders = vec!["?"; model.fields.len()].join(",");
        let key = model.identity.iter().map(|f| quote(f)).collect::<Vec<_>>().join(",");
        let updates = model
            .fields
            .iter()
            .filter(|f| !model.identity.contains(&f.name))
            .map(|f| format!("{0}=excluded.{0}", quote(&f.name)))
            .collect::<Vec<_>>();
        let action = if updates.is_empty() { "DO NOTHING".to_string() } else { format!("DO UPDATE SET {}", updates.join(",")) };
        let sql = format!("INSERT INTO {} ({}) VALUES ({placeholders}) ON CONFLICT({key}) {action}", quote(table), columns_sql(model));
        self.exec(table, &sql, &row_params(model, row))?;
        Ok(())
    }
    pub fn row_delete(&mut self, table: &str, model: &ModelDescriptor, identity: &Value) -> Result<()> {
        let sql = format!("DELETE FROM {} WHERE {}", quote(table), identity_where(model));
        self.exec(table, &sql, &identity_params(model, identity))?;
        Ok(())
    }
    pub fn rows_where(&mut self, table: &str, model: &ModelDescriptor, filter: &[(String, Value)]) -> Result<Vec<Value>> {
        let (clause, params) = filter_sql(filter);
        let sql = format!("SELECT {} FROM {} WHERE {clause}", columns_sql(model), quote(table));
        let rows = self.rows(&sql, &params)?;
        rows.rows.iter().map(|r| decode_row(model, &rows.columns, r)).collect()
    }
    pub fn identities_where(&mut self, table: &str, model: &ModelDescriptor, filter: &[(String, Value)]) -> Result<Vec<Value>> {
        Ok(self
            .rows_where(table, model, filter)?
            .into_iter()
            .map(|row| Value::Object(model.identity.iter().map(|f| (f.clone(), row[f].clone())).collect()))
            .collect())
    }
    pub fn copy_aside(&mut self, model: &ModelDescriptor, identity: &Value) -> Result<()> {
        let before = before_table(&model.name);
        let sql = format!(
            "INSERT OR IGNORE INTO {} ({cols}) SELECT {cols} FROM {} WHERE {}",
            quote(&before),
            quote(&model.name),
            identity_where(model),
            cols = columns_sql(model)
        );
        self.exec(&before, &sql, &identity_params(model, identity))?;
        Ok(())
    }
    pub fn count(&mut self, table: &str) -> Result<u64> {
        let value = self.scalar(&format!("SELECT COUNT(*) FROM {}", quote(table)), &[])?;
        as_u64(&value.unwrap_or(Value::from(0)))
    }
}
```

- [ ] **Step 5: Write `ledger.rs`**

```rust
//! Per-record stamp, channel claims and subscriptions.
use crate::engine::{Engine, as_u64};
use crate::store::ClientStore;
use otter_core::{RecordKey, Result};
use serde_json::{Value, json};

impl<S: ClientStore> Engine<'_, S> {
    pub fn record_stamp(&mut self, key: &RecordKey) -> Result<u64> {
        match self.scalar("SELECT stamp FROM otter_record WHERE model=? AND identity=?", &[json!(key.model), json!(key.encoded_identity()?)])? {
            Some(v) => as_u64(&v),
            None => Ok(0),
        }
    }
    pub fn set_record_stamp(&mut self, key: &RecordKey, stamp: u64) -> Result<()> {
        self.exec("otter_record", "INSERT INTO otter_record (model, identity, stamp) VALUES (?,?,?) ON CONFLICT(model, identity) DO UPDATE SET stamp=excluded.stamp", &[json!(key.model), json!(key.encoded_identity()?), json!(stamp)])?;
        Ok(())
    }
    pub fn drop_record(&mut self, key: &RecordKey) -> Result<()> {
        self.exec("otter_record", "DELETE FROM otter_record WHERE model=? AND identity=?", &[json!(key.model), json!(key.encoded_identity()?)])?;
        Ok(())
    }
    pub fn claim_add(&mut self, channel: &str, key: &RecordKey) -> Result<()> {
        self.exec("otter_claim", "INSERT OR IGNORE INTO otter_claim (channel, model, identity) VALUES (?,?,?)", &[json!(channel), json!(key.model), json!(key.encoded_identity()?)])?;
        Ok(())
    }
    pub fn claim_remove(&mut self, channel: &str, key: &RecordKey) -> Result<()> {
        self.exec("otter_claim", "DELETE FROM otter_claim WHERE channel=? AND model=? AND identity=?", &[json!(channel), json!(key.model), json!(key.encoded_identity()?)])?;
        Ok(())
    }
    pub fn claims(&mut self, key: &RecordKey) -> Result<Vec<String>> {
        let rows = self.rows("SELECT channel FROM otter_claim WHERE model=? AND identity=? ORDER BY channel", &[json!(key.model), json!(key.encoded_identity()?)])?;
        Ok(rows.rows.into_iter().filter_map(|r| r[0].as_str().map(str::to_owned)).collect())
    }
    pub fn claims_remove_all(&mut self, key: &RecordKey) -> Result<()> {
        self.exec("otter_claim", "DELETE FROM otter_claim WHERE model=? AND identity=?", &[json!(key.model), json!(key.encoded_identity()?)])?;
        Ok(())
    }
    pub fn claimed_by(&mut self, channel: &str) -> Result<Vec<RecordKey>> {
        let rows = self.rows("SELECT model, identity FROM otter_claim WHERE channel=? ORDER BY model, identity", &[json!(channel)])?;
        rows.rows
            .into_iter()
            .map(|r| {
                let identity: Value = serde_json::from_str(r[1].as_str().unwrap_or("null"))?;
                self.schema.record_key(r[0].as_str().unwrap_or(""), &identity)
            })
            .collect()
    }
    pub fn cursor(&mut self, channel: &str) -> Result<Option<u64>> {
        self.scalar("SELECT cursor FROM otter_subscription WHERE channel=?", &[json!(channel)])?.map(|v| as_u64(&v)).transpose()
    }
    pub fn set_cursor(&mut self, channel: &str, cursor: u64) -> Result<()> {
        self.exec("otter_subscription", "INSERT INTO otter_subscription (channel, cursor) VALUES (?,?) ON CONFLICT(channel) DO UPDATE SET cursor=excluded.cursor", &[json!(channel), json!(cursor)])?;
        Ok(())
    }
    pub fn delete_subscription(&mut self, channel: &str) -> Result<()> {
        self.exec("otter_subscription", "DELETE FROM otter_subscription WHERE channel=?", &[json!(channel)])?;
        Ok(())
    }
    pub fn subscriptions(&mut self) -> Result<Vec<(String, u64)>> {
        let rows = self.rows("SELECT channel, cursor FROM otter_subscription ORDER BY channel", &[])?;
        rows.rows.into_iter().map(|r| Ok((r[0].as_str().unwrap_or("").to_string(), as_u64(&r[1])?))).collect()
    }
}
```

- [ ] **Step 6: Write `queue.rs`**

```rust
//! Pending mutations, their operations, dependencies, prerequisites, push checkpoints and rejections.
use crate::engine::{Engine, as_u64};
use crate::store::ClientStore;
use crate::{Mutation, Operation, OperationKind};
use otter_core::{ChannelCheckpoint, RecordKey, Rejection, Result, invalid};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OpKind {
    Wire,
    Companion,
    Effect,
}
#[derive(Clone, Debug)]
pub struct QueuedOp {
    pub ordinal: u64,
    pub position: u64,
    pub kind: OpKind,
    pub op: Operation,
}
#[derive(Clone, Debug)]
pub struct Queued {
    pub ordinal: u64,
    pub push: Option<u64>,
    pub mutation: Mutation,
}

fn text(value: &Value) -> String {
    value.as_str().unwrap_or("").to_string()
}
fn op_text(op: OperationKind) -> &'static str {
    match op {
        OperationKind::Create => "create",
        OperationKind::Update => "update",
        OperationKind::Delete => "delete",
    }
}
fn kind_text(kind: OpKind) -> &'static str {
    match kind {
        OpKind::Wire => "wire",
        OpKind::Companion => "companion",
        OpKind::Effect => "effect",
    }
}
fn decode_op(row: &[Value]) -> Result<QueuedOp> {
    // columns: ordinal, position, kind, model, identity, op, values
    let kind = match row[2].as_str() {
        Some("wire") => OpKind::Wire,
        Some("companion") => OpKind::Companion,
        Some("effect") => OpKind::Effect,
        _ => return Err(invalid("unknown operation kind")),
    };
    let op = match row[5].as_str() {
        Some("create") => OperationKind::Create,
        Some("update") => OperationKind::Update,
        Some("delete") => OperationKind::Delete,
        _ => return Err(invalid("unknown operation")),
    };
    Ok(QueuedOp {
        ordinal: as_u64(&row[0])?,
        position: as_u64(&row[1])?,
        kind,
        op: Operation {
            model: text(&row[3]),
            op,
            identity: serde_json::from_str(row[4].as_str().unwrap_or("null"))?,
            values: row[6].as_str().map(serde_json::from_str).transpose()?,
        },
    })
}

impl<S: ClientStore> Engine<'_, S> {
    fn bump(&mut self, column: &str) -> Result<u64> {
        let current = self.scalar(&format!("SELECT {column} FROM otter_client"), &[])?.ok_or_else(|| invalid("client row missing"))?;
        let value = as_u64(&current)?;
        let next = value.checked_add(1).filter(|v| *v <= otter_core::MAX_SAFE_INTEGER).ok_or_else(|| invalid("counter exhausted"))?;
        self.exec("otter_client", &format!("UPDATE otter_client SET {column}=?"), &[json!(next)])?;
        Ok(value)
    }
    pub fn allocate_ordinal(&mut self) -> Result<u64> {
        self.bump("next_ordinal")
    }
    pub fn allocate_push(&mut self) -> Result<u64> {
        self.bump("next_push")
    }
    fn insert_op(&mut self, ordinal: u64, position: u64, kind: OpKind, op: &Operation) -> Result<()> {
        let key = self.schema.record_key(&op.model, &op.identity)?;
        self.exec(
            "otter_mutation_operation",
            "INSERT INTO otter_mutation_operation (ordinal, position, kind, model, identity, op, \"values\") VALUES (?,?,?,?,?,?,?)",
            &[
                json!(ordinal),
                json!(position),
                json!(kind_text(kind)),
                json!(op.model),
                json!(key.encoded_identity()?),
                json!(op_text(op.op)),
                match &op.values {
                    Some(v) => json!(serde_json::to_string(v)?),
                    None => Value::Null,
                },
            ],
        )?;
        Ok(())
    }
    pub fn insert_mutation(&mut self, ordinal: u64, mutation: &Mutation) -> Result<()> {
        self.exec("otter_mutation", "INSERT INTO otter_mutation (ordinal, name, version, push) VALUES (?,?,?,NULL)", &[json!(ordinal), json!(mutation.name), json!(mutation.version)])?;
        let mut position = 0;
        for (kind, ops) in [(OpKind::Wire, &mutation.operations), (OpKind::Companion, &mutation.companion), (OpKind::Effect, &mutation.effects)] {
            for op in ops {
                self.insert_op(ordinal, position, kind, op)?;
                position += 1;
            }
        }
        for (kind, deps) in [("lifecycle", &mutation.lifecycle_dependencies), ("sequence", &mutation.sequence_dependencies)] {
            for dep in deps {
                self.exec("otter_mutation_dependency", "INSERT OR IGNORE INTO otter_mutation_dependency (ordinal, depends_on, kind) VALUES (?,?,?)", &[json!(ordinal), json!(dep), json!(kind)])?;
            }
        }
        for key in &mutation.prerequisites {
            self.exec("otter_mutation_prerequisite", "INSERT OR IGNORE INTO otter_mutation_prerequisite (ordinal, key, error) VALUES (?,?,NULL)", &[json!(ordinal), json!(key)])?;
        }
        Ok(())
    }
    pub fn add_effect(&mut self, ordinal: u64, op: &Operation) -> Result<()> {
        let next = self.scalar("SELECT COALESCE(MAX(position), -1) + 1 FROM otter_mutation_operation WHERE ordinal=?", &[json!(ordinal)])?;
        let position = as_u64(&next.unwrap_or(json!(0)))?;
        self.insert_op(ordinal, position, OpKind::Effect, op)
    }
    fn ops_by_ordinal(&mut self, filter: &str, params: &[Value]) -> Result<BTreeMap<u64, Vec<QueuedOp>>> {
        let rows = self.rows(&format!("SELECT ordinal, position, kind, model, identity, op, \"values\" FROM otter_mutation_operation {filter} ORDER BY ordinal, position"), params)?;
        let mut result: BTreeMap<u64, Vec<QueuedOp>> = BTreeMap::new();
        for row in &rows.rows {
            let op = decode_op(row)?;
            result.entry(op.ordinal).or_default().push(op);
        }
        Ok(result)
    }
    fn queued_where(&mut self, filter: &str, params: &[Value]) -> Result<Vec<Queued>> {
        let mutations = self.rows(&format!("SELECT ordinal, name, version, push FROM otter_mutation {filter} ORDER BY ordinal"), params)?;
        if mutations.rows.is_empty() {
            return Ok(vec![]);
        }
        let ops = self.ops_by_ordinal("", &[])?;
        let deps = self.rows("SELECT ordinal, depends_on, kind FROM otter_mutation_dependency ORDER BY ordinal, depends_on", &[])?;
        let prerequisites = self.rows("SELECT ordinal, key FROM otter_mutation_prerequisite ORDER BY ordinal, key", &[])?;
        let mut result = vec![];
        for row in &mutations.rows {
            let ordinal = as_u64(&row[0])?;
            let mut mutation = Mutation::new(text(&row[1]), vec![]);
            mutation.version = as_u64(&row[2])?;
            for op in ops.get(&ordinal).into_iter().flatten() {
                match op.kind {
                    OpKind::Wire => mutation.operations.push(op.op.clone()),
                    OpKind::Companion => mutation.companion.push(op.op.clone()),
                    OpKind::Effect => mutation.effects.push(op.op.clone()),
                }
            }
            for dep in deps.rows.iter().filter(|d| as_u64(&d[0]).ok() == Some(ordinal)) {
                let target = as_u64(&dep[1])?;
                if dep[2] == "lifecycle" {
                    mutation.lifecycle_dependencies.push(target);
                } else {
                    mutation.sequence_dependencies.push(target);
                }
            }
            for p in prerequisites.rows.iter().filter(|p| as_u64(&p[0]).ok() == Some(ordinal)) {
                mutation.prerequisites.push(text(&p[1]));
            }
            result.push(Queued { ordinal, push: row[3].as_u64(), mutation });
        }
        Ok(result)
    }
    pub fn queued(&mut self) -> Result<Vec<Queued>> {
        self.queued_where("", &[])
    }
    pub fn queued_one(&mut self, ordinal: u64) -> Result<Option<Queued>> {
        Ok(self.queued_where("WHERE ordinal=?", &[json!(ordinal)])?.into_iter().next())
    }
    pub fn ops_for(&mut self, key: &RecordKey) -> Result<Vec<QueuedOp>> {
        Ok(self
            .ops_by_ordinal("WHERE model=? AND identity=?", &[json!(key.model), json!(key.encoded_identity()?)])?
            .into_values()
            .flatten()
            .collect())
    }
    pub fn dirty(&mut self, key: &RecordKey) -> Result<bool> {
        Ok(self.scalar("SELECT 1 FROM otter_mutation_operation WHERE model=? AND identity=? LIMIT 1", &[json!(key.model), json!(key.encoded_identity()?)])?.is_some())
    }
    pub fn delete_mutations(&mut self, ordinals: &[u64]) -> Result<()> {
        for ordinal in ordinals {
            self.exec("otter_mutation", "DELETE FROM otter_mutation WHERE ordinal=?", &[json!(ordinal)])?;
        }
        for table in ["otter_mutation_operation", "otter_mutation_dependency", "otter_mutation_prerequisite"] {
            self.changed.insert(table.into());
        }
        Ok(())
    }
    pub fn assign_push(&mut self, ordinals: &[u64], push: u64) -> Result<()> {
        for ordinal in ordinals {
            self.exec("otter_mutation", "UPDATE otter_mutation SET push=? WHERE ordinal=?", &[json!(push), json!(ordinal)])?;
        }
        Ok(())
    }
    pub fn pushes(&mut self) -> Result<Vec<u64>> {
        let rows = self.rows("SELECT push FROM otter_mutation WHERE push IS NOT NULL UNION SELECT push FROM otter_push_checkpoint ORDER BY 1", &[])?;
        rows.rows.iter().map(|r| as_u64(&r[0])).collect()
    }
    pub fn prerequisite_keys(&mut self) -> Result<Vec<(String, Option<String>)>> {
        let rows = self.rows("SELECT key, MAX(error) FROM otter_mutation_prerequisite GROUP BY key ORDER BY key", &[])?;
        Ok(rows.rows.into_iter().map(|r| (text(&r[0]), r[1].as_str().map(str::to_owned))).collect())
    }
    pub fn resolve_prerequisite(&mut self, key: &str) -> Result<usize> {
        self.exec("otter_mutation_prerequisite", "DELETE FROM otter_mutation_prerequisite WHERE key=?", &[json!(key)])
    }
    pub fn fail_prerequisite(&mut self, key: &str, error: &str) -> Result<usize> {
        self.exec("otter_mutation_prerequisite", "UPDATE otter_mutation_prerequisite SET error=? WHERE key=?", &[json!(error), json!(key)])
    }
    pub fn reset_prerequisite(&mut self, key: &str) -> Result<usize> {
        self.exec("otter_mutation_prerequisite", "UPDATE otter_mutation_prerequisite SET error=NULL WHERE key=?", &[json!(key)])
    }
    pub fn checkpoints(&mut self, push: u64) -> Result<Vec<ChannelCheckpoint>> {
        let rows = self.rows("SELECT channel, cursor FROM otter_push_checkpoint WHERE push=? ORDER BY channel", &[json!(push)])?;
        rows.rows.iter().map(|r| Ok(ChannelCheckpoint { channel: text(&r[0]), cursor: as_u64(&r[1])? })).collect()
    }
    pub fn insert_checkpoints(&mut self, push: u64, checkpoints: &[ChannelCheckpoint]) -> Result<()> {
        for cp in checkpoints {
            self.exec("otter_push_checkpoint", "INSERT INTO otter_push_checkpoint (push, channel, cursor) VALUES (?,?,?)", &[json!(push), json!(cp.channel), json!(cp.cursor)])?;
        }
        Ok(())
    }
    pub fn delete_checkpoints(&mut self, push: u64) -> Result<()> {
        self.exec("otter_push_checkpoint", "DELETE FROM otter_push_checkpoint WHERE push=?", &[json!(push)])?;
        Ok(())
    }
    pub fn checkpoint_channels(&mut self) -> Result<BTreeSet<String>> {
        let rows = self.rows("SELECT DISTINCT channel FROM otter_push_checkpoint", &[])?;
        Ok(rows.rows.iter().map(|r| text(&r[0])).collect())
    }
    pub fn insert_rejection(&mut self, ordinal: u64, name: &str, code: &str, detail: &Value) -> Result<()> {
        self.exec("otter_rejection", "INSERT OR REPLACE INTO otter_rejection (ordinal, name, code, detail) VALUES (?,?,?,?)", &[json!(ordinal), json!(name), json!(code), json!(serde_json::to_string(detail)?)])?;
        Ok(())
    }
    pub fn rejections(&mut self) -> Result<Vec<Rejection>> {
        let rows = self.rows("SELECT ordinal, code FROM otter_rejection ORDER BY ordinal", &[])?;
        rows.rows.iter().map(|r| Ok(Rejection { ordinal: as_u64(&r[0])?, code: text(&r[1]) })).collect()
    }
    pub fn rejection_details(&mut self) -> Result<Vec<Value>> {
        let rows = self.rows("SELECT detail FROM otter_rejection ORDER BY ordinal", &[])?;
        rows.rows.iter().map(|r| Ok(serde_json::from_str(r[0].as_str().unwrap_or("null"))?)).collect()
    }
    pub fn delete_rejection(&mut self, ordinal: u64) -> Result<()> {
        self.exec("otter_rejection", "DELETE FROM otter_rejection WHERE ordinal=?", &[json!(ordinal)])?;
        Ok(())
    }
}
```

- [ ] **Step 7: Run the engine tests**

Run: `cargo test -p otter-sqlite --locked --test engine`
Expected: PASS.

- [ ] **Step 8: Commit**

Stage `crates/client/src` and `crates/sqlite/tests/engine.rs`; commit as `feat(client): engine handle with row, ledger and queue access`.

---

### Task 6: Client, transactions, sessions, watch, and the mutate engine

**Files:**
- Rewrite: `crates/client/src/lib.rs`
- Create: `crates/client/src/mutate.rs`
- Rewrite: `crates/client/src/policies.rs`
- Delete: `crates/client/src/cascade.rs`, `crates/client/src/migration.rs`
- Modify: `crates/client/src/transport.rs` (only the two lines that read `snapshot().batches`; replace with `client.checkpoint_channels()?` and `client.desired_channels()?` — full rewrite of that function in Task 9)
- Modify: `crates/client/src/query.rs` (temporarily make `evaluate`, `related`, `referencing` return `Err(invalid("rewritten in Task 9"))` so the crate compiles; Task 9 rewrites the file)
- Test: `crates/sqlite/tests/client.rs` (new file, replaces the deleted one)

**Interfaces:**
- Produces (`lib.rs`):

```rust
pub use otter_core::*;
pub use store::*; pub use query::{QuerySpec, QueryOrder, Direction}; pub use connection::*; pub use transport::*;
pub struct Operation { pub model: String, pub op: OperationKind, pub identity: Value, pub values: Option<Value> }  // unchanged
pub struct Mutation { name, version, operations, companion, effects, prerequisites, lifecycle_dependencies, sequence_dependencies }  // subscribe/unsubscribe removed
pub enum Readiness { Pending, Ready, Failed }  // unchanged
pub struct ApplyReport { pub applied: usize, pub skipped: usize, pub stale: bool, pub conflicts: usize, pub diagnostics: Vec<Value> }
pub struct Client<S: ClientStore> { /* store, schema, client_id, generation, watchers, session, last_changed */ }
impl<S: ClientStore> Client<S> {
    pub fn open(store: S, schema: Schema) -> Result<Self>;
    pub fn client_id(&self) -> &str;
    pub fn generation(&self) -> u64;
    pub fn last_changed(&self) -> &BTreeSet<String>;
    pub fn watch(&mut self, tables: BTreeSet<String>) -> Receiver<()>;
    pub fn transaction<T>(&mut self, body: impl FnOnce(&mut ClientTransaction<'_, S>) -> Result<T>) -> Result<T>;
    pub fn begin_session(&mut self) -> Result<()>;
    pub fn session<T>(&mut self, body: impl FnOnce(&mut ClientTransaction<'_, S>) -> Result<T>) -> Result<T>;
    pub fn commit_session(&mut self) -> Result<()>;
    pub fn rollback_session(&mut self) -> Result<()>;
    pub fn session_savepoint(&mut self) -> Result<()>;
    pub fn session_release(&mut self) -> Result<()>;
    pub fn session_rollback_savepoint(&mut self) -> Result<()>;
    pub fn session_active(&self) -> bool;
    pub fn read(&mut self, key: &RecordKey) -> Result<Option<Value>>;          // committed view
    pub fn pending_count(&mut self) -> Result<usize>;
    pub fn before_image_count(&mut self) -> Result<usize>;
    pub fn cursor(&mut self, channel: &str) -> Result<u64>;                    // 0 when not subscribed
    pub fn subscriptions(&mut self) -> Result<Vec<(String, u64)>>;
    pub fn desired_channels(&mut self) -> Result<BTreeSet<String>>;
    pub fn checkpoint_channels(&mut self) -> Result<BTreeSet<String>>;
    pub(crate) fn write<T>(&mut self, body: impl FnOnce(&mut Engine<'_, S>) -> Result<T>) -> Result<T>;  // one write transaction with the generation fence
    pub(crate) fn view<T>(&mut self, body: impl FnOnce(&mut Engine<'_, S>) -> Result<T>) -> Result<T>;   // reader connection, no transaction
}
pub struct ClientTransaction<'a, S: ClientStore> { pub(crate) engine: Engine<'a, S>, depth: u64 }
impl ClientTransaction {
    pub fn read(&mut self, key: &RecordKey) -> Result<Option<Value>>;
    pub fn savepoint<T>(&mut self, body: impl FnOnce(&mut Self) -> Result<T>) -> Result<T>;
    pub fn set_channel(&mut self, channel: String, subscribed: bool) -> Result<()>;   // insert cursor 0 / unsubscribe cleanup
    pub fn enqueue(&mut self, mutation: Mutation) -> Result<u64>;
    pub fn direct(&mut self, operation: Operation) -> Result<()>;
}
```
- Produces (`mutate.rs`, `impl Engine`):

```rust
pub fn apply_to_row(row: &mut Option<Value>, op: &Operation) -> Result<()>;    // pure: create/update/delete on one JSON row
impl Engine {
    pub fn read_row(&mut self, key: &RecordKey) -> Result<Option<Value>>;       // main table
    pub fn truth(&mut self, key: &RecordKey) -> Result<Option<Value>>;          // before row if dirty, else main row
    pub fn apply_main(&mut self, op: &Operation) -> Result<()>;                 // write op to the main table
    pub fn hold_truth(&mut self, key: &RecordKey) -> Result<()>;               // copy_aside unless already dirty
    pub fn rebuild(&mut self, key: &RecordKey) -> Result<()>;
    pub fn descendants(&mut self, parent: &RecordKey) -> Result<Vec<RecordKey>>;
    pub fn refresh_pending(&mut self) -> Result<()>;
    pub fn set_authority(&mut self, key: &RecordKey, value: Option<Value>) -> Result<()>;   // value = full row
    pub fn enqueue(&mut self, mutation: Mutation) -> Result<u64>;
    pub fn direct(&mut self, operation: Operation) -> Result<()>;
    pub fn unsubscribe(&mut self, channel: &str) -> Result<()>;
}
```

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/client.rs` with the helpers every later test file copies:

```rust
use otter_client::*;
use otter_core::*;
use otter_sqlite::SqliteStore;
use serde_json::{Value, json};
use std::collections::BTreeSet;

pub fn schema() -> Schema {
    Schema::from_value(serde_json::from_str(include_str!("../../../fixtures/schemas/entry.json")).unwrap()).unwrap()
}
pub fn open(path: &std::path::Path) -> Client<SqliteStore> {
    Client::open(SqliteStore::open(path).unwrap(), schema()).unwrap()
}
pub fn key() -> RecordKey {
    schema().record_key("Entry", &json!({"id":"e"})).unwrap()
}
pub fn update(text: &str) -> Operation {
    Operation { model: "Entry".into(), op: OperationKind::Update, identity: json!({"id":"e"}), values: Some(json!({"text":text})) }
}
pub fn mutation(text: &str) -> Mutation {
    Mutation::new("Edit", vec![update(text)])
}
pub fn page(channel: &str, from: u64, to: u64, text: Option<&str>) -> PullPage {
    PullPage { channel: channel.into(), from_cursor: from, to_cursor: to, changes: vec![RecordChange {
        cursor: to, model: "Entry".into(), identity: json!({"id":"e"}), stamp: None,
        state: text.map(|t| json!({"text":t,"note":null})).unwrap_or(Value::Null) }] }
}
pub fn seed(c: &mut Client<SqliteStore>, text: &str) {
    c.transaction(|tx| tx.direct(Operation { model: "Entry".into(), op: OperationKind::Create, identity: json!({"id":"e"}), values: Some(json!({"text":text,"note":null})) })).unwrap();
}
pub fn family_schema() -> Schema {
    Schema::from_value(json!({"enums":[],"models":[
 {"name":"Book","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"title","nullable":false,"type":{"kind":"scalar","name":"string"}}]},
 {"name":"Comment","identity":["id"],"fields":[{"name":"id","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"bookId","nullable":false,"type":{"kind":"scalar","name":"string"}},{"name":"text","nullable":false,"type":{"kind":"scalar","name":"string"}}],"relations":[{"name":"book","target":"Book","fields":["bookId"],"targetFields":["id"],"onDelete":"delete"}],"unique":[["bookId","text"]]}
]})).unwrap()
}
pub fn create(model: &str, id: &str, values: Value) -> Operation {
    Operation { model: model.into(), op: OperationKind::Create, identity: json!({"id":id}), values: Some(values) }
}
pub fn table_count(c: &mut Client<SqliteStore>, table: &str) -> u64 {
    c.read_sql(&format!("SELECT COUNT(*) AS n FROM \"{table}\""), &[]).unwrap()[0]["n"].as_u64().unwrap()
}

#[test]
fn open_creates_tables_persists_identity_and_survives_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    let id = c.client_id().to_string();
    seed(&mut c, "A");
    assert_eq!(c.read(&key()).unwrap().unwrap(), json!({"id":"e","text":"A","note":null}));
    drop(c);
    let mut c = open(&path);
    assert_eq!(c.client_id(), id);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert_eq!(table_count(&mut c, "otter_before_Entry"), 0);
}

#[test]
fn optimistic_edit_holds_truth_once_and_rejection_rebuilds_from_it() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");
    c.transaction(|tx| { tx.enqueue(Mutation::new("Composite", vec![update("B"), update("C")]))?; Ok(()) }).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
    assert_eq!(c.before_image_count().unwrap(), 1);
    assert_eq!(c.read_sql("SELECT text FROM otter_before_Entry", &[]).unwrap(), vec![json!({"text":"A"})]);
    c.transaction(|tx| { tx.enqueue(mutation("D"))?; Ok(()) }).unwrap();
    assert_eq!(c.before_image_count().unwrap(), 1, "second edit does not copy again");
    c.drop_mutation(2).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
    c.drop_mutation(1).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert_eq!(c.before_image_count().unwrap(), 0);
}

#[test]
fn local_transaction_and_mutation_savepoint_have_independent_fate() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");
    let events = c.watch(BTreeSet::from(["Entry".to_string()]));
    let result: Result<()> = c.transaction(|tx| { tx.enqueue(mutation("B"))?; Err(invalid("rollback")) });
    assert!(result.is_err());
    assert_eq!(c.pending_count().unwrap(), 0);
    assert!(events.try_recv().is_err());
    c.transaction(|tx| {
        tx.direct(update("LOCAL"))?;
        let failed: Result<()> = tx.savepoint(|tx| { tx.enqueue(mutation("bad"))?; Err(invalid("refuse")) });
        assert!(failed.is_err());
        Ok(())
    }).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "LOCAL");
    assert_eq!(c.pending_count().unwrap(), 0);
    assert!(events.try_recv().is_ok());
    assert!(events.try_recv().is_err());
}

#[test]
fn watch_fires_only_for_declared_tables() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    let entry = c.watch(BTreeSet::from(["Entry".to_string()]));
    let queue = c.watch(BTreeSet::from(["otter_mutation".to_string()]));
    seed(&mut c, "A");
    assert!(entry.try_recv().is_ok());
    assert!(queue.try_recv().is_err());
    c.transaction(|tx| tx.set_channel("book".into(), true)).unwrap();
    assert!(entry.try_recv().is_err());
    assert_eq!(c.last_changed(), &BTreeSet::from(["otter_client".to_string(), "otter_subscription".to_string()]));
}

#[test]
fn session_reads_own_writes_without_notifying_until_commit_and_blocks_other_writes() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    seed(&mut c, "A");
    let events = c.watch(BTreeSet::from(["Entry".to_string()]));
    c.begin_session().unwrap();
    c.session(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    assert_eq!(c.session(|tx| tx.read(&key())).unwrap().unwrap()["text"], "B");
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert!(events.try_recv().is_err());
    assert!(c.apply_page(page("book", 0, 1, Some("X"))).is_err(), "no second transaction during a session");
    c.session_savepoint().unwrap();
    c.session(|tx| tx.direct(update("C"))).unwrap();
    c.session_rollback_savepoint().unwrap();
    assert_eq!(c.session(|tx| tx.read(&key())).unwrap().unwrap()["text"], "B");
    c.commit_session().unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert!(events.try_recv().is_ok());
    c.begin_session().unwrap();
    c.session(|tx| tx.direct(update("Z"))).unwrap();
    c.rollback_session().unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
}

#[test]
fn stale_writer_cannot_overwrite_committed_database() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut a = open(&path);
    let mut b = open(&path);
    seed(&mut a, "A");
    let result = b.transaction(|tx| tx.direct(Operation { model: "Entry".into(), op: OperationKind::Create, identity: json!({"id":"e"}), values: Some(json!({"text":"B","note":null})) }));
    assert!(result.is_err());
    assert_eq!(open(&path).read(&key()).unwrap().unwrap()["text"], "A");
}

#[test]
fn schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(SqliteStore::open(dir.path().join("db")).unwrap(), family_schema()).unwrap();
    c.transaction(|tx| { tx.direct(create("Book", "b", json!({"title":"Book"})))?; tx.direct(create("Comment", "c", json!({"bookId":"b","text":"hello"}))) }).unwrap();
    c.transaction(|tx| { tx.enqueue(Mutation::new("DeleteBook", vec![Operation { model: "Book".into(), op: OperationKind::Delete, identity: json!({"id":"b"}), values: None }]))?; Ok(()) }).unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
    assert_eq!(table_count(&mut c, "otter_before_Comment"), 1);
    let request = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(request.raw["mutations"][0]["operations"].as_array().unwrap().len(), 1);
    let mut ack = PushReceipt { required_channel: "book".into(), required_cursor: 0, required_checkpoints: vec![ChannelCheckpoint { channel: "book".into(), cursor: 0 }], rejections: vec![] };
    ack.rejections.push(Rejection { ordinal: 1, code: "denied".into() });
    c.acknowledge(1, ack).unwrap();
    assert_eq!(c.query("Comment", &json!({})).unwrap().len(), 1);
    assert_eq!(table_count(&mut c, "otter_before_Comment"), 0);
}

#[test]
fn declared_unique_constraint_is_atomic() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(SqliteStore::open(dir.path().join("db")).unwrap(), family_schema()).unwrap();
    let result = c.transaction(|tx| { tx.direct(create("Comment", "c1", json!({"bookId":"b","text":"same"})))?; tx.direct(create("Comment", "c2", json!({"bookId":"b","text":"same"}))) });
    assert!(result.is_err());
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
}

#[test]
fn direct_cascade_handles_cyclic_relationships_once() {
    let dir = tempfile::tempdir().unwrap();
    let mut value = serde_json::to_value(family_schema()).unwrap();
    value["models"][0]["fields"].as_array_mut().unwrap().push(json!({"name":"commentId","nullable":true,"type":{"kind":"scalar","name":"string"}}));
    value["models"][0]["relations"] = json!([{"name":"comment","target":"Comment","fields":["commentId"],"targetFields":["id"],"onDelete":"delete"}]);
    let mut c = Client::open(SqliteStore::open(dir.path().join("db")).unwrap(), Schema::from_value(value).unwrap()).unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"B","commentId":"c"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"C"})))?;
        tx.direct(Operation { model: "Book".into(), op: OperationKind::Delete, identity: json!({"id":"b"}), values: None })
    }).unwrap();
    assert!(c.query("Book", &json!({})).unwrap().is_empty());
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
}

#[test]
fn creating_then_editing_a_record_automatically_has_lifecycle_dependency() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.transaction(|tx| { tx.enqueue(Mutation::new("Create", vec![create("Entry", "e", json!({"text":"A"}))]))?; tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations.len(), 1);
}

#[test]
fn unsubscribe_drops_records_nobody_else_claims_and_restarts_from_zero() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("a", 0, 1, Some("A"))).unwrap();
    c.apply_page(page("b", 0, 1, Some("B"))).unwrap();
    let mut other = page("a", 1, 2, Some("O"));
    other.changes[0].identity = json!({"id":"only-a"});
    c.apply_page(other).unwrap();
    c.transaction(|tx| tx.set_channel("a".into(), false)).unwrap();
    assert_eq!(c.cursor("a").unwrap(), 0);
    assert!(c.read(&key()).unwrap().is_some(), "still claimed by b");
    assert!(c.read(&schema().record_key("Entry", &json!({"id":"only-a"})).unwrap()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
}
```

`freeze`, `acknowledge`, `drop_mutation`, `apply_page`, `query`, `read_sql` are implemented in Tasks 7-9; until then keep the calls compiling with the stubs described in Step 3 (they return `Err(invalid("not yet implemented"))`), and expect the tests that use them to fail. The tests that must PASS at the end of this task are: `open_creates_tables_persists_identity_and_survives_reopen`, `optimistic_edit_holds_truth_once_and_rejection_rebuilds_from_it` (needs `drop_mutation`, implemented here because it is one call into `remove_rejected`, which is defined in Task 8; so implement `drop_mutation` and `remove_rejected` in this task in `push.rs` as described in Task 8 Step 3 and move on), `local_transaction_and_mutation_savepoint_have_independent_fate`, `watch_fires_only_for_declared_tables`, `session_reads_own_writes_without_notifying_until_commit_and_blocks_other_writes`, `stale_writer_cannot_overwrite_committed_database`, `declared_unique_constraint_is_atomic`, `direct_cascade_handles_cyclic_relationships_once`.

`query` is needed by three of those. Implement the plain `query(model, filter)` (equality filter, no ordering) in `query.rs` in this task; Task 9 adds `QuerySpec` ordering, `related`, `referencing` and `read_sql`. `table_count` uses `read_sql`; implement `read_sql` here too (it is small):

```rust
    pub fn read_sql(&mut self, sql: &str, parameters: &[Value]) -> Result<Vec<Value>> {
        let rows = self.store.query_committed(sql, parameters)?;
        rows_to_objects(rows)
    }
```

with `rows_to_objects` in `query.rs`:

```rust
pub(crate) fn rows_to_objects(rows: SqlRows) -> Result<Vec<Value>> {
    if rows.columns.iter().collect::<BTreeSet<_>>().len() != rows.columns.len() {
        return Err(invalid("SQL result column names must be unique; use aliases"));
    }
    Ok(rows.rows.into_iter().map(|row| Value::Object(rows.columns.iter().cloned().zip(row).collect())).collect())
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test client`
Expected: FAIL to compile (`Client::open` takes three arguments, `watch` missing, ...).

- [ ] **Step 3: Rewrite `lib.rs`**

```rust
//! Client engine over per-model SQLite tables. No state lives in memory between calls.
pub mod connection;
pub mod ddl;
pub mod engine;
pub mod ledger;
mod mutate;
mod policies;
pub mod queue;
pub mod query;
pub mod rows;
pub mod store;
pub mod transport;
mod downlink;
mod push;

pub use connection::*;
pub use otter_core::*;
pub use query::{Direction, QueryOrder, QuerySpec};
pub use store::*;
pub use transport::*;

use engine::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::sync::mpsc::{self, Receiver, Sender};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OperationKind {
    Create,
    Update,
    Delete,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Operation {
    pub model: String,
    pub op: OperationKind,
    pub identity: Value,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub values: Option<Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mutation {
    pub name: String,
    #[serde(default = "one")]
    pub version: u64,
    pub operations: Vec<Operation>,
    #[serde(default)]
    pub companion: Vec<Operation>,
    #[serde(default)]
    pub effects: Vec<Operation>,
    #[serde(default)]
    pub prerequisites: Vec<String>,
    #[serde(default)]
    pub lifecycle_dependencies: Vec<u64>,
    #[serde(default)]
    pub sequence_dependencies: Vec<u64>,
}
fn one() -> u64 {
    1
}
impl Mutation {
    pub fn new(name: impl Into<String>, operations: Vec<Operation>) -> Self {
        Self {
            name: name.into(),
            version: 1,
            operations,
            companion: vec![],
            effects: vec![],
            prerequisites: vec![],
            lifecycle_dependencies: vec![],
            sequence_dependencies: vec![],
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Readiness {
    Pending,
    Ready,
    Failed,
}
#[derive(Debug, Default, Serialize)]
pub struct ApplyReport {
    pub applied: usize,
    pub skipped: usize,
    pub stale: bool,
    pub conflicts: usize,
    pub diagnostics: Vec<Value>,
}

struct Session {
    changed: BTreeSet<String>,
    savepoints: Vec<String>,
    counter: u64,
}

pub struct Client<S: ClientStore> {
    store: S,
    schema: Schema,
    client_id: String,
    generation: u64,
    watchers: Vec<(BTreeSet<String>, Sender<()>)>,
    session: Option<Session>,
    last_changed: BTreeSet<String>,
}

impl<S: ClientStore> Client<S> {
    pub fn open(mut store: S, schema: Schema) -> Result<Self> {
        schema.validate()?;
        store.execute_batch(ddl::FRAMEWORK_DDL)?;
        store.begin()?;
        let opened = (|| {
            ddl::reconcile(&mut store, &schema)?;
            let row = store.query("SELECT client_id, generation FROM otter_client", &[])?;
            let (client_id, generation) = match row.rows.first() {
                Some(r) => (r[0].as_str().unwrap_or("").to_string(), engine::as_u64(&r[1])?),
                None => {
                    let id = uuid::Uuid::new_v4().to_string();
                    store.execute("INSERT INTO otter_client (client_id, next_ordinal, next_push, generation) VALUES (?,1,1,1)", &[Value::from(id.clone())])?;
                    (id, 1)
                }
            };
            Ok::<_, Error>((client_id, generation))
        })();
        let (client_id, generation) = match opened {
            Ok(v) => v,
            Err(e) => {
                store.rollback()?;
                return Err(e);
            }
        };
        store.commit()?;
        let mut client = Self { store, schema, client_id, generation, watchers: vec![], session: None, last_changed: BTreeSet::new() };
        client.write(|e| e.settle())?;
        Ok(client)
    }
    pub fn client_id(&self) -> &str {
        &self.client_id
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn last_changed(&self) -> &BTreeSet<String> {
        &self.last_changed
    }
    pub fn session_active(&self) -> bool {
        self.session.is_some()
    }
    pub fn watch(&mut self, tables: BTreeSet<String>) -> Receiver<()> {
        let (tx, rx) = mpsc::channel();
        self.watchers.push((tables, tx));
        rx
    }
    fn notify(&mut self, changed: BTreeSet<String>) {
        self.watchers.retain(|(tables, sender)| {
            if tables.iter().any(|t| changed.contains(t)) {
                sender.send(()).is_ok()
            } else {
                true
            }
        });
        self.last_changed = changed;
    }
    /// Bump the generation inside the open transaction; a stale writer fails here.
    fn fence(&mut self) -> Result<()> {
        let affected = self.store.execute(
            "UPDATE otter_client SET generation = generation + 1 WHERE generation = ?",
            &[Value::from(self.generation)],
        )?;
        if affected != 1 {
            return Err(invalid("stale client writer; reopen runtime"));
        }
        Ok(())
    }
    pub(crate) fn write<T>(&mut self, body: impl FnOnce(&mut Engine<'_, S>) -> Result<T>) -> Result<T> {
        if self.session.is_some() {
            return Err(invalid("client transaction active"));
        }
        self.store.begin()?;
        let mut changed = BTreeSet::new();
        let result = body(&mut Engine::new(&mut self.store, &self.schema, &mut changed, false)).and_then(|v| self.fence().map(|_| v));
        match result {
            Ok(value) => {
                self.store.commit()?;
                self.generation += 1;
                changed.insert("otter_client".into());
                self.notify(changed);
                Ok(value)
            }
            Err(e) => {
                self.store.rollback()?;
                Err(e)
            }
        }
    }
    pub(crate) fn view<T>(&mut self, body: impl FnOnce(&mut Engine<'_, S>) -> Result<T>) -> Result<T> {
        let mut changed = BTreeSet::new();
        body(&mut Engine::new(&mut self.store, &self.schema, &mut changed, true))
    }
    pub fn transaction<T>(&mut self, body: impl FnOnce(&mut ClientTransaction<'_, S>) -> Result<T>) -> Result<T> {
        self.write(|engine| {
            let mut tx = ClientTransaction { engine: Engine::new(engine.store, engine.schema, engine.changed, false), depth: 0 };
            body(&mut tx)
        })
    }
    pub fn begin_session(&mut self) -> Result<()> {
        if self.session.is_some() {
            return Err(invalid("transaction already active"));
        }
        self.store.begin()?;
        self.session = Some(Session { changed: BTreeSet::new(), savepoints: vec![], counter: 0 });
        Ok(())
    }
    pub fn session<T>(&mut self, body: impl FnOnce(&mut ClientTransaction<'_, S>) -> Result<T>) -> Result<T> {
        let session = self.session.as_mut().ok_or_else(|| invalid("no active transaction"))?;
        let mut tx = ClientTransaction { engine: Engine::new(&mut self.store, &self.schema, &mut session.changed, false), depth: 0 };
        body(&mut tx)
    }
    pub fn commit_session(&mut self) -> Result<()> {
        let session = self.session.take().ok_or_else(|| invalid("no active transaction"))?;
        if !session.savepoints.is_empty() {
            self.store.rollback()?;
            return Err(invalid("unclosed savepoint"));
        }
        if let Err(e) = self.fence() {
            self.store.rollback()?;
            return Err(e);
        }
        self.store.commit()?;
        self.generation += 1;
        let mut changed = session.changed;
        changed.insert("otter_client".into());
        self.notify(changed);
        Ok(())
    }
    pub fn rollback_session(&mut self) -> Result<()> {
        self.session.take().ok_or_else(|| invalid("no active transaction"))?;
        self.store.rollback()
    }
    pub fn session_savepoint(&mut self) -> Result<()> {
        let session = self.session.as_mut().ok_or_else(|| invalid("no active transaction"))?;
        session.counter += 1;
        let name = format!("session_{}", session.counter);
        self.store.savepoint(&name)?;
        session.savepoints.push(name);
        Ok(())
    }
    pub fn session_release(&mut self) -> Result<()> {
        let session = self.session.as_mut().ok_or_else(|| invalid("no active transaction"))?;
        let name = session.savepoints.pop().ok_or_else(|| invalid("no savepoint"))?;
        self.store.release(&name)
    }
    pub fn session_rollback_savepoint(&mut self) -> Result<()> {
        let session = self.session.as_mut().ok_or_else(|| invalid("no active transaction"))?;
        let name = session.savepoints.pop().ok_or_else(|| invalid("no savepoint"))?;
        self.store.rollback_to(&name)
    }
    pub fn read(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        let key = self.schema.record_key(&key.model, &key.identity)?;
        self.view(|e| e.read_row(&key))
    }
    pub fn read_sql(&mut self, sql: &str, parameters: &[Value]) -> Result<Vec<Value>> {
        let rows = self.store.query_committed(sql, parameters)?;
        query::rows_to_objects(rows)
    }
    pub fn session_sql(&mut self, sql: &str, parameters: &[Value]) -> Result<Vec<Value>> {
        if self.session.is_none() {
            return Err(invalid("no active transaction"));
        }
        let rows = self.store.query(sql, parameters)?;
        query::rows_to_objects(rows)
    }
    pub fn pending_count(&mut self) -> Result<usize> {
        self.view(|e| Ok(e.count("otter_mutation")? as usize))
    }
    pub fn before_image_count(&mut self) -> Result<usize> {
        let tables: Vec<String> = self.schema.models.iter().map(|m| ddl::before_table(&m.name)).collect();
        self.view(|e| {
            let mut total = 0;
            for table in &tables {
                total += e.count(table)? as usize;
            }
            Ok(total)
        })
    }
    pub fn cursor(&mut self, channel: &str) -> Result<u64> {
        self.view(|e| Ok(e.cursor(channel)?.unwrap_or(0)))
    }
    pub fn subscriptions(&mut self) -> Result<Vec<(String, u64)>> {
        self.view(|e| e.subscriptions())
    }
    pub fn desired_channels(&mut self) -> Result<BTreeSet<String>> {
        Ok(self.subscriptions()?.into_iter().map(|(c, _)| c).collect())
    }
    pub fn checkpoint_channels(&mut self) -> Result<BTreeSet<String>> {
        self.view(|e| e.checkpoint_channels())
    }
}

pub struct ClientTransaction<'a, S: ClientStore> {
    pub(crate) engine: Engine<'a, S>,
    depth: u64,
}
impl<S: ClientStore> ClientTransaction<'_, S> {
    pub fn read(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        let key = self.engine.schema.record_key(&key.model, &key.identity)?;
        self.engine.read_row(&key)
    }
    pub fn savepoint<T>(&mut self, body: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        self.depth += 1;
        let name = format!("tx_{}", self.depth);
        self.engine.store.savepoint(&name)?;
        let result = body(self);
        self.depth -= 1;
        match result {
            Ok(v) => {
                self.engine.store.release(&name)?;
                Ok(v)
            }
            Err(e) => {
                self.engine.store.rollback_to(&name)?;
                Err(e)
            }
        }
    }
    pub fn set_channel(&mut self, channel: String, subscribed: bool) -> Result<()> {
        if subscribed {
            if self.engine.cursor(&channel)?.is_none() {
                self.engine.set_cursor(&channel, 0)?;
            }
            Ok(())
        } else {
            self.engine.unsubscribe(&channel)
        }
    }
    pub fn enqueue(&mut self, mutation: Mutation) -> Result<u64> {
        self.savepoint(|tx| tx.engine.enqueue(mutation))
    }
    pub fn direct(&mut self, operation: Operation) -> Result<()> {
        self.savepoint(|tx| tx.engine.direct(operation))
    }
}
```

`Client` methods `query`, `query_spec`, `related`, `referencing`, `freeze`, `freeze_with_limit`, `acknowledge`, `apply_page`, `set_readiness`, `dismiss_rejection`, `drop_mutation`, `record_status`, `rejections`, `pending_tasks` are added by Tasks 7-9; `ClientTransaction` gets `query`, `query_spec`, `related`, `referencing` in Task 9. For this task add stubs for the ones the tests call (`query`, `freeze`, `acknowledge`, `apply_page`) that return `Err(invalid("not yet implemented"))`, except `query`, which Task 9 fully replaces but is implemented here for equality filters:

```rust
    pub fn query(&mut self, model: &str, filter: &Value) -> Result<Vec<Value>> {
        let filter: std::collections::BTreeMap<String, Value> = serde_json::from_value(filter.clone())?;
        self.view(|e| query::evaluate(e, model, &QuerySpec { filter, ..Default::default() }))
    }
```

and `query::evaluate` for this task is the filter-only version from Task 9 Step 3 without ordering or limit.

Add `uuid` is already a dependency of `otter-client`. Remove `pub mod migration; pub mod cascade;` and delete both files.

- [ ] **Step 4: Write `mutate.rs`**

```rust
//! Optimistic writes, truth holding, rebuild, cascade and authority changes.
use crate::ddl::before_table;
use crate::engine::Engine;
use crate::queue::OpKind;
use crate::rows::merge_identity;
use crate::store::ClientStore;
use crate::{Mutation, Operation, OperationKind, policies};
use otter_core::{RecordKey, Result, invalid};
use serde_json::Value;
use std::collections::BTreeSet;

pub fn apply_to_row(row: &mut Option<Value>, op: &Operation) -> Result<()> {
    match op.op {
        OperationKind::Create => {
            if row.is_some() {
                return Err(invalid("create already exists"));
            }
            let values = op.values.as_ref().ok_or_else(|| invalid("create values missing"))?;
            *row = Some(merge_identity(&op.identity, values));
        }
        OperationKind::Update => {
            let current = row.as_mut().ok_or_else(|| invalid("update row missing"))?;
            let patch = op.values.as_ref().and_then(Value::as_object).ok_or_else(|| invalid("patch missing"))?;
            for (k, v) in patch {
                current[k] = v.clone();
            }
        }
        OperationKind::Delete => {
            *row = None;
        }
    }
    Ok(())
}

fn normalize(schema: &otter_core::Schema, op: &mut Operation) -> Result<()> {
    op.identity = schema.record_key(&op.model, &op.identity)?.identity;
    match op.op {
        OperationKind::Create => {
            let values = op.values.as_ref().ok_or_else(|| invalid("create values missing"))?;
            op.values = Some(schema.normalize_state(&op.model, values)?);
        }
        OperationKind::Update => {
            let values = op.values.as_ref().ok_or_else(|| invalid("update values missing"))?;
            op.values = Some(schema.validate_patch(&op.model, values)?);
        }
        OperationKind::Delete => {
            if op.values.is_some() {
                return Err(invalid("delete cannot contain values"));
            }
        }
    }
    Ok(())
}

impl<S: ClientStore> Engine<'_, S> {
    pub fn read_row(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        let model = self.schema.model(&key.model)?.clone();
        self.row_get(&key.model, &model, &key.identity)
    }
    fn before_get(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        let model = self.schema.model(&key.model)?.clone();
        self.row_get(&before_table(&key.model), &model, &key.identity)
    }
    fn before_set(&mut self, key: &RecordKey, row: Option<&Value>) -> Result<()> {
        let model = self.schema.model(&key.model)?.clone();
        let table = before_table(&key.model);
        match row {
            Some(row) => self.row_upsert(&table, &model, row),
            None => self.row_delete(&table, &model, &key.identity),
        }
    }
    fn main_set(&mut self, key: &RecordKey, row: Option<&Value>) -> Result<()> {
        let model = self.schema.model(&key.model)?.clone();
        match row {
            Some(row) => self.row_upsert(&key.model, &model, row),
            None => self.row_delete(&key.model, &model, &key.identity),
        }
    }
    pub fn truth(&mut self, key: &RecordKey) -> Result<Option<Value>> {
        if self.dirty(key)? {
            self.before_get(key)
        } else {
            self.read_row(key)
        }
    }
    pub fn apply_main(&mut self, op: &Operation) -> Result<()> {
        let key = self.schema.record_key(&op.model, &op.identity)?;
        let model = self.schema.model(&op.model)?.clone();
        match op.op {
            OperationKind::Create => {
                let values = op.values.as_ref().ok_or_else(|| invalid("create values missing"))?;
                let row = merge_identity(&op.identity, values);
                if self.read_row(&key)?.is_some() {
                    return Err(invalid("create already exists"));
                }
                self.row_insert(&op.model, &model, &row)
            }
            OperationKind::Update => {
                let mut row = self.read_row(&key)?;
                apply_to_row(&mut row, op)?;
                self.row_upsert(&op.model, &model, row.as_ref().ok_or_else(|| invalid("update row missing"))?)
            }
            OperationKind::Delete => self.row_delete(&op.model, &model, &op.identity),
        }
    }
    pub fn hold_truth(&mut self, key: &RecordKey) -> Result<()> {
        if self.dirty(key)? {
            return Ok(());
        }
        let model = self.schema.model(&key.model)?.clone();
        self.copy_aside(&model, &key.identity)
    }
    pub fn rebuild(&mut self, key: &RecordKey) -> Result<()> {
        let truth = self.before_get(key)?;
        let ops = self.ops_for(key)?;
        let mut row = truth.clone();
        let mut failed = false;
        for queued in &ops {
            if apply_to_row(&mut row, &queued.op).is_err() {
                failed = true;
                break;
            }
        }
        let result = if failed { truth.clone() } else { row };
        if self.main_set(key, result.as_ref()).is_err() {
            self.main_set(key, truth.as_ref())?;
        }
        if ops.is_empty() {
            self.before_set(key, None)?;
        }
        Ok(())
    }
    pub fn descendants(&mut self, parent: &RecordKey) -> Result<Vec<RecordKey>> {
        let mut seen = BTreeSet::from([parent.encoded()?]);
        let mut todo = vec![parent.clone()];
        let mut result = vec![];
        while let Some(parent) = todo.pop() {
            for model in self.schema.models.clone() {
                for relation in &model.relations {
                    if relation.target != parent.model || relation.on_delete != "delete" {
                        continue;
                    }
                    let filter: Vec<(String, Value)> = relation
                        .fields
                        .iter()
                        .zip(&relation.target_fields)
                        .map(|(local, target)| (local.clone(), parent.identity[target].clone()))
                        .collect();
                    let mut identities = self.identities_where(&model.name, &model, &filter)?;
                    identities.extend(self.identities_where(&before_table(&model.name), &model, &filter)?);
                    for identity in identities {
                        let child = self.schema.record_key(&model.name, &identity)?;
                        if seen.insert(child.encoded()?) {
                            todo.push(child.clone());
                            result.push(child);
                        }
                    }
                }
            }
        }
        Ok(result)
    }
    pub fn refresh_pending(&mut self) -> Result<()> {
        for queued in self.queued()? {
            let deletes: Vec<Operation> = queued
                .mutation
                .operations
                .iter()
                .chain(&queued.mutation.companion)
                .filter(|op| op.op == OperationKind::Delete)
                .cloned()
                .collect();
            for op in deletes {
                let parent = self.schema.record_key(&op.model, &op.identity)?;
                for child in self.descendants(&parent)? {
                    let already = queued.mutation.effects.iter().any(|e| e.model == child.model && e.identity == child.identity);
                    if already {
                        continue;
                    }
                    self.hold_truth(&child)?;
                    self.add_effect(queued.ordinal, &Operation { model: child.model.clone(), identity: child.identity.clone(), op: OperationKind::Delete, values: None })?;
                    self.rebuild(&child)?;
                }
            }
        }
        Ok(())
    }
    fn set_authority_one(&mut self, key: &RecordKey, value: Option<Value>) -> Result<()> {
        if self.dirty(key)? {
            self.before_set(key, value.as_ref())?;
            self.rebuild(key)
        } else {
            self.main_set(key, value.as_ref())
        }
    }
    pub fn set_authority(&mut self, key: &RecordKey, value: Option<Value>) -> Result<()> {
        if value.is_none() {
            for child in self.descendants(key)? {
                self.claims_remove_all(&child)?;
                self.drop_record(&child)?;
                self.set_authority_one(&child, None)?;
            }
        }
        self.set_authority_one(key, value)?;
        self.refresh_pending()
    }
    pub fn enqueue(&mut self, mut mutation: Mutation) -> Result<u64> {
        if mutation.name.trim().is_empty() || mutation.version == 0 || mutation.operations.is_empty() {
            return Err(invalid("invalid named mutation"));
        }
        for dependency in mutation.lifecycle_dependencies.iter().chain(&mutation.sequence_dependencies) {
            if self.queued_one(*dependency)?.is_none() {
                return Err(invalid("unknown mutation dependency"));
            }
        }
        mutation.effects.clear();
        let mut effects = vec![];
        let wire = mutation.operations.len();
        let mut all: Vec<Operation> = mutation.operations.drain(..).chain(mutation.companion.drain(..)).collect();
        for op in all.iter_mut() {
            normalize(self.schema, op)?;
            let key = self.schema.record_key(&op.model, &op.identity)?;
            self.hold_truth(&key)?;
            if op.op == OperationKind::Delete {
                for child in self.descendants(&key)? {
                    self.hold_truth(&child)?;
                    let effect = Operation { model: child.model, identity: child.identity, op: OperationKind::Delete, values: None };
                    self.apply_main(&effect)?;
                    effects.push(effect);
                }
            }
            self.apply_main(op)?;
        }
        mutation.companion = all.split_off(wire);
        mutation.operations = all;
        mutation.effects = effects;
        policies::derive(self, &mut mutation)?;
        let ordinal = self.allocate_ordinal()?;
        self.insert_mutation(ordinal, &mutation)?;
        Ok(ordinal)
    }
    pub fn direct(&mut self, mut operation: Operation) -> Result<()> {
        normalize(self.schema, &mut operation)?;
        let key = self.schema.record_key(&operation.model, &operation.identity)?;
        if operation.op == OperationKind::Delete {
            for child in self.descendants(&key)? {
                self.direct_one(Operation { model: child.model, identity: child.identity, op: OperationKind::Delete, values: None })?;
            }
        }
        self.direct_one(operation)
    }
    fn direct_one(&mut self, operation: Operation) -> Result<()> {
        let key = self.schema.record_key(&operation.model, &operation.identity)?;
        let is_dirty = self.dirty(&key)?;
        self.apply_main(&operation)?;
        if is_dirty {
            let mut truth = self.before_get(&key)?;
            if operation.op == OperationKind::Delete {
                self.before_set(&key, None)?;
            } else if apply_to_row(&mut truth, &operation).is_ok() {
                self.before_set(&key, truth.as_ref())?;
            } else {
                let current = self.read_row(&key)?;
                self.before_set(&key, current.as_ref())?;
            }
        }
        Ok(())
    }
    pub fn unsubscribe(&mut self, channel: &str) -> Result<()> {
        for key in self.claimed_by(channel)? {
            self.claim_remove(channel, &key)?;
            if self.claims(&key)?.is_empty() {
                self.drop_record(&key)?;
                self.set_authority(&key, None)?;
            }
        }
        self.delete_subscription(channel)
    }
}
```

Each `hold_truth` in `enqueue` runs before the operation is inserted, so `dirty` still reflects earlier mutations only, exactly like the old code that pushed to the queue at the end. The `OpKind` import is unused here; drop it if clippy complains.

- [ ] **Step 5: Rewrite `policies.rs` over the engine**

Replace every `state.records/state.before/state.queue/state.tasks` access. The logic is unchanged; the data sources are:

```rust
//! Resolve schema-declared dependencies from data, without replaying application callbacks.
use crate::engine::Engine;
use crate::store::ClientStore;
use crate::{Mutation, OperationKind};
use otter_core::{RecordKey, Result, canonical_json, invalid};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn derive<S: ClientStore>(engine: &mut Engine<'_, S>, mutation: &mut Mutation) -> Result<()> {
    let queue = engine.queued()?;
    let schema = engine.schema;
    let mut lifecycle: BTreeSet<_> = mutation.lifecycle_dependencies.iter().copied().collect();
    for op in &mutation.operations {
        let key = schema.record_key(&op.model, &op.identity)?;
        let mut references = vec![key.clone()];
        for relation in &schema.model(&key.model)?.relations {
            if let Some(target) = reference(engine, &key, &relation.name)? {
                references.push(target);
            }
        }
        for prior in &queue {
            for previous in &prior.mutation.operations {
                let previous_key = schema.record_key(&previous.model, &previous.identity)?;
                if (previous.op == OperationKind::Create && references.contains(&previous_key))
                    || (previous.op == OperationKind::Delete && op.op == OperationKind::Create && previous_key == key)
                {
                    lifecycle.insert(prior.ordinal);
                }
            }
        }
        for requirement in schema.requirements.iter().filter(|r| r.model == op.model) {
            let Some(value) = op.values.as_ref().and_then(|v| v.get(&requirement.field)).filter(|v| !v.is_null()) else {
                continue;
            };
            let arguments: serde_json::Map<_, _> = requirement.arguments.keys().map(|k| (k.clone(), value.clone())).collect();
            let invocation = json!({"name":requirement.name,"arguments":arguments});
            mutation.prerequisites.push(canonical_json(&invocation)?);
        }
    }
    mutation.lifecycle_dependencies = lifecycle.into_iter().collect();
    mutation.prerequisites.sort();
    mutation.prerequisites.dedup();
    let mut sequences: BTreeSet<_> = mutation.sequence_dependencies.iter().copied().collect();
    if let Some(policy) = policy_fn(schema, mutation) {
        let current = slots(schema, mutation, policy)?;
        if let Some(after) = policy["sequence"]["after"].as_array() {
            for reference_spec in after {
                let name = reference_spec["name"].as_str().ok_or_else(|| invalid("invalid sequence descriptor"))?;
                let arguments = reference_spec["arguments"].as_object().ok_or_else(|| invalid("invalid sequence arguments"))?;
                for prior in queue.iter().filter(|q| q.mutation.name == name) {
                    let Some(prior_policy) = policy_fn(schema, &prior.mutation) else { continue };
                    let targets = slots(schema, &prior.mutation, prior_policy)?;
                    let mut matches = true;
                    for (target, path) in arguments {
                        let path = path.as_str().ok_or_else(|| invalid("invalid sequence path"))?;
                        let source = resolve(engine, &current, path)?;
                        if source.is_none() || !targets.get(target).is_some_and(|keys| keys.contains(source.as_ref().unwrap())) {
                            matches = false;
                            break;
                        }
                    }
                    if matches {
                        sequences.insert(prior.ordinal);
                    }
                }
            }
        }
    }
    mutation.sequence_dependencies = sequences.into_iter().collect();
    Ok(())
}
fn policy_fn<'a>(schema: &'a otter_core::Schema, mutation: &Mutation) -> Option<&'a Value> {
    schema.client_policies.iter().find(|p| p["name"] == mutation.name && p["version"].as_u64() == Some(mutation.version))
}
fn slots(schema: &otter_core::Schema, mutation: &Mutation, policy: &Value) -> Result<BTreeMap<String, Vec<RecordKey>>> {
    // unchanged from the previous implementation
    let mut result = BTreeMap::new();
    let mut at = 0;
    for slot in policy["slots"].as_array().ok_or_else(|| invalid("client policy slots missing"))? {
        let name = slot["name"].as_str().ok_or_else(|| invalid("slot name missing"))?;
        let mut keys = vec![];
        while let Some(op) = mutation.operations.get(at) {
            if slot["model"] != op.model || slot["operation"] != serde_json::to_value(op.op)? {
                break;
            }
            keys.push(schema.record_key(&op.model, &op.identity)?);
            at += 1;
            if slot["cardinality"] != "list" {
                break;
            }
        }
        result.insert(name.into(), keys);
    }
    Ok(result)
}
fn resolve<S: ClientStore>(engine: &mut Engine<'_, S>, slots: &BTreeMap<String, Vec<RecordKey>>, path: &str) -> Result<Option<RecordKey>> {
    let mut parts = path.split('.');
    let first = parts.next().ok_or_else(|| invalid("empty path"))?;
    let Some(keys) = slots.get(first).filter(|v| v.len() == 1) else { return Ok(None) };
    let mut key = keys[0].clone();
    for part in parts {
        let Some(next) = reference(engine, &key, part)? else { return Ok(None) };
        key = next;
    }
    Ok(Some(key))
}
fn reference<S: ClientStore>(engine: &mut Engine<'_, S>, key: &RecordKey, name: &str) -> Result<Option<RecordKey>> {
    let relation = engine.schema.model(&key.model)?.relations.iter().find(|r| r.name == name).ok_or_else(|| invalid("unknown relation in dependency"))?.clone();
    let row = match engine.read_row(key)? {
        Some(row) => Some(row),
        None => engine.truth(key)?,
    };
    let Some(row) = row else { return Ok(None) };
    let mut identity = serde_json::Map::new();
    for (local, target) in relation.fields.iter().zip(&relation.target_fields) {
        let Some(value) = row.get(local).filter(|v| !v.is_null()) else { return Ok(None) };
        identity.insert(target.clone(), value.clone());
    }
    Ok(Some(engine.schema.record_key(&relation.target, &Value::Object(identity))?))
}
```

The old `state.tasks` map is gone: the prerequisite key is the canonical JSON of the invocation, and `pending_tasks()` (Task 8) parses it back.

- [ ] **Step 6: Run the client tests**

Run: `cargo test -p otter-sqlite --locked --test client`
Expected: the eight tests listed in Step 1 PASS; the ones needing `freeze`/`acknowledge`/`apply_page` FAIL with `not yet implemented`. Also run `cargo test -p otter-sqlite --locked --test engine --test ddl --test store` to confirm nothing regressed.

- [ ] **Step 7: Commit**

Stage `crates/client` and `crates/sqlite/tests/client.rs`; commit as `feat(client): row-based engine with transactions, sessions and table watches`.

---

### Task 7: Downlink with stamps and tombstones

**Files:**
- Create: `crates/client/src/downlink.rs`
- Modify: `crates/client/src/lib.rs` (add `pub fn apply_page`)
- Test: `crates/sqlite/tests/downlink.rs`

**Interfaces:**
- Produces: `Client::apply_page(&mut self, page: PullPage) -> Result<ApplyReport>` and `Engine::apply_change(&mut self, channel: &str, change: &RecordChange, report: &mut ApplyReport) -> Result<()>`.
- Consumes: `Engine::settle()` from Task 8. For this task add `pub fn settle(&mut self) -> Result<()> { Ok(()) }` in a new `push.rs` if it does not exist yet; Task 8 fills it in.

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/downlink.rs`. Copy the helper block (`schema`, `open`, `key`, `page`, `table_count`) from `crates/sqlite/tests/client.rs` verbatim at the top (Rust integration tests do not share modules), then:

```rust
fn stamped(channel: &str, from: u64, to: u64, stamp: u64, text: Option<&str>) -> PullPage {
    let mut p = page(channel, from, to, text);
    p.changes[0].stamp = Some(stamp);
    p
}

#[test]
fn channel_claims_and_cross_channel_delete() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("a", 0, 1, Some("A"))).unwrap();
    c.apply_page(page("b", 0, 1, Some("B"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(table_count(&mut c, "otter_claim"), 2);
    c.apply_page(page("a", 1, 2, None)).unwrap();
    assert!(c.read(&key()).unwrap().is_none(), "delete applies across channels");
    assert_eq!(table_count(&mut c, "otter_claim"), 1, "b's claim is the pending tombstone confirmation");
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    c.apply_page(page("b", 1, 2, None)).unwrap();
    assert_eq!(table_count(&mut c, "otter_claim"), 0);
    assert_eq!(table_count(&mut c, "otter_record"), 0, "tombstone dropped once every channel confirmed");
    assert_eq!(c.cursor("a").unwrap(), 2);
    assert_eq!(c.cursor("b").unwrap(), 2);
}

#[test]
fn older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(stamped("b", 0, 1, 11, Some("NEW"))).unwrap();
    let report = c.apply_page(stamped("a", 0, 1, 10, Some("OLD"))).unwrap();
    assert_eq!((report.applied, report.skipped, report.conflicts), (1, 0, 0));
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NEW");
    assert_eq!(table_count(&mut c, "otter_claim"), 2, "stale content still records the claim");
    assert_eq!(c.cursor("a").unwrap(), 1);
    let old_delete = c.apply_page(stamped("a", 1, 2, 9, None)).unwrap();
    assert_eq!(old_delete.applied, 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NEW", "an old tombstone cannot delete newer content");
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
}

#[test]
fn equal_stamp_is_idempotent_or_a_diagnostic() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(stamped("a", 0, 1, 5, Some("X"))).unwrap();
    let same = c.apply_page(stamped("b", 0, 1, 5, Some("X"))).unwrap();
    assert_eq!(same.conflicts, 0);
    let conflict = c.apply_page(stamped("b", 1, 2, 5, Some("Y"))).unwrap();
    assert_eq!(conflict.conflicts, 1);
    assert_eq!(conflict.diagnostics[0]["stamp"], 5);
    assert_eq!(conflict.diagnostics[0]["model"], "Entry");
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "X");
    assert_eq!(c.cursor("b").unwrap(), 2, "the channel is not stalled");
}

#[test]
fn newer_authority_lands_beneath_pending_edits_and_replays_them() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    c.apply_page(page("book", 1, 2, Some("SERVER"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    assert_eq!(c.read_sql("SELECT text FROM otter_before_Entry", &[]).unwrap(), vec![json!({"text":"SERVER"})]);
}

#[test]
fn original_bad_change_skip_policy_is_retained() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    let mut bad = page("book", 1, 2, Some("B"));
    bad.changes[0].state = json!({"text":22});
    let report = c.apply_page(bad).unwrap();
    assert_eq!(report.skipped, 1);
    assert_eq!(c.cursor("book"), 2);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    let stale = c.apply_page(page("book", 1, 2, Some("Z"))).unwrap();
    assert!(stale.stale);
    assert!(c.apply_page(page("book", 5, 6, Some("Z"))).is_err(), "cursor gap");
}

#[test]
fn delete_cascades_to_descendants_and_their_claims() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(SqliteStore::open(dir.path().join("db")).unwrap(), family_schema()).unwrap();
    let book = |cursor, state| PullPage { channel: "lib".into(), from_cursor: cursor - 1, to_cursor: cursor, changes: vec![RecordChange { cursor, model: "Book".into(), identity: json!({"id":"b"}), stamp: None, state }] };
    c.apply_page(book(1, json!({"title":"T"}))).unwrap();
    c.apply_page(PullPage { channel: "lib".into(), from_cursor: 1, to_cursor: 2, changes: vec![RecordChange { cursor: 2, model: "Comment".into(), identity: json!({"id":"c"}), stamp: None, state: json!({"bookId":"b","text":"hi"}) }] }).unwrap();
    assert_eq!(table_count(&mut c, "otter_claim"), 2);
    c.apply_page(book(3, Value::Null)).unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
    assert_eq!(table_count(&mut c, "otter_claim"), 0);
    assert_eq!(table_count(&mut c, "otter_record"), 0);
}
```

`c.cursor("book")` returns `Result<u64>` now; write `c.cursor("book").unwrap()` everywhere.

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test downlink`
Expected: FAIL (`apply_page` returns `not yet implemented`).

- [ ] **Step 3: Write `downlink.rs`**

```rust
//! Apply a Pull page: channel order by cursor, record content by stamp.
use crate::engine::Engine;
use crate::rows::merge_identity;
use crate::store::ClientStore;
use crate::{ApplyReport, Client};
use otter_core::{PullPage, RecordChange, Result, invalid};
use serde_json::json;

impl<S: ClientStore> Engine<'_, S> {
    pub fn apply_change(&mut self, channel: &str, change: &RecordChange, report: &mut ApplyReport) -> Result<()> {
        let key = self.schema.record_key(&change.model, &change.identity)?;
        let local = self.record_stamp(&key)?;
        let is_delete = change.state.is_null();
        let incoming = if is_delete {
            None
        } else {
            Some(merge_identity(&key.identity, &self.schema.validate_state(&change.model, &change.state)?))
        };
        let newer = match change.stamp {
            None => true,
            Some(stamp) if stamp > local => true,
            Some(stamp) if stamp < local => false,
            Some(stamp) => {
                // equal stamp: idempotent when content matches, diagnostic otherwise
                let current = self.truth(&key)?;
                if current == incoming {
                    false
                } else {
                    report.conflicts += 1;
                    report.diagnostics.push(json!({
                        "model": key.model, "identity": key.identity, "stamp": stamp, "channel": channel,
                        "local": current, "incoming": incoming,
                    }));
                    false
                }
            }
        };
        if !newer {
            if is_delete {
                self.claim_remove(channel, &key)?;
                if self.read_row(&key)?.is_none() && !self.dirty(&key)? && self.claims(&key)?.is_empty() {
                    self.drop_record(&key)?;
                }
            } else {
                self.claim_add(channel, &key)?;
            }
            return Ok(());
        }
        if is_delete {
            self.set_authority(&key, None)?;
            self.claim_remove(channel, &key)?;
            if self.claims(&key)?.is_empty() {
                self.drop_record(&key)?;
            } else {
                self.set_record_stamp(&key, change.stamp.unwrap_or(local))?;
            }
        } else {
            self.set_authority(&key, incoming)?;
            self.claim_add(channel, &key)?;
            self.set_record_stamp(&key, change.stamp.unwrap_or(local))?;
        }
        Ok(())
    }
}

impl<S: ClientStore> Client<S> {
    /// Per-change commits; a failing change is skipped and the cursor still advances (reference behavior).
    pub fn apply_page(&mut self, page: PullPage) -> Result<ApplyReport> {
        page.validate()?;
        let current = self.cursor(&page.channel)?;
        if page.to_cursor <= current {
            return Ok(ApplyReport { stale: true, ..Default::default() });
        }
        if page.from_cursor > current {
            return Err(invalid("pull cursor gap"));
        }
        let mut report = ApplyReport::default();
        for change in page.changes.iter().filter(|c| c.cursor > current) {
            let channel = page.channel.clone();
            self.write(|e| {
                let expected = e.cursor(&channel)?.unwrap_or(0);
                if expected >= change.cursor {
                    return Err(invalid("cursor moved during page application"));
                }
                e.store.savepoint("change")?;
                match e.apply_change(&channel, change, &mut report) {
                    Ok(()) => {
                        e.store.release("change")?;
                        report.applied += 1;
                    }
                    Err(_) => {
                        e.store.rollback_to("change")?;
                        report.skipped += 1;
                    }
                }
                e.set_cursor(&channel, change.cursor)?;
                e.settle()
            })?;
        }
        if self.cursor(&page.channel)? < page.to_cursor {
            let channel = page.channel.clone();
            self.write(|e| {
                e.set_cursor(&channel, page.to_cursor)?;
                e.settle()
            })?;
        }
        Ok(report)
    }
}
```

The `report` borrow inside the closure: `write` takes `FnOnce`, so capturing `&mut report` is fine.

The first `apply_page` on an unsubscribed channel inserts the subscription row through `set_cursor`; a page arriving means the host asked for it.

- [ ] **Step 4: Run the downlink tests**

Run: `cargo test -p otter-sqlite --locked --test downlink`
Expected: PASS for every test except `newer_authority_lands_beneath_pending_edits_and_replays_them` and `delete_cascades...` only if they depend on `settle` beyond the stub (they do not). All six should PASS.

- [ ] **Step 5: Commit**

Stage `crates/client/src` and `crates/sqlite/tests/downlink.rs`; commit as `feat(client): downlink applies content by stamp and membership by channel`.

---

### Task 8: Push, receipts, settlement, rejections and readiness

**Files:**
- Create: `crates/client/src/push.rs`
- Modify: `crates/client/src/lib.rs` (add the `Client` methods listed below)
- Test: `crates/sqlite/tests/push.rs`

**Interfaces:**
- Produces (`Client`):

```rust
pub fn freeze(&mut self) -> Result<Option<Vec<u8>>>;                       // 256 KiB limit
pub fn freeze_with_limit(&mut self, max_bytes: usize) -> Result<Option<Vec<u8>>>;
pub fn acknowledge(&mut self, sequence: u64, receipt: PushReceipt) -> Result<()>;
pub fn set_readiness(&mut self, key: &str, value: Readiness) -> Result<()>;
pub fn pending_tasks(&mut self) -> Result<Vec<Value>>;                     // [{ "key", "state": "pending"|"failed", ...invocation fields }]
pub fn dismiss_rejection(&mut self, ordinal: u64) -> Result<()>;
pub fn drop_mutation(&mut self, ordinal: u64) -> Result<()>;
pub fn rejections(&mut self) -> Result<Vec<Rejection>>;
pub fn record_status(&mut self, key: &RecordKey) -> Result<Value>;         // {"pending":[{ordinal,name,phase,prerequisites}],"rejections":[detail]}
```
- Produces (`Engine`): `settle()`, `settle_push(push)`, `remove_rejected(&[Rejection])`, `encode_push(push) -> Result<Vec<u8>>`.

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/push.rs` with the shared helpers from `client.rs` plus:

```rust
fn receipt(channel: &str, cursor: u64) -> PushReceipt {
    PushReceipt { required_channel: channel.into(), required_cursor: cursor, required_checkpoints: vec![ChannelCheckpoint { channel: channel.into(), cursor }], rejections: vec![] }
}

#[test]
fn offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("client.sqlite");
    let mut c = open(&path);
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    let bytes = c.freeze().unwrap().unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "B");
    drop(c);
    let mut c = open(&path);
    assert_eq!(c.freeze().unwrap().unwrap(), bytes, "re-encoded from rows, byte for byte");
    c.acknowledge(1, receipt("book", 2)).unwrap();
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(table_count(&mut c, "otter_push_checkpoint"), 1);
    c.apply_page(page("book", 1, 2, Some("NORMALIZED"))).unwrap();
    assert_eq!(c.pending_count().unwrap(), 0);
    assert_eq!(table_count(&mut c, "otter_push_checkpoint"), 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "NORMALIZED");
    assert_eq!(c.before_image_count().unwrap(), 0);
}

#[test]
fn pull_before_ack_and_later_local_edit_replay_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    c.freeze().unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("C"))?; Ok(()) }).unwrap();
    c.apply_page(page("book", 1, 2, Some("B"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
    c.acknowledge(1, receipt("book", 2)).unwrap();
    assert_eq!(c.pending_count().unwrap(), 1);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "C");
}

#[test]
fn rejection_removes_optimism_preserves_direct_truth_and_has_durable_inbox() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; tx.direct(Operation { values: Some(json!({"note":"local"})), ..update("unused") }) }).unwrap();
    c.freeze().unwrap();
    let mut ack = receipt("book", 1);
    ack.rejections.push(Rejection { ordinal: 1, code: "denied".into() });
    c.acknowledge(1, ack).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap(), json!({"id":"e","text":"A","note":"local"}));
    assert_eq!(table_count(&mut c, "otter_push_checkpoint"), 0, "all rejected settles at once");
    drop(c);
    let mut c = open(&path);
    assert_eq!(c.rejections().unwrap().len(), 1);
    let status = c.record_status(&key()).unwrap();
    assert_eq!(status["rejections"][0]["mutation"]["name"], "Edit");
    assert_eq!(status["rejections"][0]["code"], "denied");
    c.dismiss_rejection(1).unwrap();
    assert!(c.rejections().unwrap().is_empty());
}

#[test]
fn accepted_batches_only_settle_in_ready_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    c.freeze().unwrap();
    c.acknowledge(1, receipt("slow", 9)).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("C"))?; Ok(()) }).unwrap();
    c.freeze().unwrap();
    c.acknowledge(2, receipt("book", 1)).unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);
    c.apply_page(PullPage { channel: "slow".into(), from_cursor: 0, to_cursor: 9, changes: vec![] }).unwrap();
    assert_eq!(c.pending_count().unwrap(), 0);
}

#[test]
fn failed_prerequisite_stays_optimistic_independent_work_can_overtake() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { let mut m = mutation("B"); m.prerequisites.push("upload:1".into()); tx.enqueue(m)?; tx.enqueue(mutation("C"))?; Ok(()) }).unwrap();
    let request = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(request.mutations.len(), 1);
    assert_eq!(request.mutations[0].ordinal, 2);
    c.set_readiness("upload:1", Readiness::Failed).unwrap();
    assert_eq!(c.pending_count().unwrap(), 2);
    assert_eq!(c.pending_tasks().unwrap()[0]["state"], "failed");
    c.set_readiness("upload:1", Readiness::Ready).unwrap();
    assert!(c.pending_tasks().unwrap().is_empty());
}

#[test]
fn lifecycle_dependency_waits_for_parent_ack_but_sequence_can_share_batch() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { let parent = tx.enqueue(mutation("B"))?; let mut child = mutation("C"); child.lifecycle_dependencies.push(parent); tx.enqueue(child)?; Ok(()) }).unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations.len(), 1);
    c.acknowledge(1, receipt("book", 9)).unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations[0].ordinal, 2);
}

#[test]
fn accepted_wire_rows_do_not_promote_companion_over_server_authority() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { let mut m = mutation("B"); m.companion.push(update("COMPANION")); tx.enqueue(m)?; Ok(()) }).unwrap();
    c.freeze().unwrap();
    c.acknowledge(1, receipt("book", 2)).unwrap();
    c.apply_page(page("book", 1, 2, Some("SERVER"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "SERVER");
}

#[test]
fn schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut value = serde_json::to_value(schema()).unwrap();
    value["requirements"] = json!([{"model":"Entry","field":"note","name":"Upload","arguments":{"key":"self"}}]);
    value["prerequisites"] = json!([{"name":"Upload","fields":[{"name":"key","type":"String"}]}]);
    let schema = Schema::from_value(value).unwrap();
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), schema.clone()).unwrap();
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(Mutation::new("Edit", vec![Operation { values: Some(json!({"note":"asset"})), ..update("x") }]))?; Ok(()) }).unwrap();
    assert!(c.freeze().unwrap().is_none());
    let tasks = c.pending_tasks().unwrap();
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0]["arguments"], json!({"key":"asset"}));
    let key = tasks[0]["key"].as_str().unwrap().to_string();
    drop(c);
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), schema).unwrap();
    assert_eq!(c.pending_tasks().unwrap().len(), 1);
    c.set_readiness(&key, Readiness::Ready).unwrap();
    assert!(c.freeze().unwrap().is_some());
}

#[test]
fn byte_budget_skips_large_candidate_but_always_allows_one() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("small"))?; tx.enqueue(mutation(&"x".repeat(2000)))?; tx.enqueue(mutation("third"))?; Ok(()) }).unwrap();
    let first = PushRequest::decode(&c.freeze_with_limit(600).unwrap().unwrap()).unwrap();
    assert_eq!(first.mutations.iter().map(|m| m.ordinal).collect::<Vec<_>>(), vec![1, 3]);
    c.acknowledge(1, receipt("book", 1)).unwrap();
    let second = PushRequest::decode(&c.freeze_with_limit(1).unwrap().unwrap()).unwrap();
    assert_eq!(second.mutations[0].ordinal, 2);
}

#[test]
fn schema_sequence_relationship_blocks_dependent_but_not_independent_work() {
    let dir = tempfile::tempdir().unwrap();
    let mut value = serde_json::to_value(family_schema()).unwrap();
    value["clientPolicies"] = json!([
    {"name":"Rename","version":1,"slots":[{"name":"book","model":"Book","operation":"update","cardinality":"single"}]},
    {"name":"CommentEdit","version":1,"slots":[{"name":"comment","model":"Comment","operation":"update","cardinality":"single"}],"sequence":{"after":[{"name":"Rename","arguments":{"book":"comment.book"}}]}}
    ]);
    let mut c = Client::open(SqliteStore::open(dir.path().join("db")).unwrap(), Schema::from_value(value).unwrap()).unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"B"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"C"})))?;
        let mut m = Mutation::new("Rename", vec![Operation { model: "Book".into(), op: OperationKind::Update, identity: json!({"id":"b"}), values: Some(json!({"title":"D"})) }]);
        m.prerequisites.push("pending".into());
        tx.enqueue(m)?;
        tx.enqueue(Mutation::new("CommentEdit", vec![Operation { model: "Comment".into(), op: OperationKind::Update, identity: json!({"id":"c"}), values: Some(json!({"text":"E"})) }]))?;
        Ok(())
    }).unwrap();
    assert!(c.freeze().unwrap().is_none());
    c.set_readiness("pending", Readiness::Ready).unwrap();
    let batch = PushRequest::decode(&c.freeze().unwrap().unwrap()).unwrap();
    assert_eq!(batch.mutations.len(), 2);
}

#[test]
fn accepted_companion_cascade_does_not_resurrect_descendants() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), family_schema()).unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"B"})))?;
        tx.direct(create("Book", "other", json!({"title":"Other"})))?;
        tx.direct(create("Comment", "c", json!({"bookId":"b","text":"C"})))?;
        let mut m = Mutation::new("Edit", vec![Operation { model: "Book".into(), identity: json!({"id":"other"}), op: OperationKind::Update, values: Some(json!({"title":"New"})) }]);
        m.companion.push(Operation { model: "Book".into(), identity: json!({"id":"b"}), op: OperationKind::Delete, values: None });
        tx.enqueue(m)?;
        Ok(())
    }).unwrap();
    c.freeze().unwrap();
    c.acknowledge(1, receipt("book", 0)).unwrap();
    drop(c);
    let mut c = Client::open(SqliteStore::open(&path).unwrap(), family_schema()).unwrap();
    assert!(c.query("Comment", &json!({})).unwrap().is_empty());
}

#[test]
fn late_task_completion_does_not_resurrect_unused_readiness() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    let ordinal = c.transaction(|tx| { let mut m = mutation("B"); m.prerequisites.push("upload".into()); tx.enqueue(m) }).unwrap();
    c.drop_mutation(ordinal).unwrap();
    c.set_readiness("upload", Readiness::Ready).unwrap();
    assert!(c.pending_tasks().unwrap().is_empty());
    assert_eq!(table_count(&mut c, "otter_mutation_prerequisite"), 0);
}

#[test]
fn record_status_reports_phases_and_duplicate_ack_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| tx.enqueue(mutation("B"))).unwrap();
    assert_eq!(c.record_status(&key()).unwrap()["pending"][0]["phase"], "queued");
    c.freeze().unwrap();
    assert_eq!(c.record_status(&key()).unwrap()["pending"][0]["phase"], "frozen");
    c.acknowledge(1, receipt("book", 5)).unwrap();
    assert_eq!(c.record_status(&key()).unwrap()["pending"][0]["phase"], "accepted");
    c.acknowledge(1, receipt("book", 5)).unwrap();
    assert!(c.acknowledge(1, receipt("book", 6)).is_err(), "a different receipt for the same push is refused");
    assert!(c.acknowledge(7, receipt("book", 1)).is_err(), "unknown push");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test push`
Expected: FAIL (`freeze`/`acknowledge` stubs).

- [ ] **Step 3: Write `push.rs`**

```rust
//! Freeze pushes from queued rows, record receipts, settle the accepted prefix.
use crate::engine::Engine;
use crate::queue::Queued;
use crate::store::ClientStore;
use crate::{Client, Mutation, Operation, OperationKind, Readiness, mutate::apply_to_row};
use otter_core::{PushReceipt, PushRequest, RecordKey, Rejection, Result, canonical_json, invalid};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

const MAX_MUTATIONS: usize = 20;

fn keys_of<'a>(schema: &otter_core::Schema, ops: impl Iterator<Item = &'a Operation>) -> Result<BTreeSet<String>> {
    ops.map(|op| schema.record_key(&op.model, &op.identity)?.encoded()).collect()
}
fn all_ops(m: &Mutation) -> impl Iterator<Item = &Operation> {
    m.operations.iter().chain(&m.companion).chain(&m.effects)
}

impl<S: ClientStore> Engine<'_, S> {
    fn client_id(&mut self) -> Result<String> {
        Ok(self.scalar("SELECT client_id FROM otter_client", &[])?.and_then(|v| v.as_str().map(str::to_owned)).unwrap_or_default())
    }
    fn request_json(&mut self, push: u64, mutations: &[Queued]) -> Result<Value> {
        let acts: Vec<Value> = mutations
            .iter()
            .map(|q| json!({"ordinal":q.ordinal,"name":q.mutation.name,"version":q.mutation.version,"operations":q.mutation.operations}))
            .collect();
        Ok(json!({"clientId":self.client_id()?,"batchSequence":push,"mutations":acts}))
    }
    pub fn encode_push(&mut self, push: u64) -> Result<Vec<u8>> {
        let mutations: Vec<Queued> = self.queued()?.into_iter().filter(|q| q.push == Some(push)).collect();
        let request = self.request_json(push, &mutations)?;
        PushRequest::decode(canonical_json(&request)?.as_bytes())?.encode()
    }
    /// The push that was sent and not yet acknowledged, if any.
    fn in_flight(&mut self) -> Result<Option<u64>> {
        for push in self.pushes()? {
            if self.checkpoints(push)?.is_empty() {
                return Ok(Some(push));
            }
        }
        Ok(None)
    }
    pub fn freeze(&mut self, max_bytes: usize) -> Result<Option<Vec<u8>>> {
        if max_bytes == 0 {
            return Ok(None);
        }
        if let Some(push) = self.in_flight()? {
            return Ok(Some(self.encode_push(push)?));
        }
        let queue = self.queued()?;
        let blocked_keys: BTreeSet<String> = self.prerequisite_keys()?.into_iter().map(|(k, _)| k).collect();
        let unsent: BTreeSet<u64> = queue.iter().filter(|q| q.push.is_none()).map(|q| q.ordinal).collect();
        let mut selected: Vec<Queued> = vec![];
        let mut chosen = BTreeSet::new();
        let next_push = self.scalar("SELECT next_push FROM otter_client", &[])?.map(|v| crate::engine::as_u64(&v)).transpose()?.unwrap_or(1);
        for q in queue.iter().filter(|q| q.push.is_none()) {
            if q.mutation.prerequisites.iter().any(|k| blocked_keys.contains(k)) {
                continue;
            }
            let blocked = q.mutation.lifecycle_dependencies.iter().any(|d| unsent.contains(d))
                || q.mutation.sequence_dependencies.iter().any(|d| unsent.contains(d) && !chosen.contains(d));
            if blocked {
                continue;
            }
            if !selected.is_empty() {
                let mut candidate = selected.clone();
                candidate.push(q.clone());
                if canonical_json(&self.request_json(next_push, &candidate)?)?.len() > max_bytes {
                    continue;
                }
            }
            chosen.insert(q.ordinal);
            selected.push(q.clone());
            if selected.len() == MAX_MUTATIONS {
                break;
            }
        }
        if selected.is_empty() {
            return Ok(None);
        }
        let push = self.allocate_push()?;
        let ordinals: Vec<u64> = selected.iter().map(|q| q.ordinal).collect();
        self.assign_push(&ordinals, push)?;
        Ok(Some(self.encode_push(push)?))
    }
    pub fn acknowledge(&mut self, push: u64, receipt: &PushReceipt) -> Result<()> {
        let mutations: Vec<Queued> = self.queued()?.into_iter().filter(|q| q.push == Some(push)).collect();
        let existing = self.checkpoints(push)?;
        if !existing.is_empty() {
            let mut incoming = receipt.required_checkpoints.clone();
            incoming.sort_by(|a, b| a.channel.cmp(&b.channel));
            if incoming != existing {
                return Err(invalid("receipt changed"));
            }
            return Ok(());
        }
        if mutations.is_empty() {
            return Err(invalid("unknown batch receipt"));
        }
        let ordinals: BTreeSet<u64> = mutations.iter().map(|q| q.ordinal).collect();
        if receipt.rejections.iter().any(|r| !ordinals.contains(&r.ordinal)) {
            return Err(invalid("rejection ordinal not in batch"));
        }
        self.remove_rejected(&receipt.rejections)?;
        let remaining = self.queued()?.into_iter().any(|q| q.push == Some(push));
        if receipt.required_checkpoints.is_empty() || !remaining {
            if remaining {
                self.settle_push(push)?;
            }
            return Ok(());
        }
        self.insert_checkpoints(push, &receipt.required_checkpoints)?;
        self.settle()
    }
    pub fn settle(&mut self) -> Result<()> {
        loop {
            let Some(push) = self.pushes()?.into_iter().next() else { return Ok(()) };
            let checkpoints = self.checkpoints(push)?;
            if checkpoints.is_empty() {
                return Ok(()); // in flight; nothing later may settle first
            }
            for cp in &checkpoints {
                if self.cursor(&cp.channel)?.unwrap_or(0) < cp.cursor {
                    return Ok(());
                }
            }
            self.settle_push(push)?;
        }
    }
    pub fn settle_push(&mut self, push: u64) -> Result<()> {
        let schema = self.schema;
        let mutations: Vec<Queued> = self.queued()?.into_iter().filter(|q| q.push == Some(push)).collect();
        let mut wire_rows = BTreeSet::new();
        let mut affected: BTreeMap<String, RecordKey> = BTreeMap::new();
        for q in &mutations {
            wire_rows.extend(keys_of(schema, q.mutation.operations.iter())?);
            for op in all_ops(&q.mutation) {
                let key = schema.record_key(&op.model, &op.identity)?;
                affected.insert(key.encoded()?, key);
            }
        }
        for q in &mutations {
            let mut local_ops = q.mutation.companion.clone();
            for op in &q.mutation.companion {
                if op.op == OperationKind::Delete {
                    let key = schema.record_key(&op.model, &op.identity)?;
                    if !wire_rows.contains(&key.encoded()?) {
                        for child in self.descendants(&key)? {
                            local_ops.push(Operation { model: child.model, identity: child.identity, op: OperationKind::Delete, values: None });
                        }
                    }
                }
            }
            for op in &local_ops {
                let key = schema.record_key(&op.model, &op.identity)?;
                if wire_rows.contains(&key.encoded()?) {
                    continue;
                }
                let mut truth = self.truth_before(&key)?;
                if apply_to_row(&mut truth, op).is_ok() {
                    self.write_before(&key, truth.as_ref())?;
                }
                affected.insert(key.encoded()?, key);
            }
        }
        let ordinals: Vec<u64> = mutations.iter().map(|q| q.ordinal).collect();
        self.delete_mutations(&ordinals)?;
        self.delete_checkpoints(push)?;
        for key in affected.values() {
            self.rebuild(key)?;
        }
        Ok(())
    }
    pub fn remove_rejected(&mut self, rejections: &[Rejection]) -> Result<()> {
        let schema = self.schema;
        let queue = self.queued()?;
        let mut rejected: BTreeMap<u64, String> = rejections.iter().map(|r| (r.ordinal, r.code.clone())).collect();
        loop {
            let more: Vec<u64> = queue
                .iter()
                .filter(|q| !rejected.contains_key(&q.ordinal) && q.mutation.lifecycle_dependencies.iter().any(|d| rejected.contains_key(d)))
                .map(|q| q.ordinal)
                .collect();
            if more.is_empty() {
                break;
            }
            for id in more {
                rejected.insert(id, "dependency.rejected".into());
            }
        }
        let mut affected: BTreeMap<String, RecordKey> = BTreeMap::new();
        for q in queue.iter().filter(|q| rejected.contains_key(&q.ordinal)) {
            let code = &rejected[&q.ordinal];
            for op in all_ops(&q.mutation) {
                let key = schema.record_key(&op.model, &op.identity)?;
                affected.insert(key.encoded()?, key);
            }
            let records: Vec<Value> = all_ops(&q.mutation).map(|op| json!({"model":op.model,"identity":op.identity})).collect();
            let detail = json!({"ordinal":q.ordinal,"code":code,"mutation":q.mutation,"records":records});
            self.insert_rejection(q.ordinal, &q.mutation.name, code, &detail)?;
        }
        let ordinals: Vec<u64> = rejected.keys().copied().collect();
        self.delete_mutations(&ordinals)?;
        for key in affected.values() {
            self.rebuild(key)?;
        }
        Ok(())
    }
}
```

`truth_before` and `write_before` are the `before_get` / `before_set` helpers from `mutate.rs`; make those two `pub(crate)` and use their names directly instead of the aliases above.

Then the `Client` methods in `lib.rs`:

```rust
impl<S: ClientStore> Client<S> {
    pub fn freeze(&mut self) -> Result<Option<Vec<u8>>> {
        self.freeze_with_limit(256 * 1024)
    }
    pub fn freeze_with_limit(&mut self, max_bytes: usize) -> Result<Option<Vec<u8>>> {
        self.write(|e| e.freeze(max_bytes))
    }
    pub fn acknowledge(&mut self, sequence: u64, receipt: PushReceipt) -> Result<()> {
        let receipt = PushReceipt::decode(&receipt.encode()?)?;
        self.write(|e| e.acknowledge(sequence, &receipt))
    }
    pub fn set_readiness(&mut self, key: &str, value: Readiness) -> Result<()> {
        self.write(|e| {
            match value {
                Readiness::Ready => e.resolve_prerequisite(key)?,
                Readiness::Failed => e.fail_prerequisite(key, "failed")?,
                Readiness::Pending => e.reset_prerequisite(key)?,
            };
            Ok(())
        })
    }
    pub fn pending_tasks(&mut self) -> Result<Vec<Value>> {
        self.view(|e| {
            Ok(e.prerequisite_keys()?
                .into_iter()
                .map(|(key, error)| {
                    let mut value = serde_json::from_str::<Value>(&key).ok().filter(Value::is_object).unwrap_or_else(|| json!({}));
                    value["key"] = json!(key);
                    value["state"] = json!(if error.is_some() { "failed" } else { "pending" });
                    value
                })
                .collect())
        })
    }
    pub fn dismiss_rejection(&mut self, ordinal: u64) -> Result<()> {
        self.write(|e| e.delete_rejection(ordinal))
    }
    pub fn drop_mutation(&mut self, ordinal: u64) -> Result<()> {
        self.write(|e| {
            match e.queued_one(ordinal)? {
                None => return Ok(()),
                Some(q) if q.push.is_some() => return Err(invalid("cannot drop a sent mutation with unknown/accepted outcome")),
                Some(_) => {}
            }
            e.remove_rejected(&[Rejection { ordinal, code: "dropped".into() }])
        })
    }
    pub fn rejections(&mut self) -> Result<Vec<Rejection>> {
        self.view(|e| e.rejections())
    }
    pub fn record_status(&mut self, key: &RecordKey) -> Result<Value> {
        let key = self.schema.record_key(&key.model, &key.identity)?;
        self.view(|e| {
            let prerequisites: BTreeMap<String, Option<String>> = e.prerequisite_keys()?.into_iter().collect();
            let mut pending = vec![];
            for q in e.queued()? {
                let touches = q.mutation.operations.iter().chain(&q.mutation.companion).chain(&q.mutation.effects).any(|op| op.model == key.model && op.identity == key.identity);
                if !touches {
                    continue;
                }
                let phase = match q.push {
                    None => "queued",
                    Some(push) if e.checkpoints(push)?.is_empty() => "frozen",
                    Some(_) => "accepted",
                };
                let prerequisites: Vec<Value> = q.mutation.prerequisites.iter().map(|k| json!({"key":k,"state":match prerequisites.get(k) { None => "ready", Some(Some(_)) => "failed", Some(None) => "pending" }})).collect();
                pending.push(json!({"ordinal":q.ordinal,"name":q.mutation.name,"phase":phase,"prerequisites":prerequisites}));
            }
            let rejections: Vec<Value> = e.rejection_details()?.into_iter().filter(|d| d["records"].as_array().is_some_and(|r| r.iter().any(|x| x["model"] == key.model && x["identity"] == key.identity))).collect();
            Ok(json!({"pending":pending,"rejections":rejections}))
        })
    }
}
```

- [ ] **Step 4: Run the push tests and the whole sqlite crate**

Run: `cargo test -p otter-sqlite --locked`
Expected: PASS for `push`, `downlink`, `client` (all of them now), `engine`, `ddl`, `store`, except the query-related tests in `client.rs` that Task 9 completes (`query_normalizes...` is in Task 9's file, so `client.rs` should be fully green).

- [ ] **Step 5: Commit**

Stage `crates/client/src` and `crates/sqlite/tests/push.rs`; commit as `feat(client): freeze pushes from rows, settle accepted prefix, durable rejections`.

---

### Task 9: Queries over tables, read-only SQL, transport

**Files:**
- Rewrite: `crates/client/src/query.rs`
- Modify: `crates/client/src/lib.rs` (`Client::query_spec`, `related`, `referencing`; `ClientTransaction::query`, `query_spec`, `related`, `referencing`)
- Rewrite: `crates/client/src/transport.rs` `SyncCycle::next`
- Test: `crates/sqlite/tests/query.rs`

**Interfaces:**
- Produces (`query.rs`): `QuerySpec`, `QueryOrder`, `Direction` unchanged; `pub fn evaluate<S>(engine: &mut Engine<'_, S>, model: &str, spec: &QuerySpec) -> Result<Vec<Value>>`, `pub fn related<S>(engine, key: &RecordKey, name: &str) -> Result<Option<Value>>`, `pub fn referencing<S>(engine, key: &RecordKey, source: &str, name: &str) -> Result<Vec<Value>>`, `pub(crate) fn rows_to_objects(rows: SqlRows) -> Result<Vec<Value>>`.
- `Client::query(model, filter)`, `query_spec(model, spec)`, `related(key, name)`, `referencing(key, source, name)`, `read_sql(sql, params)`, `session_sql(sql, params)`; the same four query methods on `ClientTransaction`.

- [ ] **Step 1: Write the failing tests**

Create `crates/sqlite/tests/query.rs` with the shared helpers plus:

```rust
#[test]
fn query_normalizes_filters_orders_nulls_and_resolves_relationships() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = Client::open(SqliteStore::open(dir.path().join("db")).unwrap(), family_schema()).unwrap();
    c.transaction(|tx| {
        tx.direct(create("Book", "b", json!({"title":"Book"})))?;
        for (id, text) in [("c1", "Z"), ("c2", "A"), ("c3", "A")] {
            tx.direct(create("Comment", id, json!({"bookId":if id=="c3"{"other"}else{"b"},"text":text})))?;
        }
        Ok(())
    }).unwrap();
    let spec: QuerySpec = serde_json::from_value(json!({"orderBy":[{"field":"text","direction":"ascending"}],"limit":2})).unwrap();
    let rows = c.query_spec("Comment", &spec).unwrap();
    assert_eq!(rows.iter().map(|r| r["id"].as_str().unwrap()).collect::<Vec<_>>(), vec!["c2", "c3"]);
    let key = family_schema().record_key("Comment", &json!({"id":"c1"})).unwrap();
    assert_eq!(c.related(&key, "book").unwrap().unwrap()["id"], "b");
    let book = family_schema().record_key("Book", &json!({"id":"b"})).unwrap();
    assert_eq!(c.referencing(&book, "Comment", "book").unwrap().len(), 2);
    assert!(c.query("Comment", &json!({"missing":1})).is_err());
    assert_eq!(c.query("Comment", &json!({"bookId":"b"})).unwrap().len(), 2);
    c.transaction(|tx| {
        assert_eq!(tx.query("Comment", &json!({}))?.len(), 3);
        tx.direct(create("Comment", "c4", json!({"bookId":"b","text":"Q"})))?;
        assert_eq!(tx.query("Comment", &json!({}))?.len(), 4, "reads inside the transaction see its writes");
        Ok(())
    }).unwrap();
}

#[test]
fn readonly_sql_sees_optimistic_rows_and_refuses_write_statements() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.apply_page(page("book", 0, 1, Some("A"))).unwrap();
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    assert_eq!(c.read_sql("SELECT id,text FROM Entry WHERE id=?", &[json!("e")]).unwrap(), vec![json!({"id":"e","text":"B"})]);
    assert!(c.read_sql("DELETE FROM Entry RETURNING id", &[]).is_err());
    assert!(c.read_sql("PRAGMA user_version=10", &[]).is_err());
    assert!(c.read_sql("SELECT id, id FROM Entry", &[]).is_err(), "duplicate column names need aliases");
    c.begin_session().unwrap();
    c.session(|tx| tx.direct(update("C"))).unwrap();
    assert_eq!(c.session_sql("SELECT text FROM Entry", &[]).unwrap(), vec![json!({"text":"C"})]);
    assert_eq!(c.read_sql("SELECT text FROM Entry", &[]).unwrap(), vec![json!({"text":"B"})]);
    c.rollback_session().unwrap();
}

#[test]
fn transport_pulls_subscribed_and_checkpoint_channels_after_pushing() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    c.transaction(|tx| tx.set_channel("book".into(), true)).unwrap();
    seed(&mut c, "A");
    c.transaction(|tx| { tx.enqueue(mutation("B"))?; Ok(()) }).unwrap();
    let mut cycle = SyncCycle::default();
    let push = cycle.next(&mut c).unwrap().unwrap();
    assert_eq!(push.kind, "push");
    let receipt = PushReceipt { required_channel: "other".into(), required_cursor: 3, required_checkpoints: vec![ChannelCheckpoint { channel: "other".into(), cursor: 3 }], rejections: vec![] };
    cycle.complete(&mut c, &receipt.encode().unwrap()).unwrap();
    let first = cycle.next(&mut c).unwrap().unwrap();
    assert_eq!(first.kind, "pull");
    let request = PullRequest::decode(first.body.as_bytes()).unwrap();
    assert_eq!(request.channel, "book");
    cycle.complete(&mut c, &PullPage { channel: "book".into(), from_cursor: 0, to_cursor: 0, changes: vec![] }.encode().unwrap()).unwrap();
    let second = PullRequest::decode(cycle.next(&mut c).unwrap().unwrap().body.as_bytes()).unwrap();
    assert_eq!(second.channel, "other", "checkpoint channels are pulled even when not subscribed");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p otter-sqlite --locked --test query`
Expected: FAIL (`query_spec`, `related`, `referencing` missing; transport uses removed API).

- [ ] **Step 3: Rewrite `query.rs`**

```rust
//! Filters run in SQL; ordering keeps the reference comparison rules (nulls first, UTF-16 order).
use crate::engine::Engine;
use crate::store::{ClientStore, SqlRows};
use otter_core::{RecordKey, Result, ValueType, invalid};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuerySpec {
    #[serde(default)]
    pub filter: BTreeMap<String, Value>,
    #[serde(default)]
    pub order_by: Vec<QueryOrder>,
    pub limit: Option<usize>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct QueryOrder {
    pub field: String,
    pub direction: Direction,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Direction {
    Ascending,
    Descending,
}
fn compare(a: &Value, b: &Value) -> Ordering {
    match (a, b) {
        (Value::Null, Value::Null) => Ordering::Equal,
        (Value::Null, _) => Ordering::Less,
        (_, Value::Null) => Ordering::Greater,
        (Value::String(a), Value::String(b)) => a.encode_utf16().cmp(b.encode_utf16()),
        (Value::Bool(a), Value::Bool(b)) => a.cmp(b),
        (Value::Number(a), Value::Number(b)) => a.as_f64().unwrap().total_cmp(&b.as_f64().unwrap()),
        _ => Ordering::Equal,
    }
}
pub(crate) fn rows_to_objects(rows: SqlRows) -> Result<Vec<Value>> {
    if rows.columns.iter().collect::<BTreeSet<_>>().len() != rows.columns.len() {
        return Err(invalid("SQL result column names must be unique; use aliases"));
    }
    Ok(rows.rows.into_iter().map(|row| Value::Object(rows.columns.iter().cloned().zip(row).collect())).collect())
}
pub fn evaluate<S: ClientStore>(engine: &mut Engine<'_, S>, model: &str, spec: &QuerySpec) -> Result<Vec<Value>> {
    let schema = engine.schema;
    let model = schema.model(model)?.clone();
    let field = |name: &str| model.fields.iter().find(|f| f.name == name).ok_or_else(|| invalid(format!("unknown query field {name}")));
    let mut filter = vec![];
    for (name, value) in &spec.filter {
        let field = field(name)?;
        if matches!(field.value_type, ValueType::List { .. }) {
            return Err(invalid("list predicates unsupported"));
        }
        filter.push((name.clone(), schema.normalize_value(field, value)?));
    }
    for order in &spec.order_by {
        if !matches!(field(&order.field)?.value_type, ValueType::Scalar { .. }) {
            return Err(invalid("ordering requires scalar field"));
        }
    }
    let mut rows = engine.rows_where(&model.name, &model, &filter)?;
    rows.sort_by(|a, b| {
        for order in &spec.order_by {
            let cmp = compare(&a[&order.field], &b[&order.field]);
            let cmp = match order.direction {
                Direction::Ascending => cmp,
                Direction::Descending => cmp.reverse(),
            };
            if cmp != Ordering::Equal {
                return cmp;
            }
        }
        for field in &model.identity {
            let cmp = compare(&a[field], &b[field]);
            if cmp != Ordering::Equal {
                return cmp;
            }
        }
        Ordering::Equal
    });
    if let Some(limit) = spec.limit {
        rows.truncate(limit);
    }
    Ok(rows)
}
pub fn related<S: ClientStore>(engine: &mut Engine<'_, S>, key: &RecordKey, name: &str) -> Result<Option<Value>> {
    let schema = engine.schema;
    let key = schema.record_key(&key.model, &key.identity)?;
    let relation = schema.model(&key.model)?.relations.iter().find(|r| r.name == name).ok_or_else(|| invalid("unknown relation"))?.clone();
    let Some(row) = engine.read_row(&key)? else { return Ok(None) };
    let mut identity = serde_json::Map::new();
    for (local, target) in relation.fields.iter().zip(&relation.target_fields) {
        if row[local].is_null() {
            return Ok(None);
        }
        identity.insert(target.clone(), row[local].clone());
    }
    engine.read_row(&schema.record_key(&relation.target, &Value::Object(identity))?)
}
pub fn referencing<S: ClientStore>(engine: &mut Engine<'_, S>, key: &RecordKey, source: &str, name: &str) -> Result<Vec<Value>> {
    let schema = engine.schema;
    let key = schema.record_key(&key.model, &key.identity)?;
    let relation = schema.model(source)?.relations.iter().find(|r| r.name == name && r.target == key.model).ok_or_else(|| invalid("unknown inverse relation"))?.clone();
    let filter = relation.fields.iter().zip(&relation.target_fields).map(|(local, target)| (local.clone(), key.identity[target].clone())).collect();
    evaluate(engine, source, &QuerySpec { filter, ..Default::default() })
}
```

Add to `Client` in `lib.rs`:

```rust
    pub fn query_spec(&mut self, model: &str, spec: &QuerySpec) -> Result<Vec<Value>> {
        self.view(|e| query::evaluate(e, model, spec))
    }
    pub fn related(&mut self, key: &RecordKey, name: &str) -> Result<Option<Value>> {
        self.view(|e| query::related(e, key, name))
    }
    pub fn referencing(&mut self, key: &RecordKey, source: &str, name: &str) -> Result<Vec<Value>> {
        self.view(|e| query::referencing(e, key, source, name))
    }
```

and to `ClientTransaction`:

```rust
    pub fn query(&mut self, model: &str, filter: &Value) -> Result<Vec<Value>> {
        let filter: BTreeMap<String, Value> = serde_json::from_value(filter.clone())?;
        query::evaluate(&mut self.engine, model, &QuerySpec { filter, ..Default::default() })
    }
    pub fn query_spec(&mut self, model: &str, spec: &QuerySpec) -> Result<Vec<Value>> {
        query::evaluate(&mut self.engine, model, spec)
    }
    pub fn related(&mut self, key: &RecordKey, name: &str) -> Result<Option<Value>> {
        query::related(&mut self.engine, key, name)
    }
    pub fn referencing(&mut self, key: &RecordKey, source: &str, name: &str) -> Result<Vec<Value>> {
        query::referencing(&mut self.engine, key, source, name)
    }
```

- [ ] **Step 4: Rewrite `SyncCycle::next` in `transport.rs`**

Replace the body after the push branch:

```rust
        let mut channels = client.desired_channels()?;
        channels.extend(client.checkpoint_channels()?);
        if let Some(channel) = channels.iter().find(|c| !self.completed.contains(*c)) {
            let request = PullRequest { client_id: client.client_id().into(), channel: channel.clone(), from_cursor: client.cursor(channel)? };
            let action = TransportAction { kind: "pull".into(), body: String::from_utf8(request.encode()?).map_err(|_| invalid("utf8"))? };
            self.active = Some(action.clone());
            return Ok(Some(action));
        }
        Ok(None)
```

`complete` is unchanged.

- [ ] **Step 5: Run the whole sqlite crate**

Run: `cargo test -p otter-sqlite --locked && cargo clippy -p otter-client -p otter-sqlite --all-targets --locked -- -D warnings && cargo fmt --all --check`
Expected: PASS, no warnings.

- [ ] **Step 6: Commit**

Stage `crates/client/src` and `crates/sqlite/tests/query.rs`; commit as `feat(client): queries and read-only SQL run against the tables`.

---

### Task 10: Bindings, scenarios, cleanup, docs and the full gate

**Files:**
- Modify: `bindings/common/src/lib.rs`
- Modify: `bindings/common/tests/session.rs` (update `open` requests if they pass `owner`; they may keep passing it, it is ignored)
- Modify: `integration/rust/tests/scenarios.rs:99-100`
- Modify: `docs/architecture/code-organization.md` (section 5, "Client: a separate local storage contract"), `docs/architecture/compatibility-and-recovery.md` (Boundaries table rows "Existing local cache" and "Channel overlap", the Capacity paragraph), `docs/next-things.md` (tick the rewrite items that this closes; add none)
- Delete: any leftover `LegacyClientStore` references

**Interfaces:**
- Bindings responses gain `"changedTables": [..]` next to `"changed"`. `open` ignores `owner` and `migration`. New op `"watch"` is not added: the JS and Dart packages consume `changedTables` from every response in a follow-up; this task only exposes the data.

- [ ] **Step 1: Update the bindings host**

In `bindings/common/src/lib.rs`:

- `Entry` becomes `{ client: Client<SqliteStore>, cycle: SyncCycle, connection: ConnectionDriver }` (no `session`, no `savepoints`).
- `open`: `Client::open(SqliteStore::open(text(&request, "path")?)?, Schema::from_value(request["schema"].clone())?)?`.
- The `request["transaction"] == true && e.session.is_none()` guard becomes `!e.client.session_active()`.
- `begin` → `e.client.begin_session()?`; `commit` → `e.client.commit_session()?`; `rollback` → `e.client.rollback_session()?`; `savepoint` → `e.client.session_savepoint()?`; `release` → `e.client.session_release()?`; `rollbackSavepoint` → `e.client.session_rollback_savepoint()?`.
- Every `match &mut e.session { Some(s) => s.run(|tx| ...), None => e.client.X(...) }` becomes `if e.client.session_active() { e.client.session(|tx| ...)? } else { e.client.X(...)? }`. For `sql`: `if e.client.session_active() { e.client.session_sql(sql, parameters)? } else { e.client.read_sql(sql, parameters)? }`.
- The `_ =>` arm's `if e.session.is_some()` becomes `if e.client.session_active()`.
- `status`: `json!({"clientId":e.client.client_id(),"pending":e.client.pending_count()?,"beforeImages":e.client.before_image_count()?,"cursors":e.client.subscriptions()?.into_iter().collect::<BTreeMap<_,_>>(),"channels":e.client.desired_channels()?,"rejections":e.client.rejections()?})`.
- `tasks` → `json!(e.client.pending_tasks()?)`.
- Final response: `json!({"value":value,"changed":generation!=e.client.generation(),"changedTables":e.client.last_changed(),"generation":e.client.generation()})`.

- [ ] **Step 2: Update the Rust scenarios**

In `integration/rust/tests/scenarios.rs` change `open` to `Client::open(SqliteStore::open(path).unwrap(), schema()).unwrap()`, and `assert_eq!(client.pending_count(), 0, ...)` / `before_image_count()` to the `Result` forms with `.unwrap()`, `client.rejections().unwrap().len()`, `client.cursor("book").unwrap()` in `pull`.

- [ ] **Step 3: Build and test everything**

Run: `cargo fmt --all && cargo test --workspace --locked && cargo clippy --workspace --all-targets --locked -- -D warnings`
Expected: PASS, including the 64 interleavings in `integration/rust`.

- [ ] **Step 4: Update the documentation**

`docs/architecture/code-organization.md`, replace the paragraph under "Client: a separate local storage contract" with:

```markdown
`ClientStore` is a SQL executor: `begin`/`commit`/`rollback`, savepoints, `execute`, `query` on the writer connection and `query_committed` on a read-only connection. `otter-client` owns the schema of the local database: one table per model named as the model, `otter_before_<Model>` twins that hold server truth while a row has pending edits, and the `otter_` framework tables (`otter_client`, `otter_record`, `otter_claim`, `otter_subscription`, `otter_mutation` and its `_operation`, `_dependency`, `_prerequisite` children, `otter_push_checkpoint`, `otter_rejection`). The engine works row by row inside SQLite transactions; nothing is held in memory between calls. Every write transaction increments `otter_client.generation` with a `WHERE generation = ?` fence so a stale instance fails instead of overwriting.
```

`docs/architecture/compatibility-and-recovery.md`:

- Boundaries row "Existing local cache": `On open the client reconciles PRAGMA table_info against the schema: missing columns are added (non-nullable ones need a schema default), identity or storage-type changes refuse to open. Queued operation rows are never rewritten.`
- Boundaries row "Channel overlap": `Records carry an optional content stamp; a stamped change is applied only when newer than the local stamp. A delete applies across channels; the remaining claims are the channels whose copy of the delete has not arrived. Issue #8 makes the stamp mandatory.`
- Capacity paragraph: replace the sentence starting "The current SQLite adapter materializes" with `Reads, including raw SQL, run against the on-disk tables through a read-only connection; no query copies the record set.`
- Add under Application recovery: `- One database file per signed-in user. The client stores no owner; opening another user's file shows that user's cache and pushes with their client id.`

- [ ] **Step 5: Run the full gate**

Run: `bash scripts/test.sh`
Expected: green on this machine. If the Nest steps fail because `packages/nest` was removed by #5 on `main`, rebase this branch on `main` first.

- [ ] **Step 6: Commit**

Stage `bindings/common`, `integration/rust`, `docs`; commit as `feat(client): bindings on the row-based engine; document the table layout`.

- [ ] **Step 7: Open the pull request**

Title: `Client persistence: per-model SQLite tables (#9)`. Body: link the spec and the plan, list the server dedup change, and note the follow-ups: generated typed `watch` in the JS/Dart packages using `changedTables`, and issue #8 making `stamp` required.

---

## Self-review

**Spec coverage.** Naming → Task 4 and Task 2 (`otter_` rejection). Model and before tables, unique indexes, storage types → Task 4. `otter_record`/`otter_claim`/`otter_subscription` → Task 5, unsubscribe cleanup → Task 6. Mutation tables and prerequisites with `error` → Task 5, semantics → Task 8. `otter_push_checkpoint`, no push table, no stored request → Task 8. `otter_rejection`, `otter_client` with generation fence → Tasks 5 and 6. Reconciliation on open → Task 4. Store contract and transaction boundaries → Tasks 3, 6, 7, 8. Optimistic write, rebuild, cascade → Task 6. Downlink stamp rules and tombstones → Task 7. Push and settlement → Task 8. Server dedup by sequence → Task 1. Connections → Task 3. Change notification → Task 6 (`watch`), Task 10 (`changedTables` in bindings). Tests listed in the spec → each task's test file; the 64 interleavings → Task 10.

**Known deviations from the spec, deliberate.** The store contract is a SQL executor rather than a per-model method list; the per-model operations exist as `Engine` methods in `rows.rs`. Bindings expose `changedTables` instead of a `watch` op because the bindings are request/response; the JS/Dart packages build table-scoped watchers on top in the follow-up issue.

**Type consistency checked.** `Engine::new(store, schema, changed, committed)`; `cursor()` returns `Result<Option<u64>>` on `Engine` and `Result<u64>` on `Client`; `before_get`/`before_set` are `pub(crate)` in `mutate.rs` and used by `push.rs`; `Queued { ordinal, push, mutation }`; `ApplyReport { applied, skipped, stale, conflicts, diagnostics }`.
