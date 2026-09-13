# Record Stamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every record delivered by Pull carries a required per-record `stamp`, allocated by the server on each `notify`, so the client (already stamp-aware since #9) can discard stale cross-channel content.

**Architecture:** The server gains an `otter_record` table that allocates one stamp per `(model, identity)` per `notify` call and stores it on the `otter_invalidation` row; Pull copies the row's stamp into `RecordChange`. The wire field becomes required, and the client's transitional "unstamped" branches are deleted. The client apply rules themselves are already on `main` from #9 and are not rewritten.

**Tech Stack:** Rust (`crates/core`, `crates/server`, `crates/client`, `crates/sqlite`), TypeScript (`packages/persistence-prisma`, `packages/server`), PostgreSQL via Prisma raw SQL, `node --test`, `cargo test`.

**Spec:** `docs/superpowers/specs/2026-09-12-record-stamp-design.md`

## Global Constraints

- Counters (cursor, stamp) are JSON integers in the JavaScript safe range; stamp is additionally `> 0`. The Rust helper is `otter_core::read_counter(&value, positive)`; the SQL check is `CHECK(stamp > 0 AND stamp <= 9007199254740991)`.
- No migration path: `packages/persistence-prisma/migration.sql` is rewritten in place (source alpha).
- Wire field name is exactly `stamp`. Existing wire names (`scope`, `syncId`, `fromCursor`, `toCursor`) do not change.
- Push, receipts, checkpoints and settlement code are not touched.
- Every commit must pass `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` and `cargo test --workspace --locked`. Prettier must pass on `packages/**/*.mts`.
- Commit messages end with the attribution lines from the session (Co-Authored-By and Claude-Session).

## Running things

```bash
# from the worktree root
source scripts/env.sh                                   # toolchain paths
cargo test -p otter-server                              # Rust server unit tests
cargo test -p otter-core                                # protocol tests + fixtures
cargo test -p otter-sqlite                              # client behaviour tests (crates/sqlite/tests)
cargo test -p otter-integration --test scenarios        # integration/rust
bash integration/persistence/server/run.sh              # node + Postgres persistence suite (starts a temp cluster)
bash scripts/test.sh                                    # everything, run once at the end
```

If `integration/rust` has a different crate name, read `integration/rust/Cargo.toml` `[package] name` and substitute it.

---

### Task 1: Rust server reads stamps from persistence

**Files:**
- Modify: `crates/server/src/lib.rs` (`process_pull` around line 430, `publish` around line 506)
- Create: `crates/server/tests/stamp.rs`
- Modify: `integration/rust/tests/scenarios.rs:87` (test host `scan` row)

