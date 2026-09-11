# local-first-state Rust Rebuild Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to execute the accepted milestone task-by-task. Do not start runtime implementation from this proposal until the architecture decisions are reviewed. No sub-agent work is required. Checkboxes track future implementation, not work completed while writing this plan.

**Goal:** 从零交付共用 Rust 协议与状态机的 local-first-state，保留自然的 Dart/TypeScript 业务接口与用户事务控制。

**Architecture:** Rust client/server runtime 共享 schema、wire、operation semantics。宿主通过 typed ports 执行业务 handler/materializer、事务内持久化和网络 I/O。第一闭环采用 Dart native、Rust SQLite、Node binding、Prisma/PostgreSQL。

**Tech Stack:** Rust workspace；SQLite；PostgreSQL；Node/TypeScript；Dart。NAPI-RS、flutter_rust_bridge、rusqlite 是 spike 候选；实际版本完成构建验证后写入 lockfile/toolchain。unadapter 不作为正确性前提。

## Global Constraints

- 项目名称 `local-first-state`；GitHub 保持 private；不自动发布 package。
- 用户拥有 backend transaction；框架只使用绑定该 transaction 的 persistence。
- publish 必须明确 scopes；不引入 ambient scope 或强制 scope/model 一对一。
- 共同算法放在 Rust；SDK 不能自己实现 ACK settlement、record conflict 或 replay。
- 不在本轮执行重写；本计划是架构提案配套的实施路线。
- 旧参考源码保存在 main 和历史提交；用户已授权在新分支删除旧实现。不改 Oasis，不清空实际客户端队列，不修改生产 DB。
- 所有新测试使用临时 SQLite 和本轮创建的隔离 Postgres，不能读取生产 DATABASE_URL。
- 大的未定协议先通过场景定稿；每个后续 milestone 单独细化为可执行任务，不用虚构完整代码掩盖未定设计。

---

## 1. 阅读顺序与工作目录

1. 先读 [架构提案](../specs/2026-09-10-rust-core-design.md)。
2. 用 [逻辑覆盖表](../specs/2026-09-10-existing-logic-audit.md) 检查遗漏。
3. 按此计划的 gate 顺序执行，不先从头翻译 compiler。

当前实现 worktree：`/Users/stevewang/Github/local first state/.worktrees/rust-rebuild`，branch `codex/rust-rebuild`。用户已授权从零实现并在该分支清除旧代码；旧实现以 main/参考提交保存。目录边界以 [代码组织](../../architecture/code-organization.md) 为准。

以下新路径相对该 worktree 根目录；都是未来创建位置，当前只交付文档。

```text
Cargo.toml                         workspace，随第一个 Rust 测试一起建立
rust-toolchain.toml                spike 通过后固定工具链
crates/lfs-core/src/               schema、value、identity、operation、protocol
crates/lfs-client/src/             projection、queue、scope、settlement、query
crates/lfs-server/src/             mutation、publish、materialize、host ports
crates/lfs-sqlite/src/             local DB actor/session/storage
bindings/node/src/               Node binding
bindings/dart/src/               Dart binding
crates/lfs-compiler/src/           后期 compiler 迁移
packages/server/src/              TypeScript facade / host dispatcher
packages/persistence-prisma/src/   transactional Postgres adapter
packages/nest/src/                decorators / provider discovery
packages/dart/                    Dart facade
packages/client-js/               后期 JS/browser facade
examples/rust-round-trip/          独立完整示例
fixtures/protocol-v2/              公共 wire/schema vectors
fixtures/scenarios/                人类可读交错时序及预期状态
integration/                      真实 DB / bridge / E2E
```

不要因为目录列出就一次 scaffold 所有 package。每个新 crate/package 随其第一个可验证交付创建。Rust runtime 只读取通用 schema metadata，不生成或链接业务 model 类型；代码组织文档定义了新增 model 不重编 Rust 的验收测试。

## 2. 总体阶段与退出条件

