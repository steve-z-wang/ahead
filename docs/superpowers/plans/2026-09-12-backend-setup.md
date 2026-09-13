# Backend Setup Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A complete Otter Sync backend is one `.model` file, one `handlers` object, one `loaders` object and two lines of setup, with everything derivable from the model compiled into `generated/backend.ts`.

**Architecture:** The Rust server stops receiving a per-push fallback channel and requires the host to select each mutation's checkpoint channel. The TypeScript server package (`packages/server/index.mts`) gains the single call-object convention (`HandlerCall`, `LoaderCall`, `notify({ channel, records })`), a `database` adapter option, a required `authenticate`, and `listen({ port })`; the HTTP and WebSocket adapters become internal. The Rust compiler emits `backend.ts` with typed `Handlers<Tx>` and `Loaders<Tx>` interfaces and a bound `createBackend`. The Nest package is deleted.

**Tech Stack:** Rust 1.98 (crates `otter-core`, `otter-server`, `otter-compiler`), Node 22.18+ running `.mts` with type stripping, TypeScript 5.8 for typechecks, Prisma 6.19 with PostgreSQL in tests, `node:test`.

**Spec:** `docs/superpowers/specs/2026-09-12-backend-setup-design.md`

## Global Constraints

- Every framework call takes a single object argument with named fields; no positional overloads, no variadic parameters.
- Handler call fields in declared order: `input`, `tx`, `userId`, `notify`. Loader call fields: `ids`, `tx`, `userId`.
- `notify({ channel, records })`: `channel` is a string, `records` is always an array.
- Method names in generated interfaces are the mutation or model name with the first character lower-cased (`AddTask` becomes `addTask`, `Task` becomes `task`). Older mutation versions get a `V<n>` suffix (`editTaskV1`).
- Slot arguments: create is the complete row (identity and data merged); update is `{ identity, patch }`; delete is `{ identity }`.
- The framework has no notion of a principal channel and does not guard subscriptions.
- Node type stripping must be able to run `examples/rust-round-trip/server.mts` directly: no decorators, enums, or parameter properties in hand-written or generated TypeScript.
- Commit after every task with the attribution lines the session requires.
- Work happens in the worktree `.worktrees/backend-setup` on branch `refactor/backend-setup`. Run every command from that directory. The Rust toolchain lives in `.tools/`; invoke it as `.tools/cargo/bin/cargo …`. Project scripts (`bash scripts/test.sh`, `bash integration/persistence/server/run.sh`, `bash integration/e2e/run.sh`, `bash integration/generated-api/verify.sh`) find it on their own.

---

## File map

| File | Responsibility after this plan |
| --- | --- |
| `crates/core/src/protocol.rs` | Receipt validation allows empty checkpoints when rejections are present. |
| `crates/server/src/lib.rs` | `process_push(config, owner, bytes, host)`; each accepted mutation's host result carries `channel`. |
| `bindings/node/src/server.rs` | N-API `process_push` without the channel parameter. |
| `crates/compiler/src/emit.rs` | New `backend_typescript(v, runtime_import)` emitter; `typescript()` drops `backendConfig`. |
| `crates/compiler/src/main.rs` | Writes `backend.ts`; accepts `--backend-runtime SPEC`. |
| `packages/server/index.mts` | Public surface: `createBackend`, `MutationRejected`, `devAuth`, types. HTTP and live adapters internal. |
| `packages/persistence-prisma/index.mts` | Adds `prisma(client, options?)` returning `{ transaction, persistence }`. |
| `examples/rust-round-trip/server.mts` | Rewritten to the new surface; exports `createExample()`. |
| `integration/persistence/server/runtime.test.mjs` | Rewritten to the new surface; adds checkpoint-selection and `notify` cases. |
| `integration/generated-api/*` | Typechecks `backend.ts`, including a negative fixture. |
| `packages/nest`, `integration/nest` | Deleted. |

---

### Task 1: Rust server selects checkpoints only from handler results

**Files:**
- Modify: `crates/core/src/protocol.rs:123-135` (`PushReceipt::validate`)
- Modify: `fixtures/protocol/counter-and-checkpoint.json`
- Modify: `crates/core/tests/contracts.rs`
- Modify: `crates/server/src/lib.rs:295-408` (`process_push`)
- Modify: `bindings/node/src/server.rs:36-52`
- Modify: `integration/rust/tests/scenarios.rs:48-63`
- Modify: `packages/server/index.mts` (only the `processPush` call and the `handle` branch)

**Interfaces:**
- Produces: `otter_server::process_push(config: &Config, owner: &str, bytes: &[u8], host: &impl Host) -> Result<String>`. The host's reply to `{"op":"handle",...}` must be `{"rejection": code}` or `{"channel": string}`; `null` is an error `invalid handler settlement`.
- Produces: N-API `processPush(configJson, owner, requestJson, callback)`.
- Produces: `PushReceipt` may carry `requiredCheckpoints: []` when `rejections` is non-empty; `requiredScope` is then `""` and `requiredSyncId` is `0`.

- [ ] **Step 1: Add the failing protocol fixture cases**

Edit `fixtures/protocol/counter-and-checkpoint.json` so the `receipt` array reads:

```json
  "receipt": [
    {"name": "legacy fallback", "wire": "{\"requiredScope\":\"book\",\"requiredSyncId\":0,\"rejections\":[]}", "valid": true},
    {"name": "explicit empty rejected", "wire": "{\"requiredScope\":\"book\",\"requiredSyncId\":0,\"requiredCheckpoints\":[],\"rejections\":[]}", "valid": false},
    {"name": "empty checkpoints with rejections", "wire": "{\"requiredScope\":\"\",\"requiredSyncId\":0,\"requiredCheckpoints\":[],\"rejections\":[{\"ordinal\":1,\"code\":\"denied\"}]}", "valid": true}
  ]
```

- [ ] **Step 2: Run the contracts test to see it fail**

Run: `.tools/cargo/bin/cargo test -p otter-core --test contracts`
Expected: FAIL on `empty checkpoints with rejections`.

- [ ] **Step 3: Relax receipt validation**

In `crates/core/src/protocol.rs`, replace

```rust
        if self.required_checkpoints.is_empty() {
            return Err(invalid("empty checkpoint set"));
        }
```

with

```rust
        if self.required_checkpoints.is_empty() && self.rejections.is_empty() {
            return Err(invalid("empty checkpoint set"));
        }
```

- [ ] **Step 4: Run the contracts test to see it pass**

Run: `.tools/cargo/bin/cargo test -p otter-core --test contracts`
Expected: PASS.

- [ ] **Step 5: Change `process_push` in the Rust server**

In `crates/server/src/lib.rs`:

Remove the `channel: &str,` parameter from `process_push`.

Replace the accepted-mutation branch