**Interfaces:**
- Consumes: `RecordChange.stamp: Option<u64>` (current shape, from #9).
- Produces: host `scan` rows must carry `stamp`; host `publish` must return `{ "cursor": n, "stamp": n }`. `process_pull` emits `RecordChange { stamp: Some(row.stamp) }`. Task 2 implements the persistence side; Task 3 makes the field non-optional.

- [ ] **Step 1: Write the failing tests**

Create `crates/server/tests/stamp.rs`:

```rust
//! Pull copies the invalidation row's stamp; publish accepts `{cursor, stamp}`.
use otter_server::{Config, Host};
use serde_json::{Value, json};
use std::{future::Future, pin::Pin, sync::Mutex, task::{Context, Poll, Waker}};

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
impl Host for Fixed {
    fn call(&self, r: Value) -> Pin<Box<dyn Future<Output = otter_server::Result<Value>> + Send + '_>> {
        Box::pin(async move {
            Ok(match r["op"].as_str().unwrap() {
                "authorize" => json!(true),
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
    otter_core::PullRequest { client_id: "c".into(), channel: "a".into(), from_cursor: 0 }
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
    let host = Fixed { scan: row(json!(7)), publish: Value::Null, published: Mutex::new(vec![]) };
    let text = run(otter_server::process_pull(&config(), "u", &pull_body(), &host)).unwrap();
    let page = otter_core::PullPage::decode(text.as_bytes()).unwrap();
    assert_eq!(page.changes[0].stamp, Some(7));
}

#[test]
fn pull_rejects_rows_without_a_positive_stamp() {
    for bad in [Value::Null, json!(0), json!(-1), json!(9007199254740992u64)] {
        let host = Fixed { scan: row(bad.clone()), publish: Value::Null, published: Mutex::new(vec![]) };
        let err = run(otter_server::process_pull(&config(), "u", &pull_body(), &host)).unwrap_err();
        assert!(err.contains("stamp"), "{bad}: {err}");
    }
}

#[test]
fn publish_requires_cursor_and_stamp_from_the_host() {
    let changes = json!([{"model":"Entry","identity":{"id":"e"}}]);
    let channels = json!(["a"]);
    let ok = Fixed { scan: json!([]), publish: json!({"cursor":3,"stamp":9}), published: Mutex::new(vec![]) };
    run(otter_server::publish(&config(), &changes, &channels, &ok)).unwrap();
    assert_eq!(ok.published.lock().unwrap().len(), 1);
    for bad in [json!(3), json!({"cursor":3}), json!({"cursor":3,"stamp":0})] {
        let host = Fixed { scan: json!([]), publish: bad.clone(), published: Mutex::new(vec![]) };
        let err = run(otter_server::publish(&config(), &changes, &channels, &host)).unwrap_err();
        assert!(!err.is_empty(), "{bad} must be rejected");
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p otter-server --test stamp`
Expected: `pull_copies_the_row_stamp_into_the_change` fails (`Some(7)` vs `None`); `pull_rejects_rows_without_a_positive_stamp` fails (no error); `publish_requires_cursor_and_stamp_from_the_host` fails on the `json!(3)` case being accepted.

- [ ] **Step 3: Implement in `crates/server/src/lib.rs`**

In `process_pull`, inside the `for row in rows` loop, after the `identityKey` check and before `groups.entry(...)`:

```rust
        let stamp = read_counter(&row["stamp"], true).map_err(|e| format!("invalid stamp: {e}"))?;
```

and change the pushed change to:

```rust
        changes.push(RecordChange {
            cursor,
            model: model.into(),
            identity: key.identity,
            stamp: Some(stamp),
            state: Value::Null,
        });
```

In `publish`, replace the two lines that call the host and read the counter with:

```rust
            let result = host.call(json!({"op":"publish","channel":channel,"model":key.model,"identity":key.identity,"identityKey":key.encoded_identity().map_err(err)?})).await?;
            read_counter(&result["cursor"], true).map_err(|e| format!("invalid publish cursor: {e}"))?;
            read_counter(&result["stamp"], true).map_err(|e| format!("invalid publish stamp: {e}"))?;
```

`read_counter(_, true)` already rejects null, zero, negative and out-of-range values; check its error text contains the word you assert on, or use the wrapping messages above.

- [ ] **Step 4: Update the integration test host**

In `integration/rust/tests/scenarios.rs` line 87, the `scan` row gains `"stamp":db.head`:

```rust
 "scan"=>if r["after"].as_u64().unwrap()<db.head{json!([{"channel":"book","cursor":db.head,"model":"Entry","identity":{"id":"e"},"identityKey":"{\"id\":\"e\"}","stamp":db.head}])}else{json!([])},
```

`db.head` increases on every accepted edit, so it is a valid monotonic stamp for the single record in that test.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cargo test -p otter-server --test stamp && cargo test --workspace --locked`
Expected: all pass. The scenarios test still passes because the client accepts `Some(stamp)` pages.

- [ ] **Step 6: Format, lint, commit**

```bash
cargo fmt --all
cargo clippy --workspace --all-targets --locked -- -D warnings
git add crates/server integration/rust/tests/scenarios.rs
git commit -m "feat(server): pull delivers the invalidation row's stamp; publish returns {cursor, stamp}"
```

Note: after this commit the node persistence suite (`integration/persistence/server`) is red until Task 2, because the Prisma adapter still returns a bare cursor. Do Task 2 immediately after.

---

### Task 2: Prisma persistence allocates stamps

**Files:**
- Modify: `packages/persistence-prisma/migration.sql`
- Modify: `packages/persistence-prisma/index.mts` (`scan` and `publish` cases)
- Modify: `packages/persistence-prisma/README.md`
- Modify: `integration/persistence/server/runtime.test.mjs` (line 61 assertion, plus new tests)

**Interfaces:**
- Consumes: Task 1's expectation that `publish` returns `{ cursor, stamp }` and `scan` rows carry `stamp`.
- Produces: tables `otter_record(model, identity_key, stamp)` and `otter_invalidation.stamp`.

- [ ] **Step 1: Write the failing tests**

In `integration/persistence/server/runtime.test.mjs`, change the assertion on line 61 (`push commits business + compacted publication ...`) so the page includes the stamp:

```js
 const page=await pull();assert.deepEqual(page,{scope:'shared',fromCursor:0,toCursor:1,changes:[{syncId:1,model:'Task',identity:{id:'a'},stamp:1,state:{title:'first'}}]});assert.equal(prepared,1);
```

Append these tests at the end of the file (before any trailing `after(...)` hook if one exists; otherwise at the end):

```js
test('publish allocates one stamp per notify and stores it on the invalidation row',async()=>{
 const stamps=await db.$transaction(async tx=>{const storage=new PrismaPersistence(tx);const ref={model:'Task',identity:{id:'stamped'},identityKey:'{"id":"stamped"}'};
  const a=await storage.call({op:'publish',channel:'stamp-a',...ref});const b=await storage.call({op:'publish',channel:'stamp-b',...ref});const a2=await storage.call({op:'publish',channel:'stamp-a',...ref});return [a,b,a2];});
 assert.deepEqual(stamps.map(s=>s.stamp),[1,2,3]);assert.deepEqual(stamps.map(s=>s.cursor),[1,1,2]);
 const record=await db.$queryRawUnsafe("SELECT stamp FROM otter_record WHERE model='Task' AND identity_key='{\"id\":\"stamped\"}'");assert.equal(Number(record[0].stamp),3);
 const rows=await db.$queryRawUnsafe("SELECT channel, cursor, stamp FROM otter_invalidation WHERE identity_key='{\"id\":\"stamped\"}' ORDER BY channel");
 assert.deepEqual(rows.map(r=>[r.channel,Number(r.cursor),Number(r.stamp)]),[['stamp-a',2,3],['stamp-b',1,2]]);
});
test('scan returns the stamp of each row',async()=>{
 const rows=await db.$transaction(tx=>new PrismaPersistence(tx).call({op:'scan',channel:'stamp-a',after:0,limit:50}));
 assert.deepEqual(rows.map(r=>[r.cursor,r.stamp]),[[2,3]]);
});
test('concurrent notifies of one record receive distinct stamps',async()=>{
 const notify=()=>db.$transaction(async tx=>{await backend.notify(tx,{channel:'race-stamp',records:[{model:'Task',identity:{id:'race'}}]});});
 await Promise.all([notify(),notify(),notify(),notify()]);
 const record=await db.$queryRawUnsafe("SELECT stamp FROM otter_record WHERE model='Task' AND identity_key='{\"id\":\"race\"}'");assert.equal(Number(record[0].stamp),4);
 const page=await pull('race-stamp',0);assert.equal(page.changes.length,1);assert.equal(page.changes[0].stamp,4);
});
```

Check the file's imports: `PrismaPersistence` must be imported from `../../../packages/persistence-prisma/index.mts` (it is already used on line 133; if the import is missing, add it next to the existing `prisma`/`prismaTransactions` import).

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash integration/persistence/server/run.sh`
Expected: the push test fails on the `deepEqual` (no `stamp` in the page, or Rust rejects the bare cursor from `publish`), and the three new tests fail (`otter_record` does not exist).

- [ ] **Step 3: Rewrite `migration.sql`**

```sql
CREATE TABLE IF NOT EXISTS otter_client (
 client_id text PRIMARY KEY,
 owner_id text NOT NULL,
 sequence bigint NOT NULL DEFAULT 0 CHECK(sequence >= 0 AND sequence <= 9007199254740991),
 request_hash text,
 receipt text
);
CREATE TABLE IF NOT EXISTS otter_channel (
 channel text PRIMARY KEY,
 head bigint NOT NULL CHECK(head >= 0 AND head <= 9007199254740991)
);
CREATE TABLE IF NOT EXISTS otter_record (
 model text NOT NULL,
 identity_key text NOT NULL,
 stamp bigint NOT NULL CHECK(stamp > 0 AND stamp <= 9007199254740991),
 PRIMARY KEY(model,identity_key)
);
CREATE TABLE IF NOT EXISTS otter_invalidation (
 channel text NOT NULL REFERENCES otter_channel(channel),
 model text NOT NULL,
 identity_key text NOT NULL,
 identity jsonb NOT NULL,
 cursor bigint NOT NULL CHECK(cursor > 0 AND cursor <= 9007199254740991),
 stamp bigint NOT NULL CHECK(stamp > 0 AND stamp <= 9007199254740991),
 PRIMARY KEY(channel,model,identity_key),
 UNIQUE(channel,cursor)
);
```

Keep the existing `otter_client` and `otter_channel` blocks byte-for-byte if they differ from the above; only `otter_record` and the `stamp` column are new.

- [ ] **Step 4: Implement `scan` and `publish` in `index.mts`**

Replace the `scan` case:

```ts
      case "scan": {
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT channel, cursor, model, identity_key, identity, stamp FROM otter_invalidation WHERE channel=$1 AND cursor>$2 ORDER BY cursor LIMIT $3",
          r.channel,
          BigInt(r.after),
          r.limit,
        );
        return rows.map((row) => ({
          channel: row.channel,
          cursor: safe(row.cursor),
          model: row.model,
          identityKey: row.identity_key,
          identity: row.identity,
          stamp: safe(row.stamp),
        }));
      }
```

Replace the `publish` case:

```ts
      case "publish": {
        const stamped = await tx.$queryRawUnsafe<any[]>(
          "INSERT INTO otter_record(model,identity_key,stamp) VALUES($1,$2,1) ON CONFLICT(model,identity_key) DO UPDATE SET stamp=otter_record.stamp+1 RETURNING stamp",
          r.model,
          r.identityKey,
        );
        const stamp = safe(stamped[0].stamp);
        const rows = await tx.$queryRawUnsafe<any[]>(
          "INSERT INTO otter_channel(channel,head) VALUES($1,1) ON CONFLICT(channel) DO UPDATE SET head=otter_channel.head+1 RETURNING head",
          r.channel,
        );
        const cursor = safe(rows[0].head);
        await tx.$executeRawUnsafe(
          "INSERT INTO otter_invalidation(channel,model,identity_key,identity,cursor,stamp) VALUES($1,$2,$3,$4::jsonb,$5,$6) ON CONFLICT(channel,model,identity_key) DO UPDATE SET identity=EXCLUDED.identity,cursor=EXCLUDED.cursor,stamp=EXCLUDED.stamp",
          r.channel,
          r.model,
          r.identityKey,
          JSON.stringify(r.identity),
          BigInt(cursor),
          BigInt(stamp),
        );
        return { cursor, stamp };
      }
```

The `otter_record` upsert takes the row lock first, so two transactions notifying the same record serialise on it before touching the channel head; this is what the concurrency test checks.

- [ ] **Step 5: Update the adapter README**

In `packages/persistence-prisma/README.md`, after the sentence "Table names use the `otter_` prefix and are currently fixed.", add:

```markdown
`otter_record` holds one row per `(model, identity)` and allocates its stamp: every `publish` increments it and stores the value on the `otter_invalidation` row, which Pull delivers as the change's `stamp`.
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `bash integration/persistence/server/run.sh`
Expected: all tests pass, including the three new ones and the updated push assertion.

- [ ] **Step 7: Prettier, commit**

```bash
node_modules/.bin/prettier --write packages/persistence-prisma/*.mts
node_modules/.bin/prettier --check packages/client-js/*.mts packages/server/*.mts packages/persistence-prisma/*.mts
git add packages/persistence-prisma integration/persistence/server/runtime.test.mjs
git commit -m "feat(persistence): allocate a stamp per notify in otter_record and deliver it from otter_invalidation"
```

---

### Task 3: `stamp` becomes required on the wire and the client drops the unstamped path

**Files:**
- Modify: `crates/core/src/protocol.rs:176-230` (`RecordChange`, `PullPage::decode`, `PullPage::validate`)
- Modify: `fixtures/protocol/counter-and-checkpoint.json` (`pull` array)
- Modify: `crates/core/tests/contracts.rs:200-230`
- Modify: `crates/server/src/lib.rs` (`stamp: Some(stamp)` → `stamp`)
- Modify: `crates/client/src/downlink.rs` (`apply_change`)
- Modify: `crates/sqlite/tests/common/mod.rs:29-45` (`page` helper)
- Modify: `crates/sqlite/tests/downlink.rs` (`stamped` helper, cascade test, delete the unstamped test)
- Modify: `integration/rust/examples/capacity.rs:24`
- Modify: `integration/rust/tests/scenarios.rs` (add one assertion)

**Interfaces:**
- Consumes: Tasks 1 and 2 (the server always emits a stamp now).
- Produces: `pub struct RecordChange { pub cursor: u64, pub model: String, pub identity: Value, pub stamp: u64, pub state: Value }`. Every constructor in the workspace must supply `stamp`.

- [ ] **Step 1: Write the failing protocol tests**

In `fixtures/protocol/counter-and-checkpoint.json`, replace the `pull` array with:

```json
  "pull": [
    {"name": "safe maximum", "wire": "{\"scope\":\"book\",\"fromCursor\":9007199254740991,\"toCursor\":9007199254740991,\"changes\":[]}", "valid": true},
    {"name": "overflow", "wire": "{\"scope\":\"book\",\"fromCursor\":0,\"toCursor\":9007199254740992,\"changes\":[]}", "valid": false},
    {"name": "negative", "wire": "{\"scope\":\"book\",\"fromCursor\":-1,\"toCursor\":0,\"changes\":[]}", "valid": false},
    {"name": "null withdrawal", "wire": "{\"scope\":\"book\",\"fromCursor\":0,\"toCursor\":1,\"changes\":[{\"syncId\":1,\"model\":\"Entry\",\"identity\":{\"id\":\"one\"},\"stamp\":1,\"state\":null}]}", "valid": true},
    {"name": "stamp missing", "wire": "{\"scope\":\"book\",\"fromCursor\":0,\"toCursor\":1,\"changes\":[{\"syncId\":1,\"model\":\"Entry\",\"identity\":{\"id\":\"one\"},\"state\":null}]}", "valid": false},
    {"name": "stamp zero", "wire": "{\"scope\":\"book\",\"fromCursor\":0,\"toCursor\":1,\"changes\":[{\"syncId\":1,\"model\":\"Entry\",\"identity\":{\"id\":\"one\"},\"stamp\":0,\"state\":null}]}", "valid": false},
    {"name": "stamp negative", "wire": "{\"scope\":\"book\",\"fromCursor\":0,\"toCursor\":1,\"changes\":[{\"syncId\":1,\"model\":\"Entry\",\"identity\":{\"id\":\"one\"},\"stamp\":-1,\"state\":null}]}", "valid": false},
    {"name": "stamp overflow", "wire": "{\"scope\":\"book\",\"fromCursor\":0,\"toCursor\":1,\"changes\":[{\"syncId\":1,\"model\":\"Entry\",\"identity\":{\"id\":\"one\"},\"stamp\":9007199254740992,\"state\":null}]}", "valid": false}
  ],
```

In `crates/core/tests/contracts.rs`, in `field_default_and_record_stamp_round_trip_and_otter_prefix_is_rejected`, replace the block from `let page = PullPage::decode(` through the `.contains("stamp")` assertion with:

```rust
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cargo test -p otter-core`
Expected: the fixture-driven test fails on "stamp missing" (currently valid) and the contracts test fails to compile (`Option<u64>` vs `7`). Compile failure counts as failing.

- [ ] **Step 3: Change the protocol**

In `crates/core/src/protocol.rs`:

```rust
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecordChange {
    #[serde(rename = "syncId")]
    pub cursor: u64,
    pub model: String,
    pub identity: Value,
    pub stamp: u64,
    pub state: Value,
}
```

In `PullPage::decode`, extend the pre-check loop so a missing stamp gets a clear message before serde runs:

```rust
        if let Some(changes) = value["changes"].as_array() {
            for change in changes {
                if change.get("state").is_none() {
                    return Err(invalid("change state missing"));
                }
                if change.get("stamp").is_none() {
                    return Err(invalid("change stamp missing"));
                }
            }
        }
```

In `PullPage::validate`, inside the `for change in &self.changes` loop, after `counter(change.cursor)?;` add:

```rust
            if change.stamp == 0 || counter(change.stamp).is_err() {
                return Err(invalid("change stamp must be a positive counter"));
            }
```

Negative and overflowing stamps already fail at serde (`u64`) or at `counter`; the fixture cases verify all four.

- [ ] **Step 4: Fix every constructor and the client**

`crates/server/src/lib.rs`, in `process_pull`: `stamp: Some(stamp)` → `stamp`.

`crates/client/src/downlink.rs`, `apply_change`: replace the `let newer = match change.stamp { ... }` block with:

```rust
        let stamp = change.stamp;
        let newer = if stamp > local {
            true
        } else if stamp < local {
            false
        } else {
            // equal stamp: idempotent when content matches, diagnostic otherwise
            let current = self.truth(&key)?;
            if current != incoming {
                report.conflicts += 1;
                report.diagnostics.push(json!({
                    "model": key.model, "identity": key.identity, "stamp": stamp, "channel": channel,
                    "local": current, "incoming": incoming,
                }));
            }
            false
        };
```

and replace the `if is_delete { match change.stamp { ... } } else { ... }` block at the end with:

```rust
        if is_delete {
            self.set_authority(&key, None)?;
            self.claim_remove(channel, &key)?;
            if self.claims(&key)?.is_empty() {
                self.drop_record(&key)?;
            } else {
                self.set_record_stamp(&key, stamp)?;
            }
        } else {
            self.set_authority(&key, incoming)?;
            self.claim_add(channel, &key)?;
            self.set_record_stamp(&key, stamp)?;
        }
        Ok(())
```

Delete the comment block about unstamped deletes. Update the module doc line if it mentions optional stamps.

`crates/sqlite/tests/common/mod.rs`, `page` helper: set `stamp: to,` instead of `stamp: None,`. Every existing single-channel test then gets a stamp that grows with the cursor, which is what a real server produces for one record on one channel.

`crates/sqlite/tests/downlink.rs`:
- `stamped` helper: `p.changes[0].stamp = stamp;`
- In `delete_cascades_to_descendants_and_their_claims`, the `book` closure and the Comment page: `stamp: None,` → `stamp: cursor,` in the closure and `stamp: 2,` in the Comment change (the Comment is a different record, any positive value works; the Book delete at cursor 3 has stamp 3 > 1).
- Delete the whole `unstamped_delete_releases_one_claim_and_removes_on_last` test.

`integration/rust/examples/capacity.rs:24`: `stamp: None,` → `stamp: to,`.

`integration/rust/tests/scenarios.rs`: after the first `client.apply_page(page).unwrap();` in the loop, insert before it:

```rust
        assert_eq!(page.changes[0].stamp, 1, "seed {seed}");
```

(`db.head` starts at 1 and the first pull returns the row with `stamp: db.head`.)

Search for any remaining constructor: `grep -rn "stamp: None\|stamp: Some" crates integration --include='*.rs'` must return nothing.

- [ ] **Step 5: Run everything in Rust**

Run: `cargo test --workspace --locked`
Expected: all pass. The client tests `channel_claims_and_cross_channel_delete`, `older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping`, `equal_stamp_is_idempotent_or_a_diagnostic`, `delete_cascades_to_descendants_and_their_claims` are unchanged in behaviour.

- [ ] **Step 6: Format, lint, commit**

```bash
cargo fmt --all
cargo clippy --workspace --all-targets --locked -- -D warnings
git add crates fixtures/protocol integration/rust
git commit -m "feat(protocol): stamp is a required positive counter on every pull change"
```

---

### Task 4: Acceptance scenarios on the client

**Files:**
- Modify: `crates/sqlite/tests/downlink.rs` (append tests)
- Create: `fixtures/scenarios/delayed-page/README.md`
- Create: `fixtures/scenarios/delete-across-channels/README.md`

**Interfaces:**
- Consumes: `page(channel, from, to, text)` and `stamped(channel, from, to, stamp, text)` helpers, `subscribe`, `key`, `table_count`, `open`, `mutation` from `crates/sqlite/tests/common/mod.rs` and the top of `downlink.rs`.

Each test below maps to a numbered scenario in the spec's "Acceptance scenarios". Spec scenarios 3 and 4 (fan-out stamps, concurrent notify) are covered by Task 2; scenario 9 (unstamped page rejected) by Task 3; scenario 7 (pending edits replay) by the existing `newer_authority_lands_beneath_pending_edits_and_replays_them` and the 64 interleavings in `integration/rust`.

- [ ] **Step 1: Write the tests**

Append to `crates/sqlite/tests/downlink.rs`:

```rust
/// Spec scenario 1: the newer content arrives through B first; A's delayed older page
/// cannot regress it, but A's cursor still advances and A's claim is recorded.
#[test]
fn delayed_page_from_another_channel_cannot_regress_newer_content() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("b", 0, 5, 8, Some("new"))).unwrap();
    let report = c.apply_page(stamped("a", 0, 10, 7, Some("old"))).unwrap();
    assert_eq!(report.applied, 1);
    assert_eq!(report.conflicts, 0);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "new");
    assert_eq!(c.cursor("a").unwrap(), 10);
    assert_eq!(c.cursor("b").unwrap(), 5);
    assert_eq!(table_count(&mut c, "otter_claim"), 2);
    // A catches up with the same change at its own stamp: still nothing to apply.
    c.apply_page(stamped("a", 10, 11, 9, Some("new"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "new");
}

/// Spec scenario 2: the same page delivered twice is idempotent.
#[test]
fn redelivered_page_is_a_no_op() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    let again = c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    assert!(again.stale);
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "A");
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
}

/// Spec scenario 6: a delete with a newer stamp removes the record on the first channel
/// that delivers it; the tombstone survives until every claiming channel has delivered
/// the delete; an older upsert arriving in between is discarded.
#[test]
fn delete_across_channels_keeps_a_tombstone_until_every_claim_confirms() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    c.apply_page(stamped("b", 0, 1, 2, Some("B"))).unwrap();
    // The delete reaches B first (stamp 4): record gone, A's claim remains as the tombstone marker.
    c.apply_page(stamped("b", 1, 2, 4, None)).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    // A delayed older upsert (stamp 3) on A must not resurrect the record.
    c.apply_page(stamped("a", 1, 2, 3, Some("A2"))).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    // A's copy of the delete (stamp 5, A's own notification) clears the last claim and the tombstone.
    c.apply_page(stamped("a", 2, 3, 5, None)).unwrap();
    assert_eq!(table_count(&mut c, "otter_claim"), 0);
    assert_eq!(table_count(&mut c, "otter_record"), 0);
}

/// Spec scenario 5: a record moves A -> B -> A. Each hop is a delete on the old channel and
/// an upsert on the new one, in either arrival order.
#[test]
fn move_between_channels_and_back() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(&dir.path().join("db"));
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("in A"))).unwrap();
    // Move to B: the app notifies both; B's upsert (stamp 3) arrives before A's delete (stamp 2).
    c.apply_page(stamped("b", 0, 1, 3, Some("in B"))).unwrap();
    c.apply_page(stamped("a", 1, 2, 2, None)).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "in B");
    assert_eq!(c.claims_of(&key()).unwrap(), vec!["b".to_string()]);
    // Move back to A: A's upsert (stamp 4) then B's delete (stamp 5).
    c.apply_page(stamped("a", 2, 3, 4, Some("back in A"))).unwrap();
    c.apply_page(stamped("b", 1, 2, 5, None)).unwrap();
    assert!(c.read(&key()).unwrap().is_none(), "the newest stamp is B's delete");
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
    // The app's next notification on A (stamp 6) restores it.
    c.apply_page(stamped("a", 3, 4, 6, Some("back in A"))).unwrap();
    assert_eq!(c.read(&key()).unwrap().unwrap()["text"], "back in A");
    assert_eq!(c.claims_of(&key()).unwrap(), vec!["a".to_string()]);
}

/// Spec scenario 8: stamps, claims and tombstones survive close and reopen.
#[test]
fn reopen_preserves_stamps_claims_and_tombstones() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut c = open(&path);
    subscribe(&mut c, "a");
    subscribe(&mut c, "b");
    c.apply_page(stamped("a", 0, 1, 1, Some("A"))).unwrap();
    c.apply_page(stamped("b", 0, 1, 2, Some("B"))).unwrap();
    c.apply_page(stamped("b", 1, 2, 4, None)).unwrap();
    drop(c);
    let mut c = open(&path);
    assert!(c.read(&key()).unwrap().is_none());
    assert_eq!(table_count(&mut c, "otter_record"), 1);
    assert_eq!(table_count(&mut c, "otter_claim"), 1);
    c.apply_page(stamped("a", 1, 2, 3, Some("stale"))).unwrap();
    assert!(c.read(&key()).unwrap().is_none());
    c.apply_page(stamped("a", 2, 3, 5, None)).unwrap();
    assert_eq!(table_count(&mut c, "otter_record"), 0);
}
```

The move test uses `c.claims_of(&key())`. If `Client` has no such accessor, add one to `crates/client/src/lib.rs` next to `cursor`:

```rust
    /// Channels currently claiming a record, sorted. Test and diagnostic surface.
    pub fn claims_of(&mut self, key: &RecordKey) -> Result<Vec<String>> {
        self.view(|e| e.claims(key))
    }
```

and make `ledger.rs` `claims` return the channels ordered by `channel` (add `ORDER BY channel` to its query if absent).

- [ ] **Step 2: Run to verify they fail or pass for the right reason**

Run: `cargo test -p otter-sqlite --test downlink`
Expected: `move_between_channels_and_back` fails to compile until `claims_of` exists. Add it, rerun. All five new tests must pass without further engine changes; if one fails, the failure is a real defect in `downlink.rs` relative to the spec's apply table. Fix the engine, not the test, and record the fix in the commit message.

- [ ] **Step 3: Scenario READMEs**

`fixtures/scenarios/delayed-page/README.md`:

```markdown
# Delayed page

Entry e is provided by channels A and B. B delivers the record at stamp 8 first. A's page carrying stamp 7 arrives later: its content is discarded, A's cursor advances and A's claim is recorded. A later page from A at stamp 9 with the same content is a no-op. Covered by `delayed_page_from_another_channel_cannot_regress_newer_content` in `crates/sqlite/tests/downlink.rs`.
```

`fixtures/scenarios/delete-across-channels/README.md`:

```markdown
# Delete across channels

Entry e is claimed by A (stamp 1) and B (stamp 2). The delete is notified to both. B delivers it first at stamp 4: the row is removed, A's claim remains as the tombstone marker. A delayed upsert on A at stamp 3 is discarded. A's delete at stamp 5 removes the last claim and the tombstone. Covered by `delete_across_channels_keeps_a_tombstone_until_every_claim_confirms` and `reopen_preserves_stamps_claims_and_tombstones`.
```

- [ ] **Step 4: Run, format, commit**

```bash
cargo test --workspace --locked
cargo fmt --all
cargo clippy --workspace --all-targets --locked -- -D warnings
git add crates fixtures/scenarios
git commit -m "test(client): acceptance scenarios for stamped cross-channel delivery"
```

---

### Task 5: Documentation and the notify rule

**Files:**
- Modify: `packages/server/README.md` (`## notify` section)
- Modify: `docs/architecture/compatibility-and-recovery.md:9` (wire names row)
- Modify: `docs/next-things.md:13-17`

**Interfaces:** none; prose only.

- [ ] **Step 1: `notify` rule in the server README**

In `packages/server/README.md`, after the paragraph beginning "`notify({ channel, records })` declares that `records` ...", add:

```markdown
Every `notify` allocates a new **stamp** for each record, a per-record counter that Pull delivers with the record's content. The client applies content strictly by stamp, so the order of `notify` calls decides which channel's content wins when channels return different views of the same record.

Notify every channel that provides a record whenever that record changes, including when a loader starts returning `null` for it on one channel. A channel that is not notified keeps delivering its old stamp, and the client will not pick up the change through it. The framework does not detect a missing notification.
```

- [ ] **Step 2: Wire names row**

In `docs/architecture/compatibility-and-recovery.md`, change the "Wire names" row to:

```markdown
| Wire names | Legacy `scope`, `syncId`, `requiredScope`, `requiredSyncId` and `requiredCheckpoints`; `stamp` on every pull change; public APIs use Channel, Cursor, Stamp and Checkpoint. |
```

- [ ] **Step 3: next-things checklist**

In `docs/next-things.md`, lines 13 to 17, replace the five items with:

```markdown
- [x] **Cross-channel record revision**: compare content versions when the same record arrives from different channels; do not use the channel cursor as a cross-channel recency measure. Shipped as the per-record stamp; see `docs/superpowers/specs/2026-09-12-record-stamp-design.md`.
- [x] Every record carries a stamp from creation; the stamp is allocated per `notify` and delivered from the invalidation row. Optional revisions and the "one stamp per publication" variant were rejected.
- [x] Tests for same-stamp idempotence, conflict diagnostics, late old pages, delete across channels and Move A→B→A.
- [ ] Tombstone retention is bounded by claims (dropped when every claiming channel has delivered the delete); channel generation / snapshot reset remain future work.
```

Leave the "Earlier record-revision proposal for future review" section in place; add one line under its heading: `Superseded by the record stamp design; kept for history.`

- [ ] **Step 4: Full suite and commit**

```bash
bash scripts/test.sh
git add packages/server/README.md docs/architecture/compatibility-and-recovery.md docs/next-things.md
git commit -m "docs: stamp on the wire and the notify-every-channel rule"
```

Expected: `scripts/test.sh` green end to end. If the Dart or e2e steps fail on something unrelated to stamps (toolchain, ports), report the exact failure rather than skipping.

---

## Self-review

**Spec coverage.** Naming, two numbers, allocation per notify: Task 2 (`otter_record` increment per publish request) and Task 5 (README). Always on / wire: Task 3. Server tables, publish, scan, process_pull: Tasks 1 and 2. Client tables and apply rules: already on `main`; Task 3 removes the unstamped branches; Task 4 verifies the rules against the spec's table. Delete across channels and tombstone: Task 4 tests 3 and 5. Equal stamp diagnostic: existing test plus Task 4 test 2. Application rule about notifying every channel: Task 5. Worked example numbers appear in Task 2's persistence test (stamps 1, 2, 3 across two channels). Acceptance scenarios 1 to 9 are each assigned above. Out of scope items are not touched.

**Placeholder scan.** Every code step shows the code. The only conditional instruction is Task 4's `claims_of` accessor, which shows the code to add.

**Type consistency.** `RecordChange.stamp` is `Option<u64>` in Task 1 and `u64` from Task 3 on; Task 1's tests assert `Some(7)` and Task 3 rewrites `crates/server/tests/stamp.rs` implicitly through compilation: when running Task 3 step 5, change `assert_eq!(page.changes[0].stamp, Some(7))` to `assert_eq!(page.changes[0].stamp, 7)` in `crates/server/tests/stamp.rs`. Host `publish` returns `{ cursor, stamp }` in both Task 1 (consumer) and Task 2 (producer). Persistence `scan` row field is `stamp` in both. Test helpers `page`, `stamped`, `table_count`, `subscribe`, `key`, `open` are the ones defined in `crates/sqlite/tests/common/mod.rs` and `downlink.rs`.