| 阶段 | 交付 | 进入下一阶段前的证明 |
|---|---|---|
| M0 决策与 bridge 可行性 | 对齐关键语义；Node tx、Dart SQLite 两个最小 spike | 同事务 rollback、重复请求、超时、dispose 都可观察验证 |
| M1 最小完整闭环 | UpdateEntry，单 scope，真实业务表、持久化 queue、ACK/downlink | 断网修改、重启、ACK 乱序、拒绝、lost response 全通过 |
| M2 多 scope 与权威版本 | overlap、Move、remove/delete、snapshot、visibility recovery | A/B 乱序不能回滚内容；删除不复活；settlement coverage 正确 |
| M3 现有高级客户端行为 | cascade、companion、dependencies、readiness、query/watch、batch | 覆盖表所有 runtime 行有测试；明确所有 intentional differences |
| M4 compiler 与 SDK DX | Rust compiler、Dart/TS types、Nest decorators、migration contracts | generated code 无算法；历史 mutation 可重放；类型误用编译失败 |
| M5 平台与开放发布准备 | Dart mobile、Node 部署、JS/Web 验证、文档、独立示例 | 干净机器安装可跑；恢复/存储边界明确；license 决策完成 |

不把这些阶段换算成未经验证的精确工期。M0 的 bridge 和 transaction 结果决定后面是否调整实现方式。

## 3. M0：先证明最危险的边界

### Task 0.1 — 将关键设计决定变成可评审的场景

**Files:** `fixtures/scenarios/transaction-boundary.md`、`fixtures/scenarios/settlement-order.md`、`fixtures/scenarios/scope-overlap.md`。

**输入:** 本设计 §7/9/10。**输出:** 固定的 protocol-v2 语义，后续测试按这些场景实现。

- [ ] 写出以下时序的预期 DB 状态，不先实现代码。
- [ ] 确认按 mutation receipt 是接受的新行为；若保留旧 batch 原子性，统一修改设计及后续 API。
- [ ] 确认 recordRevision 默认存在、wire decimal strings、新旧 storage 不直接混用。
- [ ] 将确认后的文档单独提交，作为实现基准。

场景 A：M1 accepted commit，M2 handler unknown error。推荐结果：M1 的业务/receipt/publication 均保留；M2 全 rollback；重试 M1 不再执行业务。若需要 M1+M2 必须同生共死，应用应定义为一条多操作 mutation。

场景 B：base.text=A，M1→B，M2→C；M1 ACK 需要 scope:11，先收到 scope:10，再 11；可见 text 始终 C；11 只允许结算已证明落地的 M1，M2 继续 pending。

场景 C：同 record 从 A scope 取到 rev10 延迟，B scope rev11 先到；最终 rev11。A 的 membership 能独立建立；旧内容不得覆盖。remove(A) 不删除 B 提供的记录；delete(rev12) 必须阻止 rev10/11 复活。

### Task 0.2 — Node bridge 加入真实 Prisma transaction

**Create:** `bindings/node/src/transaction_probe.rs`、`packages/persistence-prisma/src/transaction-session.ts`、`integration/node/transaction-bridge.test.ts`、`integration/node/schema.prisma`。

**接口形状（spike 专用，不是正式 SDK）:**

```ts
type TxProbe = {
  writeFrameworkRow(): Promise<void>;
  readFrameworkCount(): Promise<number>;
};
// Rust 调用 host callback 并等待所有 Promise；返回发生在用户 commit 之前。
declare function runRustProbe(host: TxProbe): Promise<{ observed: number }>;
```

验收测试主体：

```ts
await expect(prisma.$transaction(async tx => {
  await tx.businessProbe.create({ data: { id: 'rollback-case' } });
  const result = await runRustProbe({
    writeFrameworkRow: async () => {
      await tx.frameworkProbe.create({ data: { id: 'rollback-case' } });
    },
    readFrameworkCount: () => tx.frameworkProbe.count(),
  });
  expect(result.observed).toBe(1);
  throw new Error('force rollback');
})).rejects.toThrow('force rollback');
expect(await prisma.businessProbe.count()).toBe(0);
expect(await prisma.frameworkProbe.count()).toBe(0);
```

- [ ] 建立隔离 Postgres、两张 probe 表和 Node test harness；先测试错误地使用全局 client 的实现确实被此断言识别。
- [ ] 实现 Rust→JS async callback→Rust 返回链；不能使用另一个 Rust DB pool。
- [ ] 加入 callback rejection、Rust error、ORM timeout、runtime dispose 和多个并发 transaction；不同 handle 不可串写。
- [ ] 在 tx 结束后再调用保存的 host handle，必须返回 `transaction_closed`，无 DB 操作。
- [ ] 测试外层 commit 失败时 HTTP 层绝不生成 accepted ACK。
- [ ] 记录每个 mutation callback 数量、序列化字节和 bridge 耗时；不据微基准宣布 Rust 更快。
- [ ] 固定可工作的 binding/runtime 版本并提交。