```rust
        } else {
            let selected = if result.is_null() {
                channel
            } else {
                result["channel"]
                    .as_str()
                    .ok_or("invalid handler settlement")?
            };
            channels.insert(selected.to_string());
        }
```

with

```rust
        } else {
            let selected = result["channel"]
                .as_str()
                .ok_or("invalid handler settlement")?;
            channels.insert(selected.to_string());
        }
```

Delete

```rust
    if channels.is_empty() {
        channels.insert(channel.into());
    }
```

Replace the legacy computation and receipt construction

```rust
    let legacy = match checkpoints.iter().find(|cp| cp.channel == channel) {
        Some(cp) => cp.cursor,
        None => head(host, channel).await?,
    };
    let receipt = PushReceipt {
        required_checkpoints: checkpoints,
        required_channel: channel.into(),
        required_cursor: legacy,
        rejections,
    };
```

with

```rust
    let (required_channel, required_cursor) = match checkpoints.first() {
        Some(cp) => (cp.channel.clone(), cp.cursor),
        None => (String::new(), 0),
    };
    let receipt = PushReceipt {
        required_checkpoints: checkpoints,
        required_channel,
        required_cursor,
        rejections,
    };
```

- [ ] **Step 6: Update the Node binding and the Rust scenario test**

`bindings/node/src/server.rs`: remove `channel: String,` from the `process_push` parameters and `&channel,` from the call.

`integration/rust/tests/scenarios.rs`: in `fn push`, remove the `"book",` argument so the call reads

```rust
        match run(otter_server::process_push(&config(), "u", body, self)) {
```

- [ ] **Step 7: Keep the TypeScript host compiling**

In `packages/server/index.mts`, inside the `handle` branch after `if (result === undefined) result = null;`, temporarily add

```ts
          if (result === null)
            result = { channel: options.principalChannel(req.owner) };
```

and in the returned `push` remove the `options.principalChannel(owner),` argument:

```ts
    push: (owner: string, request: Uint8Array | string) =>
      run((tx, session) =>
        native.processPush(config, owner, text(request), host(tx, session)),
      ),
```

Update the `Native` type: `processPush(config: string, owner: string, request: string, callback: ...)`.

- [ ] **Step 8: Run the Rust gate and the Node persistence suite**

Run: `.tools/cargo/bin/cargo fmt --all && .tools/cargo/bin/cargo test --workspace --locked && .tools/cargo/bin/cargo clippy --workspace --all-targets --locked -- -D warnings`
Expected: all green, including the 64 interleaving scenarios.

Run: `node bindings/node/build.mjs && bash integration/persistence/server/run.sh`
Expected: 23 tests pass.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor(server): select push checkpoints only from handler results"
```

---

### Task 2: Prisma `prisma()` adapter, `database`, `authenticate`, `listen`, `devAuth`

**Files:**
- Modify: `packages/persistence-prisma/index.mts`
- Modify: `packages/server/index.mts`
- Modify: `integration/persistence/server/runtime.test.mjs`

**Interfaces:**
- Produces: `prisma<T>(client, options?) => { transaction: <R>(body: (tx: T) => Promise<R>) => Promise<R>; persistence: (tx: T) => Persistence }` exported from `packages/persistence-prisma/index.mts`.
- Produces: `BackendOptions<T>` gains `database: Database<T>` and `authenticate: Authenticate`; `transaction` and `persistence` top-level options are removed.
- Produces: `backend.listen({ port, host? }) => Promise<{ url: string; close(): Promise<void> }>`.
- Produces: `devAuth(): Authenticate` exported from the server package.
- Consumes: nothing from later tasks. `principalChannel`, `authorize`, `handlers`, `loaders` keep their Task 1 shapes until Task 3.

- [ ] **Step 1: Write the failing adapter test**

Append to `integration/persistence/server/runtime.test.mjs`:

```js
test('prisma() bundles the transaction runner and the persistence factory',async()=>{
 const adapter=prisma(db);
 assert.equal(typeof adapter.transaction,'function');
 const bound=adapter.persistence({$queryRawUnsafe:async()=>[{head:7}],$executeRawUnsafe:async()=>1});
 assert.equal(await bound.call({op:'head',channel:'x'}),7);
});
test('listen serves push, pull and live on one port and closes cleanly',async()=>{
 const server=await backend.listen({port:0});
 try{
  const denied=await fetch(`${server.url}/sync/pull`,{method:'POST',body:'{}'});assert.equal(denied.status,401);
  const ok=await fetch(`${server.url}/sync/pull`,{method:'POST',headers:{authorization:'Bearer alice'},body:JSON.stringify({clientId:'listen',scope:'shared',fromCursor:0})});assert.equal(ok.status,200);
 }finally{await server.close();}
});
```

and change the import line to `import {PrismaPersistence,prismaTransactions,prisma} from '../../../packages/persistence-prisma/index.mts';`.

- [ ] **Step 2: Run to see it fail**

Run: `bash integration/persistence/server/run.sh`
Expected: FAIL, `prisma is not a function` / `backend.listen is not a function`.

- [ ] **Step 3: Add `prisma()` to the Prisma package**

Append to `packages/persistence-prisma/index.mts`:

```ts
/** Bundle the transaction runner and the persistence factory for `createBackend({ database })`. */
export function prisma<T extends PrismaTransaction>(
  client: Parameters<typeof prismaTransactions<T>>[0],
  options: { retries?: number; timeout?: number } = {},
) {
  return {
    transaction: prismaTransactions<T>(client, options),
    persistence: (tx: T) => new PrismaPersistence(tx),
  };
}
```

- [ ] **Step 4: Add `database`, `authenticate`, `devAuth` and `listen` to the server package**

In `packages/server/index.mts`:

Add after the `Persistence` interface:

```ts
export interface Database<T> {
  /** Must provide a coherent snapshot and roll back rejected callbacks. Retry serialization failures. */
  transaction: <R>(body: (tx: T) => Promise<R>) => Promise<R>;
  persistence: (tx: T) => Persistence;
}
export type Authenticate = (
  request: IncomingMessage,
) => Promise<string | null | undefined> | string | null | undefined;
/** Development only: the bearer token is used verbatim as the user id. Never use in production. */
export function devAuth(): Authenticate {
  return (request) => {
    const header = request.headers.authorization;
    if (typeof header !== "string" || !header.startsWith("Bearer ")) return null;
    const id = header.slice("Bearer ".length).trim();
    return id === "" ? null : id;
  };
}
```

Replace in `BackendOptions<T>`

```ts
  transaction: <R>(body: (tx: T) => Promise<R>) => Promise<R>;
  persistence: (tx: T) => Persistence;
```

with

```ts
  database: Database<T>;
  authenticate: Authenticate;