**运行目标:** `node --test integration/node/transaction-bridge.test.mjs`（测试源码的构建步骤与 harness 同步提供）。不装完整产品依赖；失败时先定位桥接层，不改成独立事务绕过。

### Task 0.3 — Dart ↔ Rust SQLite transaction session

**Create:** `crates/lfs-sqlite/src/session.rs`、`bindings/dart/src/api.rs`、`integration/dart/transaction_bridge_test.dart`。

**接口契约:** open runtime；begin session；session 内 query/apply；commit/rollback；watch committed changes；close。session 必须有唯一 handle 与结束状态。

- [ ] 写测试：session 内写入后读得到，session 外 watcher 在 commit 前看不到；rollback 后 DB 恢复。
- [ ] 写测试：外层直接写入 + 内层 mutation savepoint 失败，只回滚该 mutation；外层可继续提交。
- [ ] Rust worker 拥有 SQLite；Dart Future 不阻塞 UI isolate。
- [ ] 提交后收到一次一致结果；rollback 不发送中间结果；close 结束 watcher。
- [ ] 进程重开读取 committed rows；未提交 session 不残留半条 mutation。
- [ ] 记录跨 binding 的 integer/null/bytes/Unicode/error 行为，固定第一组 ABI vectors。

**运行目标:** `dart test integration/dart/transaction_bridge_test.dart`，实际 package/test 路径由该 harness 的 pubspec 定义。使用临时文件 DB；不是只测 in-memory reducer。

**M0 判定:** 若两条 bridge 中任一无法可靠地保持生命周期和事务语义，暂停扩展；可改 binding 机制（例如 suspend/resume），不可降低 atomicity 承诺。只有 architecture adjustment 被记录后才继续。

## 4. M1：第一个有用的完整闭环

第一版示例：两位 viewer 共享一个 Book scope；一张 Entry 业务表；UpdateEntry 具名 mutation；Dart native client 本地 SQLite。暂不做媒体、Move、compiler 重写或浏览器。

### Task 1.1 — 公共 value/identity/protocol kernel

**Create:** `crates/lfs-core/src/{value,identity,operation,protocol,error}.rs`、`crates/lfs-core/tests/wire_vectors.rs`、`fixtures/protocol-v2/`。

**输出:** `RecordKey`、`MutationKey`、`MutationEnvelope`、`Receipt`、`ScopeCheckpoint`、`DownlinkPage`、`RecordChange`、typed errors。所有生产者/消费者从此处导入，不重新定义字段意义。

建议 wire 示例：

```json
{
  "protocolVersion": 2,
  "scope": "Book:example",
  "epoch": "example-generation",
  "from": "10",
  "through": "11",
  "changes": [{
    "cursor": "11",
    "kind": "upsert",
    "model": "Entry",
    "identity": {"id": "entry-1"},
    "revision": "7",
    "state": {"text": "server value"}
  }]
}
```

此示例的 string identity 用于协议级测试；正式生成 schema 的 UUID 模型需使用有效 UUID。

- [ ] 固定 counter 范围、canonical hash、unknown field/version、UUID、datetime、patch absent/null。
- [ ] 先写 golden vectors 和拒绝 vectors：负 cursor、overflow、重复 key、非法 float、scope mismatch、未知 epoch。
- [ ] 实现 codec/normalization；单元测试和 Node/Dart ABI 同读 vectors。
- [ ] 提交 kernel 与 vectors；不在 SDK 复制解析规则。

**验证:** `cargo test -p lfs-core`；另执行 M0 两种 binding 的 value tests。

### Task 1.2 — 本地 apply/replay 与持久化 queue

**Create:** `crates/lfs-client/src/{projection,queue,mutation}.rs`、`crates/lfs-sqlite/src/{schema,client_store}.rs`、`crates/lfs-client/tests/optimistic_replay.rs`。

**输入:** core operations、M0 ClientStore session。**输出:** 在一个 SQLite transaction 内 apply visible state + base + durable pending intent。

- [ ] 写测试：base A→enqueue B→visible B；重开仍 B 且队列仍有 M1。
- [ ] 写测试：M1 改 text，远端改另一个字段；replay 只覆盖 M1 修改的字段。
- [ ] 写测试：create/update/delete、absent/null、同 row 多 mutation；失败不留下 queue-only 或 main-only 状态。
- [ ] 实现 sparse base 与 reducer；不依赖外部 callback 重放业务代码。
- [ ] 为直接本地写入与 mutation 写入设置不同 fate，禁止误发本地操作。
- [ ] 提交 SQLite schema 和 tests；以数据库内容验证，不只断言内部函数被调用。

**验证:** `cargo test -p lfs-client --test optimistic_replay`、`cargo test -p lfs-sqlite`。

### Task 1.3 — Server persistence 与显式 publish

**Create:** `crates/lfs-server/src/{ports,publish}.rs`、`packages/persistence-prisma/src/{index,publication,receipt,snapshot}.ts`、`integration/postgres/publish.test.ts`。

**输入:** tx-bound host session。**输出:** scoped publication position + record revision，在同一事务持久化。

- [ ] 建立 namespaced framework tables 和 migrations：clients/receipts、scope heads、record revisions、compacted invalidations。
- [ ] 测试同 scope 并发发布得到互异单调 position；rollback 不留 invalidation/head 增量。
- [ ] 测试不同 scope 无框架全局锁；同 record 多 scope 一次 publication 使用同 revision。
- [ ] 测试 counter 耗尽显式失败；重复 identity/scopes 规范化后不多次写入。
- [ ] 实现 snapshot 读取；模拟 concurrent update，禁止 head/revision/state 组合来自不同 snapshot。
- [ ] 实现 commit wake + polling；测试外部 tx 写入、hint 丢失和服务重启。
- [ ] 提交 adapter 及真实 Postgres 测试。

**验证:** package 提供 `npm run test:integration -- publish`；harness 创建/销毁专属 DB。此脚本在 Task 中建立，不假定旧 server package 已有。

### Task 1.4 — 业务 handler 与 durable receipt

**Create:** `crates/lfs-server/src/{mutation,receipt}.rs`、`packages/server/src/{mutation-context,dispatch}.ts`、`integration/postgres/mutation-receipt.test.ts`。

**输入:** mutation envelope、typed dispatcher、绑定的 persistence。**输出:** accepted/rejected receipt；仅外层 commit 成功后可发送。

- [ ] 测试两次并发相同 key/hash 只执行一次业务 callback；相同 key 不同 hash 冲突。
- [ ] 测试业务写入/publication/receipt 任一步故障，全 rollback；用户 catch publication 错误后也不能得到有效 completion 并提交 accepted receipt。
- [ ] 测试明确 rejection 经 savepoint 回滚业务后保存 rejection receipt；未知异常不保存为 rejection。
- [ ] 测试外层事务结束前不能发送 ACK；commit 成功但 response 丢失，重试返回已有 receipt。
- [ ] 测试两条 mutation 的部分成功符合 Task 0.1 的新定义。
- [ ] wrapper 返回 branded completion；未绑定事务、遗漏 callback 完成、tx 已关闭均失败。
- [ ] 提交 runtime/SDK/测试，业务 handler 保持 TS。

**验证:** `cargo test -p lfs-server` 与真实数据库 mutation-receipt integration。

### Task 1.5 — Materializer、downlink、settlement

**Create:** `crates/lfs-server/src/materialize.rs`、`crates/lfs-client/src/{downlink,settlement}.rs`、`packages/server/src/materialize.ts`、`crates/lfs-client/tests/settlement_orders.rs`。

**输入:** snapshot port、materializer dispatcher、receipt/cursor。**输出:** 权威 page 及客户端原子 apply/settle。

- [ ] materializer 一次 batch 返回 unordered records；extra/duplicate 被拒绝，框架匹配 identity。
- [ ] 单 scope checkpoint 覆盖所有 wire prediction；无关 scope 或未发布 record 不能冒充 witness。
- [ ] 测试 ACK→page 与 page→ACK 两个顺序；重启在每个 durable 边界结果相同。
- [ ] 测试 page 中一个 record 损坏，全页回滚，cursor 不变，optimism 不消失。
- [ ] 测试同 row M1/M2 顺序、server normalization、server delete、拒绝后的 rebuild。
- [ ] 测试 repeated/empty/gapped page、cursor-ahead、epoch mismatch、late stale response。
- [ ] 成功后 sparse before-image/queue 清理，剩余 mutation 的基础状态正确。

**验证:** `cargo test -p lfs-client --test settlement_orders`，并通过 SQLite 读回断言。

### Task 1.6 — SDK 与真实示例

**Create:** `examples/rust-round-trip/{README.md,compose.yaml}`、`examples/rust-round-trip/server/`、`examples/rust-round-trip/client/`、`integration/e2e/round-trip.test.ts`。