```

Replace every `options.transaction(` with `options.database.transaction(` and every `options.persistence(tx)` with `options.database.persistence(tx)`.

Add `import { createServer } from "node:http";` at the top (keep the existing `import type { IncomingMessage, RequestListener, Server } from "node:http";`).

Inside `createBackend`, before `return {`, define

```ts
  const authenticate = async (request: IncomingMessage) => {
    const id = await options.authenticate(request);
    return typeof id === "string" && id.trim() !== "" ? id : null;
  };
  const listen = async ({ port, host = "127.0.0.1" }: { port: number; host?: string }) => {
    const server = createServer(createHttpHandler({ backend: api, authenticate }));
    const live = attachLive(server, { backend: api, authenticate });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, host, () => resolve());
    });
    const address = server.address();
    const actual = typeof address === "object" && address ? address.port : port;
    return {
      url: `http://${host}:${actual}`,
      close: async () => {
        await live.close();
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        );
      },
    };
  };
```

Change `return {` to `const api = {` and after the object literal's closing `};` add `return { ...api, listen };`. The `api` object is what `createHttpHandler` and `attachLive` consume, so declare `listen` after `api` (move the `listen` definition below `const api = {...};` if TypeScript complains about use before declaration).

- [ ] **Step 5: Update the test file's backend construction**

In `integration/persistence/server/runtime.test.mjs`, every `createBackend({...})` call replaces `transaction:prismaTransactions(db),persistence:tx=>new PrismaPersistence(tx),` (or `transaction:fn=>db.$transaction(fn),persistence:tx=>new PrismaPersistence(tx),`) with `database:prisma(db),authenticate:async req=>req.headers.authorization==='Bearer alice'?'alice':null,`. Calls that build a custom `persistence` (lines 114, 123 in the current file) become `database:{transaction:prismaTransactions(db),persistence:tx=>{...existing body...}},authenticate:async()=>'alice',`.

- [ ] **Step 6: Run to see it pass**

Run: `bash integration/persistence/server/run.sh`
Expected: 25 tests pass.

Run: `npm run typecheck`
Expected: FAIL only in `examples/rust-round-trip/server.mts` (it still passes `transaction`/`persistence`); fix by changing its `createBackend` call to

```ts
    database: prisma(db),
    authenticate: devAuth(),
```

(import `prisma` from the Prisma package and `devAuth` from the server package) and re-run until `npm run typecheck` passes. Keep `principalChannel`, `authorize`, `handlers`, `loaders` in the example for now.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(server): database adapter, required authenticate, listen and devAuth"
```

---

### Task 3: Single call-object convention, `notify`, checkpoint selection

**Files:**
- Modify: `packages/server/index.mts`
- Modify: `integration/persistence/server/runtime.test.mjs`
- Modify: `examples/rust-round-trip/server.mts` (handler and loader bodies only)

**Interfaces:**
- Produces (exported types):

```ts
export interface RecordRef { model: string; identity: object }
export type NotifyArgs = { channel: string; records: readonly (RecordRef | object)[] };
export type Notify = (args: NotifyArgs) => void;
export interface HandlerCall<Tx, Input> { input: Input; tx: Tx; userId: string; notify: Notify }
export interface LoaderCall<Tx, Identity> { ids: readonly Identity[]; tx: Tx; userId: string }
export type Handler<Tx, Input = any> = (call: HandlerCall<Tx, Input>) => Promise<void | { channel: string }>;
export type Loader<Tx, Identity = any, Row = object> = (call: LoaderCall<Tx, Identity>) => Promise<readonly (Row | null)[]>;
export const RECORD: unique symbol;  // non-enumerable tag on slot arguments: { model, identity }
```

- Produces: `BackendOptions<T>.handlers: Record<string, Handler<T>>` keyed by lower-camel mutation name plus `V<n>` for non-latest versions; `BackendOptions<T>.loaders: Record<string, Loader<T>>` keyed by lower-camel model name. Optional `loaderHooks?: Record<string, { prepareForViewer(call: LoaderCall<T, any>): Promise<void> }>`.
- Produces: `backend.notify(tx, { channel, records })` replaces `backend.publish(tx, changes, channels)`; `bindTransaction(tx).notify({ channel, records })` replaces `.publish`.
- Removes: `principalChannel`, `authorize`, `WriteContext`, `ReadContext`, `Changes`.
- Consumes: `Database`, `Authenticate` from Task 2.

- [ ] **Step 1: Write the failing tests for checkpoint selection and notify**

Replace the backend construction at the top of `integration/persistence/server/runtime.test.mjs` with:

```js
const authenticate=async req=>req.headers.authorization==='Bearer alice'?'alice':null;
let called=0,prepared=0,lastInput;
const backend=createBackend({config,database:prisma(db),authenticate,handlers:{
 async edit({input,tx,notify}){
  called++;lastInput=input;const {identity,patch}=input.task;
  await tx.$executeRawUnsafe('INSERT INTO business_task(id,title) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET title=$2',identity.id,patch.title);
  notify({channel:'shared',records:[input.task]});
  if(patch.title==='refuse')throw new MutationRejected('task.refused');if(patch.title==='crash')throw new Error('business crash');
  if(patch.title==='two')notify({channel:'other',records:[input.task]});
  if(patch.title==='pick')return {channel:'other'};
 }},
 loaders:{async task({ids,tx}){return Promise.all(ids.map(async identity=>{const rows=await tx.$queryRawUnsafe('SELECT title FROM business_task WHERE id=$1',identity.id);return rows[0]??null;}));}},
 loaderHooks:{task:{async prepareForViewer(){prepared++}}},
});
```

Add these tests:

```js
test('slot arguments are tagged so notify accepts them directly',async()=>{
 await backend.push('alice',push('tagged',1,[mutation(1,'hello','tagged-a')]));
 assert.deepEqual(lastInput.task[RECORD],{model:'Task',identity:{id:'tagged-a'}});
 assert.equal(Object.keys(lastInput.task).includes('model'),false);
});
test('checkpoint is the single notified channel; several need an explicit choice; none is an error',async()=>{
 const one=JSON.parse(await backend.push('alice',push('cp1',1,[mutation(1,'hello','cp-a')])));
 assert.deepEqual(one.requiredCheckpoints.map(c=>c.scope),['shared']);
 await assert.rejects(()=>backend.push('alice',push('cp2',1,[mutation(1,'two','cp-b')])),/handler\.ambiguous_checkpoint:edit/);
 const picked=JSON.parse(await backend.push('alice',push('cp3',1,[mutation(1,'pick','cp-c')])));
 assert.deepEqual(picked.requiredCheckpoints.map(c=>c.scope),['other']);
 const silent=createBackend({config,database:prisma(db),authenticate,handlers:{async edit(){}},loaders:{async task({ids}){return ids.map(()=>null)}}});
 await assert.rejects(()=>silent.push('alice',push('cp4',1,[mutation(1,'hello','cp-d')])),/handler\.no_channel:edit/);
});
test('an all-rejected batch settles with no checkpoints',async()=>{
 const receipt=JSON.parse(await backend.push('alice',push('allrej',1,[mutation(1,'refuse','rej-a')])));
 assert.deepEqual(receipt.requiredCheckpoints,[]);assert.equal(receipt.requiredScope,'');assert.equal(receipt.rejections.length,1);
});
```

Import `RECORD` from the server package. Then update the remaining tests mechanically:

- `c.transaction` → `tx` after destructuring `{ids,tx}` or `{input,tx,notify}`.
- `args.task` → `input.task`.
- `await c.publish([{model:'Task',identity}],['shared'])` → `notify({channel:'shared',records:[input.task]})`.
- `backend.publish(tx,[{model:'Task',identity:{id:'a'}}],['shared'])` → `backend.notify(tx,{channel:'shared',records:[{model:'Task',identity:{id:'a'}}]})`.
- `session.publish([...],['shared'])` → `session.notify({channel:'shared',records:[...]})`.
- `handlers:{edit:{1:fn}}` → `handlers:{edit:fn}`; `loaders:{Task:{load:fn}}` → `loaders:{task:fn}`.
- Every `principalChannel:...,authorize:...,` is deleted.
- The test named `compaction materializes latest state; deletion is aligned null; authorizer runs first` drops its authorizer assertion; keep the compaction and null assertions.
- The test asserting `403 scope.forbidden` for an unauthorized channel is deleted (no channel guard exists). Keep the `owner_mismatch` 403 test.
- Tests that read `serverSdk.createHttpHandler` / `serverSdk.attachLive` switch to `backend.listen({port:0})` and its `url`; the live WebSocket test connects to `${url.replace('http','ws')}/sync/live`.

- [ ] **Step 2: Run to see the new tests fail**

Run: `bash integration/persistence/server/run.sh`
Expected: FAIL with `RECORD` undefined / handlers not functions.

- [ ] **Step 3: Implement the call-object convention in the server package**

In `packages/server/index.mts`:

Replace the `Changes`, `WriteContext`, `ReadContext`, `Handler`, `Loader` declarations with the interfaces from this task's **Produces** block, plus:

```ts
export const RECORD: unique symbol = Symbol("otter.record");
function toRef(value: unknown): RecordRef {
  if (value !== null && typeof value === "object") {
    const tagged = (value as { [RECORD]?: RecordRef })[RECORD];
    if (tagged) return tagged;
    const { model, identity } = value as Partial<RecordRef>;
    if (typeof model === "string" && identity && typeof identity === "object")
      return { model, identity };
  }
  throw new Error("notify: record must be a slot argument or { model, identity }");
}
function tag<T extends object>(value: T, ref: RecordRef): T {
  Object.defineProperty(value, RECORD, { value: ref, enumerable: false });
  return value;
}
function lowerFirst(name: string): string {
  return name.charAt(0).toLowerCase() + name.slice(1);
}
```

In `BackendOptions<T>` replace `principalChannel`, `authorize`, `handlers`, `loaders` with

```ts
  handlers: Record<string, Handler<T>>;
  loaders: Record<string, Loader<T>>;
  loaderHooks?: Record<string, { prepareForViewer(call: LoaderCall<T, any>): Promise<void> }>;
```

At the start of `createBackend`, build the dispatch tables from the descriptor:

```ts
  const descriptor = options.config as {
    schema?: { models?: { name: string }[] };
    mutations?: { name: string; version: number; slots?: { name: string; operation: string; cardinality: string; model: string }[] }[];
  };
  const latest = new Map<string, number>();
  for (const m of descriptor.mutations ?? [])
    latest.set(m.name, Math.max(latest.get(m.name) ?? 0, m.version));
  const handlerKey = (name: string, version: number) =>
    lowerFirst(name) + (version === latest.get(name) ? "" : `V${version}`);
  const handlerTable = new Map<string, { handler: Handler<T>; slots: NonNullable<(typeof descriptor.mutations)[number]["slots"]> }>();
  for (const m of descriptor.mutations ?? []) {
    const handler = options.handlers[handlerKey(m.name, m.version)];
    if (typeof handler !== "function")
      throw new Error(`Missing handler ${handlerKey(m.name, m.version)} for ${m.name} v${m.version}`);
    handlerTable.set(`${m.name} ${m.version}`, { handler, slots: m.slots ?? [] });
  }
  const loaderTable = new Map<string, Loader<T>>();
  for (const model of descriptor.schema?.models ?? []) {
    const loader = options.loaders[lowerFirst(model.name)];
    if (typeof loader !== "function")
      throw new Error(`Missing loader ${lowerFirst(model.name)} for ${model.name}`);
    loaderTable.set(model.name, loader);
  }
  const config = JSON.stringify({ ...options.config, loaders: [...loaderTable.keys()] });
  native.validateConfig(config);
```

(This replaces the existing `config` construction and the two `Missing handler`/`Missing loader` loops.)

Replace the `handle` branch body with:

```ts
        if (req.op === "handle") {
          const entry = handlerTable.get(`${req.name} ${req.version}`);
          if (!entry) throw new Error(`Missing handler ${req.name} v${req.version}`);
          const shape = (slot: (typeof entry.slots)[number], raw: any) => {
            if (raw === null || raw === undefined) return null;
            const ref: RecordRef = { model: slot.model, identity: raw.identity };
            if (slot.operation === "create") return tag({ ...raw.identity, ...raw.data }, ref);
            if (slot.operation === "update") return tag({ identity: raw.identity, patch: raw.patch }, ref);
            return tag({ identity: raw.identity }, ref);
          };
          const input: Record<string, unknown> = {};
          for (const slot of entry.slots) {
            const raw = req.arguments[slot.name];
            input[slot.name] =
              slot.cardinality === "list"
                ? (raw as any[]).map((item) => shape(slot, item))
                : shape(slot, raw);
          }
          const notified = new Set<string>();
          const notify: Notify = ({ channel, records }) => {
            if (typeof channel !== "string" || channel === "")
              throw new Error("notify: channel must be a non-empty string");
            if (!Array.isArray(records)) throw new Error("notify: records must be an array");
            notified.add(channel);
            void publish(tx, records.map(toRef), [channel]);
          };
          try {
            const returned = await entry.handler({ input, tx, userId: req.owner, notify });
            if (returned && typeof returned === "object" && typeof returned.channel === "string")
              result = { channel: returned.channel };
            else if (notified.size === 1) result = { channel: [...notified][0] };
            else if (notified.size === 0) throw new Error(`handler.no_channel:${req.name}`);
            else throw new Error(`handler.ambiguous_checkpoint:${req.name}`);
          } catch (error) {
            const code =
              error instanceof MutationRejected
                ? error.code
                : options.translateRejection?.(error);
            if (code == null) throw error;
            result = { rejection: new MutationRejected(code).code };
          }
        }
```

Replace the `authorize` branch with `else if (req.op === "authorize") { result = true; }`.

Replace the `load` branch with:

```ts
        } else if (req.op === "load") {
          const loader = loaderTable.get(req.model);
          if (!loader) throw new Error(`Missing loader ${req.model}`);
          const call = { ids: req.identities, tx, userId: req.owner };
          await options.loaderHooks?.[lowerFirst(req.model)]?.prepareForViewer(call);
          result = await loader(call);
          if (!Array.isArray(result) || result.some((value) => value === undefined))
            throw new Error("invalid loader: undefined or non-array result");
        }
```

Remove the `export` keyword from `createHttpHandler`, `attachLive`, `HttpBackend` and `LiveBackend`; they stay in the file as internal helpers used by `listen`. Keep `export { WebSocket } from "ws";`. The `config` option stays on the runtime `BackendOptions` because the generated `createBackend` (Task 4) supplies it; application code never passes it directly.

Rename the internal `publish(tx, changes, channels)` helper's public exposures: in `bindTransaction` return `notify: ({ channel, records }: NotifyArgs) => publish(tx, records.map(toRef), [channel])` instead of `publish`, and in the `api` object replace `publish,` with `notify: (tx: T, args: NotifyArgs) => publish(tx, args.records.map(toRef), [args.channel]),`. Remove the Task 1 temporary `principalChannel` fallback.

- [ ] **Step 4: Update the example handler and loader bodies**

In `examples/rust-round-trip/server.mts` replace the `handlers` and `loaders` options with

```ts
    handlers: {
      async edit({ input, tx, notify }) {
        calls++;
        const { identity, patch } = input.entry;
        if (patch.text === "reject") throw new MutationRejected("entry.denied");
        await tx.entry.update({
          where: identity,
          data: { ...patch, ...(typeof patch.text === "string" ? { text: patch.text.trim() } : {}) },
        });
        notify({ channel: "book:demo", records: [input.entry] });
      },
    },
    loaders: {
      async entry({ ids, tx }) {
        return Promise.all(ids.map((identity) => tx.entry.findUnique({ where: identity })));
      },
    },
```

delete `principalChannel` and `authorize`, and change `backend.publish(tx, [{ model: "Entry", identity: { id: "entry-1" } }], ["book:demo"])` in `initialize()` to `backend.notify(tx, { channel: "book:demo", records: [{ model: "Entry", identity: { id: "entry-1" } }] })`.

- [ ] **Step 5: Run the suites**

Run: `bash integration/persistence/server/run.sh`
Expected: PASS.

Run: `npm run typecheck && bash integration/e2e/run.sh`
Expected: PASS. (The e2e test's `denied.status === 403` assertion for the `private` channel must be removed: no channel guard exists.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(server): single call object, notify, checkpoint from notified channel"
```

---

### Task 4: Compiler emits `backend.ts`

**Files:**
- Modify: `crates/compiler/src/emit.rs`
- Modify: `crates/compiler/src/main.rs`
- Modify: `crates/compiler/src/lib.rs` (re-export)
- Modify: `crates/compiler/tests/compiler.rs`
- Modify: `crates/compiler/tests/cli.rs`
- Create: `integration/generated-api/backend-missing.ts`
- Create: `integration/generated-api/backend-complete.ts`
- Modify: `integration/generated-api/verify.sh`, `integration/generated-api/tsconfig.json`
- Modify: `scripts/test.sh`, `examples/rust-round-trip/run.sh` (compile flags)

**Interfaces:**
- Produces: `otter_compiler::backend_typescript(v: &Value, runtime_import: &str) -> String`.
- Produces: CLI flag `--backend-runtime SPEC` (default `@ottersync/server`), written into `backend.ts` import specifiers.
- Produces: `generated/backend.ts` exporting `schema`, `<Mutation>Input` interfaces, `Handlers<Tx>`, `Loaders<Tx>`, one reference constructor per model, `createBackend`, and re-exports `MutationRejected`, `devAuth`, `HandlerCall`, `LoaderCall`, `RecordRef` plus the record/identity/patch types.
- Consumes: `createBackend`, `BackendOptions`, `HandlerCall`, `LoaderCall`, `RecordRef`, `MutationRejected`, `devAuth` from Task 3's server package.

- [ ] **Step 1: Write the failing compiler tests**

Append to `crates/compiler/tests/compiler.rs`:

```rust
#[test]
fn backend_emitter_declares_handlers_loaders_and_references() {
    let v = compile(include_str!("../../../fixtures/compiler/relations.model")).unwrap();
    let ts = otter_compiler::backend_typescript(&v, "@ottersync/server");
    assert!(ts.contains("from \"@ottersync/server\""));
    assert!(ts.contains("export interface Handlers<Tx> {"));
    assert!(ts.contains(" addBook(call: HandlerCall<Tx, AddBookInput>): Promise<void | { channel: string }>;"));
    assert!(ts.contains(" addComment(call: HandlerCall<Tx, AddCommentInput>): Promise<void | { channel: string }>;"));
    assert!(ts.contains("export interface Loaders<Tx> {"));
    assert!(ts.contains(" book(call: LoaderCall<Tx, BookIdentity>): Promise<readonly (Book | null)[]>;"));
    assert!(ts.contains("export function Book(identity: BookIdentity): RecordRef { return { model: \"Book\", identity }; }"));
    assert!(ts.contains("export interface AddBookInput {\n book: Book;\n}"));
    assert!(ts.contains("export function createBackend<Tx>("));
    assert!(!otter_compiler::typescript(&v).contains("backendConfig"));
}
#[test]
fn backend_emitter_suffixes_older_mutation_versions() {
    let v = compile("model A { id String title String @@id(id) } mutation Edit { a A.update<title> @@version(2) }").unwrap();
    let mut with_history = v.clone();
    let mut old = v["mutations"][0].clone();
    old["version"] = serde_json::json!(1);
    with_history["backendMutations"] = serde_json::json!([old, v["mutations"][0].clone()]);
    let ts = otter_compiler::backend_typescript(&with_history, "@ottersync/server");
    assert!(ts.contains(" edit(call: HandlerCall<Tx, EditInput>)"));
    assert!(ts.contains(" editV1(call: HandlerCall<Tx, EditV1Input>)"));
}
```

- [ ] **Step 2: Run to see them fail**

Run: `.tools/cargo/bin/cargo test -p otter-compiler --test compiler`
Expected: FAIL, `backend_typescript` not found.

- [ ] **Step 3: Implement the emitter**

In `crates/compiler/src/emit.rs`, remove the `backendConfig` emission from `typescript()`:

```rust
    let mut backend = v.clone();
    if let Some(history) = v.get("backendMutations") {
        backend["mutations"] = history.clone();
        backend.as_object_mut().unwrap().remove("backendMutations");
    }
    writeln!(o, "export const backendConfig = {} as const;", backend).unwrap();
```

(delete those lines) and add:

```rust
fn slot_input_type(slot: &Value) -> String {
    let model = s(slot, "model");
    let one = match s(slot, "operation") {
        "create" => model.to_string(),
        "delete" => format!("{{ identity: {model}Identity }}"),
        _ => {
            let patch = match slot["allowedPatchFields"].as_array() {
                Some(a) if a.is_empty() => format!("Pick<{model}Patch, never>"),
                Some(a) => format!(
                    "Pick<{model}Patch, {}>",
                    a.iter().map(Value::to_string).collect::<Vec<_>>().join(" | ")
                ),
                None => format!("{model}Patch"),
            };
            format!("{{ identity: {model}Identity; patch: {patch} }}")
        }
    };
    match s(slot, "cardinality") {
        "list" => format!("{one}[]"),
        "optional" => format!("{one} | null"),
        _ => one,
    }
}

/// Backend surface bound to the compiled schema. `runtime` is the import specifier of `@ottersync/server`.
pub fn backend_typescript(v: &Value, runtime: &str) -> String {
    let mut o = String::from("// Generated by otter-sync. Do not edit.\n");
    writeln!(o, "import {{ createBackend as createRuntimeBackend, type BackendOptions, type HandlerCall, type LoaderCall, type RecordRef }} from \"{runtime}\";").unwrap();
    writeln!(o, "export {{ MutationRejected, devAuth, type HandlerCall, type LoaderCall, type RecordRef }} from \"{runtime}\";").unwrap();
    let models = arr(&v["schema"], "models");
    let names: Vec<String> = models
        .iter()
        .flat_map(|m| {
            let n = s(m, "name");
            [format!("{n} as {n}Record"), format!("{n}Identity"), format!("{n}Patch")]
        })
        .collect();
    writeln!(o, "import type {{ {} }} from \"./generated.ts\";", names.join(", ")).unwrap();
    for m in models {
        let n = s(m, "name");
        writeln!(o, "export type {n} = {n}Record;").unwrap();
        writeln!(o, "export type {{ {n}Identity, {n}Patch }};").unwrap();
        writeln!(o, "export function {n}(identity: {n}Identity): RecordRef {{ return {{ model: \"{n}\", identity }}; }}").unwrap();
    }
    let mut backend = v.clone();
    if let Some(history) = v.get("backendMutations") {
        backend["mutations"] = history.clone();
        backend.as_object_mut().unwrap().remove("backendMutations");
    }
    writeln!(o, "export const schema = {} as const;", backend).unwrap();
    let mutations = arr(&backend, "mutations");
    let latest = |name: &str| mutations.iter().filter(|m| s(m, "name") == name).map(|m| m["version"].as_u64().unwrap()).max().unwrap();
    let key = |m: &Value| {
        let n = s(m, "name");
        let ver = m["version"].as_u64().unwrap();
        if ver == latest(n) { lower(n) } else { format!("{}V{ver}", lower(n)) }
    };
    let input_name = |m: &Value| {
        let n = s(m, "name");
        let ver = m["version"].as_u64().unwrap();
        if ver == latest(n) { format!("{n}Input") } else { format!("{n}V{ver}Input") }
    };
    for m in mutations {
        writeln!(o, "export interface {} {{", input_name(m)).unwrap();
        for slot in arr(m, "slots") {
            writeln!(o, " {}: {};", s(slot, "name"), slot_input_type(slot)).unwrap();
        }
        o.push_str("}\n");
    }
    o.push_str("export interface Handlers<Tx> {\n");
    for m in mutations {
        writeln!(o, " {}(call: HandlerCall<Tx, {}>): Promise<void | {{ channel: string }}>;", key(m), input_name(m)).unwrap();
    }
    o.push_str("}\n");
    o.push_str("export interface Loaders<Tx> {\n");
    for m in models {
        let n = s(m, "name");
        writeln!(o, " {}(call: LoaderCall<Tx, {n}Identity>): Promise<readonly ({n} | null)[]>;", lower(n)).unwrap();
    }
    o.push_str("}\n");
    o.push_str("export type Options<Tx> = Omit<BackendOptions<Tx>, \"config\" | \"handlers\" | \"loaders\"> & { handlers: Handlers<Tx>; loaders: Loaders<Tx> };\n");
    o.push_str("export function createBackend<Tx>(options: Options<Tx>) {\n return createRuntimeBackend<Tx>({ ...options, config: schema, handlers: options.handlers as unknown as BackendOptions<Tx>[\"handlers\"], loaders: options.loaders as unknown as BackendOptions<Tx>[\"loaders\"] });\n}\n");
    o
}
```

`lower` is the existing helper at `emit.rs:9` (first character lower-cased). In `crates/compiler/src/lib.rs` extend `pub use emit::{dart, typescript};` to `pub use emit::{backend_typescript, dart, typescript};`.

- [ ] **Step 4: Run the compiler tests**

Run: `.tools/cargo/bin/cargo test -p otter-compiler --test compiler`
Expected: PASS.

- [ ] **Step 5: Write `backend.ts` from the CLI with a `--backend-runtime` flag**

In `crates/compiler/src/main.rs`:

Add `let mut backend_runtime = String::from("@ottersync/server");` next to `let mut explicit_history = false;`. In the option loop, extend the match arm so it reads

```rust
            "--mutation-history" | "--schema-fence" | "--backend-runtime" => {
                let value = args.get(index + 1).ok_or("missing option value")?;
                match args[index].as_str() {
                    "--mutation-history" => {
                        history_path = PathBuf::from(value);
                        explicit_history = true;
                    }
                    "--schema-fence" => fence_path = PathBuf::from(value),
                    _ => backend_runtime = value.clone(),
                }
                index += 1;
            }
```

Add to the `files` array, after the `generated.ts` entry:

```rust
        (
            out.join("backend.ts"),
            otter_compiler::backend_typescript(&config, &backend_runtime),
        ),
```

Extend the usage string to `usage: otter-sync compile INPUT_DIR OUTPUT_DIR [--mutation-history FILE] [--initialize-mutation-history] [--schema-fence FILE] [--backend-runtime SPEC]`.

Append to `crates/compiler/tests/cli.rs`:

```rust
#[test]
fn cli_writes_backend_ts_with_the_requested_runtime_import() {
    let root = std::env::temp_dir().join(format!("otter-compiler-backend-{}", std::process::id()));
    let input = root.join("input");
    let out = root.join("out");
    fs::create_dir_all(&input).unwrap();
    fs::write(
        input.join("test.model"),
        "model A { id UUID title String @@id(id) } mutation Save { a A.create }",
    )
    .unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_otter-sync"))
        .arg("compile")
        .arg(&input)
        .arg(&out)
        .arg("--backend-runtime")
        .arg("../../packages/server/index.mts")
        .status()
        .unwrap();
    assert!(status.success());
    let backend = fs::read_to_string(out.join("backend.ts")).unwrap();
    assert!(backend.contains("from \"../../packages/server/index.mts\""));
    assert!(backend.contains(" save(call: HandlerCall<Tx, SaveInput>)"));
    assert!(backend.contains(" a(call: LoaderCall<Tx, AIdentity>)"));
    fs::remove_dir_all(root).unwrap();
}
```

Run: `.tools/cargo/bin/cargo test -p otter-compiler`
Expected: PASS.

- [ ] **Step 6: Typecheck the generated backend, positive and negative**

Create `integration/generated-api/backend-complete.ts`:

```ts
import { createBackend, devAuth, type Handlers, type Loaders } from "./backend.ts";
type Tx = { rows: Map<string, object> };
export const handlers: Handlers<Tx> = {
  async createEntry({ input, notify }) { notify({ channel: "c", records: [input.entry] }); },
  async editEntry({ input, notify }) { notify({ channel: "c", records: [input.entry] }); },
  async removeEntries({ input, notify }) { notify({ channel: "c", records: input.entries }); },
  async addBook({ input, notify }) { notify({ channel: "c", records: [input.book] }); },
  async addComment({ input, notify }) { notify({ channel: "c", records: [input.comment] }); },
};
export const loaders: Loaders<Tx> = {
  async entry({ ids }) { return ids.map(() => null); },
  async book({ ids }) { return ids.map(() => null); },
  async comment({ ids }) { return ids.map(() => null); },
  async counter({ ids }) { return ids.map(() => null); },
};
export const backend = createBackend<Tx>({
  database: { transaction: async (body) => body({ rows: new Map() }), persistence: () => ({ call: async () => null }) },
  authenticate: devAuth(),
  handlers,
  loaders,
  native: { validateConfig() {}, processPush: async () => "", processPull: async () => "", publish: async () => "", negotiateLive: async () => "", pullLive: async () => "" },
});
```

These names match `fixtures/compiler/*.model` exactly: mutations `CreateEntry`, `EditEntry` (only version 2 exists in `integration/generated-api/mutation-history.json`, so there is no `editEntryV1`), `RemoveEntries`, `AddBook`, `AddComment`; models `Entry`, `Book`, `Comment`, `Counter`. `RemoveEntries` has a list slot `entries` and an optional slot `maybe`, so `input.entries` is already an array and `input.maybe` may be null.

Create `integration/generated-api/backend-missing.ts` as a copy of the handlers object above **without** `addComment`, typed `Handlers<Tx>`.

Add `"backend-complete.ts"` to the `include` of `integration/generated-api/tsconfig.json`. Append to `integration/generated-api/verify.sh` after the existing `tsc -p` line:

```sh
if "$root/node_modules/.bin/tsc" --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --strict --skipLibCheck --allowImportingTsExtensions integration/generated-api/backend-missing.ts >/dev/null 2>&1; then
  echo 'A handlers object missing a mutation unexpectedly typechecked.' >&2
  exit 1
fi
```

Change the compile lines to pass the runtime path:

- `integration/generated-api/verify.sh`: `cargo run -p otter-compiler -- compile fixtures/compiler integration/generated-api --backend-runtime ../../packages/server/index.mts`
- `scripts/test.sh` and `examples/rust-round-trip/run.sh`: `... compile examples/rust-round-trip/models examples/rust-round-trip/generated --backend-runtime ../../../packages/server/index.mts`

Run: `bash integration/generated-api/verify.sh`
Expected: PASS, including the negative check.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(compiler): emit backend.ts with typed Handlers, Loaders and a bound createBackend"
```

---

### Task 5: Remove the Nest package

**Files:**
- Delete: `packages/nest/`, `integration/nest/`
- Modify: `scripts/test.sh:17-18`
- Modify: `README.md:36`, `docs/architecture/code-organization.md:41,103`, `docs/implementation-progress.md:13,34,59`, `website/mkdocs.yml:59`, `website/prepare.py:18`, `website/content/index.md:60`

- [ ] **Step 1: Delete the packages and the test steps**

```bash
git rm -r -q packages/nest integration/nest
```

Remove from `scripts/test.sh`:

```sh
(cd packages/nest && npm ci)
(cd integration/nest && npm ci && npm test)
```

- [ ] **Step 2: Remove documentation references**

- `README.md`: in the Packages table drop `, [Nest](packages/nest/README.md)`.
- `docs/architecture/code-organization.md`: delete the `nest/` tree line and the bullet `Nest depends on the server facade; the server facade does not depend on Nest.`
- `docs/implementation-progress.md`: remove `ordinary registration and Nest decorators` from the Integration row, delete the `| Nest | 5 runtime tests ... |` row, and in the dependency audit sentence remove `and the updated Nest 11.2.3 package/test dependency sets`.
- `website/mkdocs.yml`: delete `      - Nest: packages/nest/README.md`.
- `website/prepare.py`: delete `'packages/nest/README.md', ` from the `PAGES` tuple.
- `website/content/index.md`: delete ` · [Nest integration](packages/nest/README.md)`.

- [ ] **Step 3: Verify the docs build and the gate script still parse**

Run: `website/.venv/bin/python website/prepare.py && website/.venv/bin/python -m mkdocs build --strict -f website/mkdocs.yml` (create the venv per `website/README.md` if missing)
Expected: builds with no warnings.

Run: `bash -n scripts/test.sh`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove the Nest integration package"
```

---

### Task 6: Rewrite the example, the e2e test and the guides

**Files:**
- Modify: `examples/rust-round-trip/server.mts`
- Modify: `examples/rust-round-trip/README.md`
- Modify: `integration/e2e/round-trip.test.mjs`
- Modify: `packages/server/README.md`, `packages/persistence-prisma/README.md`, `website/content/concepts.md`, `docs/architecture/concepts-and-naming.md`

**Interfaces:**
- Produces: `createExample()` returning `{ db, backend, schema, initialize(), listen(port), close(), handlerCalls }` where `listen(port)` resolves to `{ url, close }`.
- Consumes: `generated/backend.ts` from Task 4; server surface from Task 3.

- [ ] **Step 1: Rewrite `examples/rust-round-trip/server.mts`**

```ts
import { PrismaClient, type Prisma } from "@prisma/client";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { prisma } from "../../packages/persistence-prisma/index.mts";
import {
  createBackend,
  devAuth,
  MutationRejected,
  type Handlers,
  type Loaders,
} from "./generated/backend.ts";
import { schema } from "./generated/generated.ts";

type Tx = Prisma.TransactionClient;

export async function createExample() {
  const db = new PrismaClient();
  let calls = 0;
  const handlers: Handlers<Tx> = {
    async edit({ input, tx, notify }) {
      calls++;
      const { identity, patch } = input.entry;
      if (patch.text === "reject") throw new MutationRejected("entry.denied");
      await tx.entry.update({
        where: identity,
        data: { ...patch, ...(typeof patch.text === "string" ? { text: patch.text.trim() } : {}) },
      });
      notify({ channel: "book:demo", records: [input.entry] });
    },
  };
  const loaders: Loaders<Tx> = {
    async entry({ ids, tx }) {
      return Promise.all(ids.map((identity) => tx.entry.findUnique({ where: identity })));
    },
  };
  const backend = createBackend<Tx>({
    database: prisma(db),
    authenticate: devAuth(),
    handlers,
    loaders,
  });
  return {
    db,
    backend,
    schema,
    get handlerCalls() {
      return calls;
    },
    async initialize() {
      const migration = await readFile(
        new URL("../../packages/persistence-prisma/migration.sql", import.meta.url),
        "utf8",
      );
      for (const sql of migration.split(";").map((s) => s.trim()).filter(Boolean))
        await db.$executeRawUnsafe(sql);
      await db.$executeRawUnsafe(
        'CREATE TABLE IF NOT EXISTS "Entry" (id TEXT PRIMARY KEY,text TEXT NOT NULL,note TEXT)',
      );
      await db.$transaction(async (tx) => {
        await tx.entry.upsert({
          where: { id: "entry-1" },
          create: { id: "entry-1", text: "Hello from the server" },
          update: {},
        });
        await backend.notify(tx, {
          channel: "book:demo",
          records: [{ model: "Entry", identity: { id: "entry-1" } }],
        });
      });
    },
    listen(port: number) {
      return backend.listen({ port });
    },
    async close() {
      await db.$disconnect();
    },
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = await createExample();
  await app.initialize();
  const server = await app.listen(Number(process.env.PORT ?? 4242));
  console.log(`Example listening at ${server.url}`);
  for (const signal of ["SIGINT", "SIGTERM"] as const)
    process.once(signal, () => void server.close().then(() => app.close()));
}
```

- [ ] **Step 2: Update the e2e test**

In `integration/e2e/round-trip.test.mjs`:

- Replace `await new Promise(resolve=>app.http.listen(0,'127.0.0.1',resolve));const url=\`http://127.0.0.1:${app.http.address().port}\`;` with `const server=await app.listen(0);const url=server.url;`.
- Delete the assertion block that expects `403` for the `private` channel (there is no channel guard).
- In the `finally`, call `await server?.close();` before `await app.close();` (declare `let server;` next to `let client;`).

- [ ] **Step 3: Run the example flows**

Run: `npm run typecheck && bash integration/e2e/run.sh`
Expected: PASS.

Run: `bash examples/rust-round-trip/run.sh` in one terminal, `node examples/rust-round-trip/client.mts` in another; type `edit   hello   `, `sync`, `show`, then `edit reject`, `sync`, `show`, then `quit`. Expected: trimmed text after the first sync, unchanged text plus a rejection after the second. Stop the server with Ctrl-C.

- [ ] **Step 4: Update the guides**

`packages/server/README.md`: replace the whole file with a guide that shows, in this order: the `.model` file, `handlers.ts`, `loaders.ts`, `main.ts` with `createBackend({ database: prisma(db), authenticate, handlers, loaders })` and `listen({ port })`; a section "Call objects" listing `HandlerCall` and `LoaderCall` fields; a section "notify" with the `{ channel, records }` shape, `Book({ id })` references and the checkpoint rules (one channel automatic, several need `return { channel }`, none is `handler.no_channel`); a section "Authentication" describing `authenticate` and `devAuth()`; a section "Background jobs" with `backend.notify(tx, ...)` and `bindTransaction(tx).notify(...)`; keep the existing "Transaction ownership", "Mutation results", "Loaders and Pull" paragraphs with `publish` replaced by `notify` and `channel` removed from loader context. Delete the "HTTP requests" and "Live notifications" sections; replace with two sentences about `listen({ port, host })` serving `/sync/mutations`, `/sync/pull` and `/sync/live`.

`packages/persistence-prisma/index.mts` README (`packages/persistence-prisma/README.md`): add a first paragraph `prisma(client)` returns the `database` option for `createBackend`; `PrismaPersistence` and `prismaTransactions` remain for custom adapters.

`website/content/concepts.md`: replace `Publish` with `Notify` in the primitive table and prose (`Handler`, `Loader`, `Notify`), and delete `viewer/channel` wording from the Loader row so it reads "Return current, complete, visible state for the requested identities, in their supplied order. Return null for missing or unauthorized rows."

`docs/architecture/concepts-and-naming.md`: add a line under the accepted names: `Notify` replaces the earlier `Publish` for the handler-side invalidation call; the wire and storage vocabulary is unchanged.

`examples/rust-round-trip/README.md`: replace the `server.mts` bullet text with "handlers and loaders implementing the generated `Handlers` and `Loaders` interfaces; `createBackend` from `generated/backend.ts`; `listen` serves HTTP and WebSocket on one port."

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(example): rewrite the round trip backend on the generated surface"
```

---

### Task 7: Full gate and implementation record

**Files:**
- Modify: `docs/implementation-progress.md`
- Modify: `docs/next-things.md`

- [ ] **Step 1: Run the complete gate**

Run: `bash scripts/test.sh`
Expected: exit 0. Record the per-suite counts printed at the end of each `node --test` run and each `cargo test` run.

- [ ] **Step 2: Update the implementation record**

In `docs/implementation-progress.md`:

- Backend row of the "Implemented" table: replace with `Generic Rust Push/Pull/notification state machines, application-owned transaction callbacks, per-mutation savepoints, durable batch receipts and coherent Loader snapshots. Handlers and Loaders implement compiler-generated interfaces; notify from handlers selects receipt checkpoints.`
- Compiler row: add `and generated/backend.ts with typed Handlers, Loaders and a bound createBackend`.
- Verification table: update the `Native backend + PostgreSQL + HTTP/WS` count to the number observed in Step 1 and add a row `Generated backend typecheck | positive fixture compiles; a handlers object missing one mutation fails to compile`.
- Add a paragraph under "Platform and release boundaries": `The backend serves its own HTTP and WebSocket endpoints through listen(); mounting on an application-owned server and the former Nest adapter were removed on 2026-09-12 (see the backend setup design record).`

In `docs/next-things.md`, under "之后再做", add: `- [ ] 客户端 openClient：一步打开、内置 transport；和后端 createBackend 对称。` and `- [ ] authenticate 目前接收 Node IncomingMessage；支持其他运行时时需要抽象请求类型。`

- [ ] **Step 3: Commit and push**

```bash
git add -A
git commit -m "docs: record the backend setup redesign verification"
git push -u origin refactor/backend-setup
```

Open a pull request against `main` titled `Backend setup redesign` whose body links `docs/superpowers/specs/2026-09-12-backend-setup-design.md`, lists the removed public surface, and closes GitHub issue #5.