- [ ] 提供应用自己的 Prisma transaction、一个普通函数 handler、一个 materializer；暂不依赖 Nest。
- [ ] Dart facade 提供 typed read/watch/mutate；事务和操作通过 Rust bridge。
- [ ] HTTP/WS 挂在同一个示例 Node server；协议 bytes 由 Rust 处理。
- [ ] 自动场景：初始 pull→断网修改→关闭重开→上线→丢一次 ACK→重试→等待 downlink→最终 queue/base 清理。
- [ ] 第二场景：server 改写 text；第三场景：server 拒绝；实际 UI/local query 输出必须体现正确结果。
- [ ] 提供只启动本示例资源的脚本，清理只删除自己创建的容器/volume；无需生产账号。
- [ ] 将精确安装、生成、构建、运行、期望输出写入 README；干净目录完整运行一次。

**M1 验收矩阵:**

| 故障点 | 必须观察到 |
|---|---|
| 本地 commit 前崩溃 | 无半条 queue/visible write |
| 本地 commit 后离线 | 重开仍有 optimism 和相同 mutation ID |
| server receipt 写失败 | 业务及 publication 都 rollback |
| server commit 后 ACK 丢失 | 重试不重复业务 |
| ACK 先到 | wire optimism 保留到 checkpoint |
| downlink 先到 | ACK 到来即可从 durable cursor 结算 |
| malformed page | cursor 不动，不误清 optimism |
| 明确拒绝 | mutation 操作完整回滚，拒绝记录可读 |
| 关闭/重新登录 | 旧 session callback 不写新 DB |

M1 只是可验证 alpha 核心，不宣布全部旧能力已替代。

## 5. M2：跨 scope 完整性

**Files:** `crates/lfs-core/src/protocol.rs`、`crates/lfs-client/src/{membership,revision,reset}.rs`、`crates/lfs-server/src/{publish,materialize,settlement}.rs`、`integration/e2e/scope-overlap.test.ts`。

- [ ] 固定 `upsert` / `removeFromScope` / `deleteRecord` 的区别及 materializer 结果语义。
- [ ] 同 record 同 revision 同内容必须幂等；冲突内容必须 blocked，不静默择一。
- [ ] 测试 rev11 先到 rev10 后到；旧内容忽略但 membership 独立处理。
- [ ] 测试 Move A→B→A，交换 old/new 页顺序，插入重连和 process restart。
- [ ] 测试 tombstone 后旧 upsert，旧 tombstone 后新 record revision。
- [ ] 测试 parent removal 不误删仍由其他 scope 提供的 child。
- [ ] 按 model 分组读取 state/revision，验证外部修改必须 publish 的契约。
- [ ] 多 scope witness coverage；sender 没权限订阅其他 recipient scope 也不能永久等待该 scope。
- [ ] 权限撤销、scope reset、generation fencing 的 settlement 恢复必须有真实 E2E。
- [ ] 加 watermark/claims/receipt 行数和体积观测；alpha 保守保留，安全 GC 另立协议 gate。

**退出条件:** 所有到达顺序的最终权威内容一致；任何 malformed/unauthorized/unproven snapshot 都不能被当作成功 barrier。未完成 reset 时不宣称任意离线时长下存储有界。

## 6. M3：完整客户端行为与性能

**Files:** `crates/lfs-client/src/{dependencies,readiness,cascade,companion,query,lifecycle}.rs`，对应 `tests/`；`packages/dart/`、`integration/e2e/`。

按以下顺序逐项交付，每项先迁入独立期望测试，再实现：

1. 多操作 mutation / local direct / companion 同 fate；accepted companion 正确推进本地 base。
2. cascade graph main+before 扫描、拒绝恢复、ancestor mutation 与 child edit 交错。
3. lifecycle dependencies 与 business sequence；独立任务超车；前置拒绝传播差异。
4. prerequisite ready/failed/retry、取消、用户重试/drop、引用清理；上传任务由宿主执行。
5. durable rejection inbox、acknowledge、derived per-record status。
6. durable desired scopes、optimistic subscribe/unsubscribe rollback、自动补齐 pending settlement 所需读取。
7. typed query、relation/inverse、排序/null/limit、watch 初始值/去重/commit-only/关闭；read-only SQL 的写入防护。
8. batch envelope、byte/count 限制、冻结重试、后台 lifecycle、auth refresh、backoff/jitter、bounded queues。

**验证:** 对照覆盖表逐行归属；随机时序 property tests + independent oracle。每 mutation/页不做逐字段 bridge callback，记录 DB round trips、p50/p95、队列10/1000条下的 replay 成本。优化不得改变 durable 边界或查询可见性。

## 7. M4：compiler、API 与 Nest

**Files:** `crates/lfs-compiler/src/{syntax,semantic,history,emit}/`、`packages/nest/src/{decorators,discovery,module}.ts`、`fixtures/schema-evolution/`。

- [ ] 先把现有 compiler 输出规范化为 Rust runtime descriptor，移除 generated 算法依赖。
- [ ] 逐步迁 parser、语义分析、relation graph、slot binding、version history；旧/新 compiler 对同合法定义输出语义等价结果。
- [ ] schema 兼容检查覆盖 model/field 删除、改名、identity、type/nullability，测试新增字段和旧客户端读取。
- [ ] 生成 Dart/TS operation builders 与 backend typed input，保持 absent/null、version snapshots。
- [ ] 业务型 input facade 显式映射底层 slots；不让任意 host callback 成为 Rust replay 的隐式依赖。
- [ ] 加 Nest `@Handles` / `@Materializes` + provider discovery；interface 检查静态类型，decorator 记录运行时 metadata。
- [ ] 启动失败测试：重复 handler、漏注册 model/version、错误 descriptor；普通函数注册仍能使用全部能力。
- [ ] HTTP adapter 挂载用户 server；独立 listen 不是必须运行的第二个服务。

**退出条件:** 一个业务作者可以只读示例完成 model、handler、materializer、publish 集成；所有生成算法 fence 与 ABI 测试通过。新 compiler 不依赖 Oasis。

## 8. M5：平台、迁移、开放准备

- [ ] Dart：macOS 开发、iOS simulator/device、Android emulator/device 的 build/load/restart smoke；精确平台支持表。
- [ ] Node：macOS 与 Linux 的实际 native artifact 安装、生产构建、容器启动；平台矩阵基于验证，不只基于编译成功。
- [ ] JS/Web：WASM 与 browser SQLite/OPFS 或 host storage 的独立 spike；多 tab single-writer、worker、quota、关闭和恢复。未验证前标为未支持。
- [ ] 非 TypeScript backend：独立 Rust host 示例再考虑 SQLx/SeaORM；不承诺从 ORM A 的 tx 自动转换为 ORM B 的 tx。
- [ ] 旧 storage/wire 迁移：选择 drain 或专门迁移器，保护 unsent/frozen/accepted/companion/local-only；不默认删除旧数据库。
- [ ] 协议版本兼容表、breaking changes、故障恢复指南、capacity/retention 说明。
- [ ] CI 分核心、binding、adapter、E2E、package smoke；只保留有独立价值的 conformance，不重复整套算法测试。
- [ ] 作者选择 license；核查分发文件；源代码先公开，registry 发布按另行明确范围推进。

## 9. 测试映射

| 旧 conformance | 新测试责任 |
|---|---|
| model-generation | Rust compiler golden/type compile/history；typed SDK smoke |
| server-client-protocol | 共享 Rust codec vectors + ABI value fidelity + cross-version fixtures |
| client-storage-contract | Rust ClientStore/SQLite transaction/watch/savepoint tests |
| server-persistence-contract | 真实 Postgres adapter atomicity/locking/snapshot tests |
| end-to-end-sync | 精选真实 SDK→network→Rust→businessDB→localDB journeys |

保留历史 wire vectors 的原因是协议对外承诺依然存在。共用代码不能发现两端同时写错，所以 property oracle 和最终 DB 状态断言仍独立于生产 reducer。

## 10. 计划自检与开始实施前的具体选择

- 本计划覆盖 compiler、client、server、protocol、storage、SDK、infra、examples、migration 和发布准备。
- 第一闭环不依赖 decorator、完整 compiler 或所有 ORM，避免先做外围 DX 却未证明事务可行。
- 三项 breaking changes 单独评审：per-mutation receipt；remove/delete 分开；downlink 失败不 skip。
- 第一版 recordRevision 默认存在；可选模式没有偷偷混入实现。
- 未定问题均有明确的负责阶段、验收场景和发布门槛。
- 下一次开始实施，先确认 M0 的默认架构选择，再逐个执行；本次只完成计划，不进行 scaffold 或 runtime rewrite。
