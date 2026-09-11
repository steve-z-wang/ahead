# local-first-state Rust 重建实施计划

[English](../../../superpowers/plans/2026-09-10-rust-rebuild.md) | [简体中文](2026-09-10-rust-rebuild.md)

> 历史设计记录（2026-09-10）：下文的状态说明与拟议 API 反映原规划阶段。当前已交付范围与已验证的限制见[实现验证记录](../../implementation-progress.md)。

> **面向代理执行者：** 使用 `superpowers:executing-plans`，逐项执行已接受的里程碑任务。在架构决策完成评审之前，不要根据本提案开始实现运行时。无需子代理工作。复选框跟踪未来的实施任务，不代表编写本计划时已完成的工作。

> 当前实施范围：保留参考实现的逻辑；新增记录修订号、跨 Channel（通道）仲裁和其他行为改动均在[后续事项](../../next-things.md)，不属于以下里程碑。命名以[概念与命名](../../architecture/concepts-and-naming.md)为准。

**目标：** 从零交付共用 Rust 协议与状态机的 local-first-state，保留自然的 Dart/TypeScript 业务接口与用户事务控制。

**架构：** Rust 客户端与服务端运行时共享模式、线协议和操作语义。宿主通过类型化端口执行业务 Handler（处理器）、Loader（加载器）、事务内持久化和网络 I/O。第一闭环采用 Dart 原生客户端、Rust SQLite、Node 绑定及 Prisma/PostgreSQL。

**技术栈：** Rust 工作空间、SQLite、PostgreSQL、Node/TypeScript、Dart。NAPI-RS、flutter_rust_bridge、rusqlite 是可行性试验的候选；实际版本完成构建验证后写入锁文件与工具链配置。unadapter 不作为正确性前提。

## 全局约束

- 项目名称为 `local-first-state`；GitHub 保持私有；不自动发布包。
- 用户拥有后端事务；框架只使用绑定该事务的持久化接口。
- 发布必须明确指定通道；不引入隐式通道，也不强制通道与模型一对一。
- 共同算法放在 Rust；SDK 不能自行实现 ACK 结算、记录冲突处理或重放。
- 用户已于 2026-09-10 授权端到端执行本计划；实现进度与验证见[实施进度](../../implementation-progress.md)。
- 旧参考源码保存在 main 和历史提交；用户已授权在新分支删除旧实现。不改 Oasis，不清空实际客户端队列，不修改生产数据库。
- 所有新测试使用临时 SQLite 和本轮创建的隔离 Postgres，不能读取生产 DATABASE_URL。
- 重大的未定协议先通过场景定稿；每个后续里程碑单独细化为可执行任务，不用虚构完整代码掩盖未定设计。

---

## 1. 阅读顺序与工作目录

1. 先读[架构提案](../specs/2026-09-10-rust-core-design.md)。
2. 用[逻辑覆盖表](../specs/2026-09-10-existing-logic-audit.md)检查遗漏。
3. 按此计划的关卡顺序执行，不先从头移植编译器。

当前实现工作树：`/Users/stevewang/Github/local first state/.worktrees/rust-rebuild`，分支 `codex/rust-rebuild`。用户已授权从零实现并在该分支清除旧代码；旧实现以 main/参考提交保存。目录边界以[代码组织](../../architecture/code-organization.md)为准。

以下路径相对该工作树根目录；随实施逐步创建。

```text
Cargo.toml                         工作空间，随第一个 Rust 测试一起建立
rust-toolchain.toml                可行性试验通过后固定工具链
crates/lfs-core/src/               模式、值、身份、操作、协议
crates/lfs-client/src/             投影、队列、通道、结算、查询
crates/lfs-server/src/             变更、发布、加载、宿主端口
crates/lfs-sqlite/src/             本地数据库 actor/会话/存储
bindings/node/src/               Node 绑定
bindings/dart/src/               Dart 绑定
crates/lfs-compiler/src/           后期编译器迁移
packages/server/src/              TypeScript 门面 / 宿主分发器
packages/persistence-prisma/src/   事务性 Postgres 适配器
packages/nest/src/                装饰器 / 提供者发现
packages/dart/                    Dart 门面
packages/client-js/               后期 JS/浏览器门面
examples/rust-round-trip/          独立完整示例
fixtures/protocol/              公共线协议/模式测试向量
fixtures/scenarios/                人类可读的交错时序及预期状态
integration/                      真实数据库 / 桥接 / 端到端测试
```

不要因为目录列出就一次搭建所有包的骨架。每个新 crate/包随其第一个可验证交付创建。Rust 运行时只读取通用模式元数据，不生成或链接业务模型类型；代码组织文档定义了新增模型不重编 Rust 的验收测试。

## 2. 总体阶段与退出条件

| 阶段 | 交付 | 进入下一阶段前的证明 |
|---|---|---|
| M0 决策与桥接可行性 | 对齐关键语义；Node 事务、Dart SQLite 两个最小可行性试验 | 同事务回滚、重复请求、超时、释放均可观察验证 |
| M1 最小完整闭环 | UpdateEntry、单通道、真实业务表、持久化队列、ACK/拉取 | 断网修改、重启、ACK 乱序、拒绝、响应丢失全通过 |
| M2 现有多通道行为 | 独立游标、认领、动态订阅、Move、多个检查点 | 与参考行为一致；已有乱序限制明确记录，不引入修订号 |
| M3 现有高级客户端行为 | 级联、伴随操作、依赖、就绪状态、查询/监听、批次 | 覆盖表所有运行时行有测试；明确所有有意差异 |
| M4 编译器与 SDK 开发体验 | Rust 编译器、Dart/TS 类型、Nest 装饰器、迁移契约 | 生成代码无算法；历史 Mutation（变更）可重放；类型误用编译失败 |
| M5 平台与开放发布准备 | Dart 移动端、Node 部署、JS/Web 验证、文档、独立示例 | 干净机器安装可跑；恢复/存储边界明确；许可证决策完成 |

不把这些阶段换算成未经验证的精确工期。M0 的桥接和事务结果决定后面是否调整实现方式。

## 3. M0：先证明最危险的边界

### 任务 0.1 — 将关键设计决定变成可评审的场景

**文件：** `fixtures/scenarios/transaction-boundary.md`、`fixtures/scenarios/settlement-order.md`、`fixtures/scenarios/channel-overlap.md`。

**输入：** 本设计 §7/9/10 和参考实现。**输出：** 固定的现有行为场景，后续测试据此实现。

- [ ] 写出以下时序的预期数据库状态，不先实现代码。
- [ ] 固定批次事务、每个变更的保存点、批次回执及序号/哈希去重的预期。
- [ ] 保留现有线协议字段、整数范围和删除表示；recordRevision、十进制字符串、epoch 延后。
- [ ] 将确认后的文档单独提交，作为实现基准。

场景 A：同一批次中 M1 执行成功，M2 处理器发生未知错误；整个批次的业务写入、回执和发布全部回滚。若 M2 是明确业务拒绝，则只回滚 M2 的保存点，批次可提交 M1 的写入及 M2 的拒绝结果。重试遵循既有批次回执规则。

场景 B：base.text=A，M1→B，M2→C；M1 的 ACK 需要 channel:11，先收到 channel:10，再收到 11；可见 text 始终为 C。按既有批次检查点与已接受前缀规则结算，M2 尚未满足条件时继续待处理。

场景 C：同一记录同时由 A/B 通道提供。按参考实现固定认领建立、null 释放当前认领、最后一个认领释放及权威级联的结果；记录延迟响应可能覆盖较新内容的限制。记录修订号仲裁与新的删除协议在后续事项中。

### 任务 0.2 — Node 桥接加入真实 Prisma 事务

**创建：** `bindings/node/src/transaction_probe.rs`、`packages/persistence-prisma/src/transaction-session.ts`、`integration/node/transaction-bridge.test.ts`、`integration/node/schema.prisma`。

**接口形状（仅用于可行性试验，不是正式 SDK）：**

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

- [ ] 建立隔离 Postgres、两张探测表和 Node 测试工具；先测试错误地使用全局客户端的实现确实被此断言识别。
- [ ] 实现 Rust→JS 异步回调→Rust 返回链；不能使用另一个 Rust 数据库连接池。
- [ ] 加入回调拒绝、Rust 错误、ORM 超时、运行时释放和多个并发事务；不同句柄不可串写。
- [ ] 在事务结束后再调用保存的宿主句柄，必须返回 `transaction_closed`，无数据库操作。
- [ ] 测试外层提交失败时 HTTP 层绝不生成接受 ACK。
- [ ] 记录每个变更的回调数量、序列化字节数和桥接耗时；不据微基准宣布 Rust 更快。
- [ ] 固定可工作的绑定/运行时版本并提交。

**运行目标：** `node --test integration/node/transaction-bridge.test.mjs`（测试源码的构建步骤与测试工具同步提供）。不装完整产品依赖；失败时先定位桥接层，不改成独立事务绕过。

### 任务 0.3 — Dart ↔ Rust SQLite 事务会话

**创建：** `crates/lfs-sqlite/src/session.rs`、`bindings/dart/src/api.rs`、`integration/dart/transaction_bridge_test.dart`。

**接口契约：** 打开运行时；开始会话；会话内查询/应用；提交/回滚；监听已提交变更；关闭。会话必须有唯一句柄与结束状态。

- [ ] 写测试：会话内写入后读得到，会话外监听者在提交前看不到；回滚后数据库恢复。
- [ ] 写测试：外层直接写入 + 内层变更保存点失败，只回滚该变更；外层可继续提交。
- [ ] Rust 工作线程拥有 SQLite；Dart Future 不阻塞 UI isolate。
- [ ] 提交后收到一次一致结果；回滚不发送中间结果；关闭时结束监听者。
- [ ] 进程重开读取已提交行；未提交会话不残留半条变更。
- [ ] 记录跨绑定的整数/null/字节/Unicode/错误行为，固定第一组 ABI 测试向量。

**运行目标：** `dart test integration/dart/transaction_bridge_test.dart`，实际包/测试路径由该测试工具的 pubspec 定义。使用临时文件数据库；不是只测内存中的归约器。

**M0 判定：** 若两条桥接中任一无法可靠地保持生命周期和事务语义，暂停扩展；可改绑定机制（例如挂起/恢复），不可降低原子性承诺。只有架构调整被记录后才继续。

## 4. M1：第一个有用的完整闭环

第一版示例：两位查看者共享一个 Book 通道；一张 Entry 业务表；UpdateEntry 具名变更；Dart 原生客户端本地 SQLite。暂不做媒体、Move、编译器重写或浏览器。

### 任务 1.1 — 公共值/身份/协议内核

**创建：** `crates/lfs-core/src/{value,identity,operation,protocol,error}.rs`、`crates/lfs-core/tests/wire_vectors.rs`、`fixtures/protocol/`。

**输出：** 通用记录身份、批次信封/回执、通道检查点、拉取页/变更及类型化错误。具体字段依据参考协议，不重新定义意义；Rust 内部类型名不等于线协议字段名。

从参考实现提取真实 JSON 测试夹具，覆盖成功、拒绝、重复请求和非法输入。不另造 protocol-v2 示例；新 API 名称在边界映射至旧线协议字段。

- [ ] 固定计数器范围、规范哈希、未知字段/版本处理、UUID、日期时间、补丁的缺省/null 行为。
- [ ] 先写黄金测试向量和拒绝测试向量：负游标、溢出、重复键、非法浮点数、通道不匹配。
- [ ] 实现编解码/规范化；单元测试和 Node/Dart ABI 测试同读测试向量。
- [ ] 提交内核与测试向量；不在 SDK 复制解析规则。

**验证：** `cargo test -p lfs-core`；另执行 M0 两种绑定的值测试。

### 任务 1.2 — 本地应用/重放与持久化队列

**创建：** `crates/lfs-client/src/{projection,queue,mutation}.rs`、`crates/lfs-sqlite/src/{schema,client_store}.rs`、`crates/lfs-client/tests/optimistic_replay.rs`。

**输入：** 核心操作、M0 ClientStore 会话。**输出：** 在一个 SQLite 事务内应用可见状态、基底及持久化待处理意图。

- [ ] 写测试：基底 A→入队 B→可见 B；重开仍为 B 且队列仍有 M1。
- [ ] 写测试：M1 改 text，远端改另一个字段；重放只覆盖 M1 修改的字段。
- [ ] 写测试：创建/更新/删除、缺省/null、同一行的多个变更；失败不留下仅有队列或仅有主表的状态。
- [ ] 实现稀疏基底与归约器；不依赖外部回调重放业务代码。
- [ ] 为直接本地写入与变更写入设置不同命运，禁止误发本地操作。
- [ ] 提交 SQLite 模式和测试；以数据库内容验证，不只断言内部函数被调用。

**验证：** `cargo test -p lfs-client --test optimistic_replay`、`cargo test -p lfs-sqlite`。

### 任务 1.3 — 服务端持久化与显式发布

**创建：** `crates/lfs-server/src/{ports,publish}.rs`、`packages/persistence-prisma/src/{index,publication,receipt,snapshot}.ts`、`integration/postgres/publish.test.ts`。

**输入：** 绑定事务的宿主会话。**输出：** 每个通道的发布位置，在同一事务持久化。

- [ ] 建立带命名空间的框架表和迁移：客户端/回执、通道头、压缩失效记录；本轮不建记录修订号表。
- [ ] 测试同通道并发发布得到互异单调位置；回滚不留失效记录/通道头增量。
- [ ] 测试不同通道无框架全局锁；同一记录向多通道发布时，按各自通道头和失效记录独立记录。
- [ ] 测试计数器耗尽时显式失败；重复身份/通道规范化后不多次写入。
- [ ] 实现快照读取；模拟并发更新，验证通道头/失效记录/状态满足参考读取契约；隔离保证不足时记录并单独评审。
- [ ] 迁移现有提交唤醒/追赶行为；测试提示与服务重启；外部事务通知缺口先记录，不默认加入新轮询语义。
- [ ] 提交适配器及真实 Postgres 测试。

**验证：** 包提供 `npm run test:integration -- publish`；测试工具创建/销毁专属数据库。此脚本在本任务中建立，不假定旧服务端包已有。

### 任务 1.4 — 业务处理器与持久化回执

**创建：** `crates/lfs-server/src/{mutation,receipt}.rs`、`packages/server/src/{mutation-context,dispatch}.ts`、`integration/postgres/mutation-receipt.test.ts`。

**输入：** 批次信封、类型化分发器、绑定的持久化接口。**输出：** 包含变更接受/拒绝结果的批次回执；仅外层提交成功后可发送。

- [ ] 测试两次并发相同批次序号/哈希只执行一次业务回调；相同键、不同哈希会冲突。
- [ ] 测试业务写入/发布/回执任一步故障，全部回滚；用户捕获发布错误后也不能得到有效完成凭证并提交接受回执。
- [ ] 测试明确拒绝经保存点回滚当前变更后纳入批次回执；未知异常回滚整个批次。
- [ ] 测试外层事务结束前不能发送 ACK；提交成功但响应丢失时，重试返回已有回执。
- [ ] 测试两条变更的业务拒绝与未知异常分别符合任务 0.1 的原行为。
- [ ] 包装器返回带品牌类型的完成凭证；未绑定事务、遗漏回调完成、事务已关闭均失败。
- [ ] 提交运行时/SDK/测试，业务处理器保持 TS。

**验证：** `cargo test -p lfs-server` 与真实数据库的 mutation-receipt 集成测试。

### 任务 1.5 — 加载器、拉取、结算

**创建：** `crates/lfs-server/src/loader.rs`、`crates/lfs-client/src/{pull,settlement}.rs`、`packages/server/src/loader.ts`、`crates/lfs-client/tests/settlement_orders.rs`。

**输入：** 快照端口、加载器分发器、回执/游标。**输出：** 权威页及客户端按既有逐条变更规则应用/结算。

- [ ] 加载器按模型批量读取，保持既有身份对齐、完整状态/null 和 prepareForViewer 契约。
- [ ] 迁移现有结算通道选择与所需检查点；更严格的见证覆盖另行设计。
- [ ] 测试 ACK→页与页→ACK 两个顺序；在每个持久化边界重启后结果相同。
- [ ] 测试既有解码器/规范应用的失败分类和逐条变更跳过/游标推进；将风险与期望结果明确记录，不改成整页回滚。
- [ ] 测试同一行的 M1/M2 顺序、服务端规范化、服务端删除、拒绝后的重建。
- [ ] 测试重复页/空页/有缺口的页、游标超前、迟到的过期响应。
- [ ] 成功后清理稀疏前镜像/队列，剩余变更的基底状态正确。

**验证：** `cargo test -p lfs-client --test settlement_orders`，并通过 SQLite 读回断言。

### 任务 1.6 — SDK 与真实示例

**创建：** `examples/rust-round-trip/{README.md,compose.yaml}`、`examples/rust-round-trip/server/`、`examples/rust-round-trip/client/`、`integration/e2e/round-trip.test.ts`。

- [ ] 提供应用自己的 Prisma 事务、一个普通函数处理器、一个加载器；暂不依赖 Nest。
- [ ] Dart 门面提供类型化读取/监听/变更；事务和操作通过 Rust 桥接。
- [ ] HTTP/WS 挂在同一个示例 Node 服务端；协议字节由 Rust 处理。
- [ ] 自动场景：初始拉取→断网修改→关闭重开→上线→丢一次 ACK→重试→等待拉取→最终队列/基底清理。
- [ ] 第二场景：服务端改写 text；第三场景：服务端拒绝；实际 UI/本地查询输出必须体现正确结果。
- [ ] 提供只启动本示例资源的脚本，清理只删除自己创建的容器/卷；无需生产账号。
- [ ] 将精确安装、生成、构建、运行、期望输出写入 README；干净目录完整运行一次。

**M1 验收矩阵：**

| 故障点 | 必须观察到 |
|---|---|
| 本地提交前崩溃 | 无半条队列/可见状态写入 |
| 本地提交后离线 | 重开仍有乐观状态和相同变更 ID |
| 服务端回执写失败 | 业务及发布都回滚 |
| 服务端提交后 ACK 丢失 | 重试不重复业务 |
| ACK 先到 | 线协议乐观状态保留到检查点 |
| 拉取先到 | ACK 到来即可从持久化游标结算 |
| 解码/应用失败 | 按参考失败分类验证逐条变更跳过/游标行为；不宣称其安全性已改善 |
| 明确拒绝 | 变更操作完整回滚，拒绝记录可读 |
| 关闭/重新登录 | 旧会话回调不写新数据库 |

M1 只是可验证的 alpha 核心，不宣布全部旧能力已替代。

## 5. M2：保留现有多通道行为

**文件：** `crates/lfs-client/src/{membership,channel,settlement}.rs`、`crates/lfs-server/src/{publish,loader}.rs`、`integration/e2e/channel-overlap.test.ts`。

- [ ] 每个通道独立维护通道头/游标；不同通道的数字不可比较。
- [ ] 迁移通道行认领、插入或更新、null 释放与既有权威级联；不引入新的删除动作。
- [ ] 测试动态期望通道、订阅/取消、重连及本地事务回滚。
- [ ] 测试跨多个通道的批次检查点、ACK/页乱序和已接受前缀结算。
- [ ] 从旧实现提取 Move 和重叠场景，包括旧响应迟到的实际限制；不得用拟议修订号行为作为本轮断言。
- [ ] 保留既有授权、prepareForViewer 与身份对齐语义。
- [ ] 更强的内容版本保证、remove/delete 区分、权限恢复与垃圾回收进入后续事项。

**退出条件：** 场景与参考实现行为等价，限制有明确记录；没有因共享 Rust 运行时而宣称新增乱序保护。

## 6. M3：完整客户端行为与性能

**文件：** `crates/lfs-client/src/{dependencies,readiness,cascade,companion,query,lifecycle}.rs`，对应 `tests/`；`packages/dart/`、`integration/e2e/`。

按以下顺序逐项交付，每项先迁入独立期望测试，再实现：

1. 多操作变更/本地直接写入/伴随操作同命运；已接受的伴随操作正确推进本地基底。
2. 级联图的 main+before 扫描、拒绝恢复、祖先变更与子项编辑交错。
3. 生命周期依赖与业务顺序；独立任务超车；前置拒绝传播差异。
4. 前置条件的就绪/失败/重试、取消、用户重试/丢弃、引用清理；上传任务由宿主执行。
5. 持久化拒绝收件箱、确认、派生的逐记录状态。
6. 持久化期望通道、乐观订阅/取消订阅回滚、既有待结算所需读取规则。
7. 类型化查询、关系/逆向关系、排序/null/数量限制、监听的初始值/去重/仅提交后通知/关闭；只读 SQL 的写入防护。
8. 批次信封、字节/数量限制、冻结重试、后台生命周期、身份验证刷新、退避/抖动、有界队列。

**验证：** 对照覆盖表逐行归属；随机时序属性测试 + 独立判定器。每个变更/页不做逐字段桥接回调，记录数据库往返次数、p50/p95、队列 10/1000 条下的重放成本。优化不得改变持久化边界或查询可见性。

## 7. M4：编译器、API 与 Nest

**文件：** `crates/lfs-compiler/src/{syntax,semantic,history,emit}/`、`packages/nest/src/{decorators,discovery,module}.ts`、`fixtures/schema-evolution/`。

- [ ] 先把现有编译器输出规范化为 Rust 运行时描述符，移除对生成算法的依赖。
- [ ] 逐步迁移解析器、语义分析、关系图、槽位绑定、版本历史；旧/新编译器对同一合法定义输出语义等价结果。
- [ ] 迁移既有模式兼容性护栏，测试模型/字段删除、新增字段和旧客户端读取；更广的身份/类型/可空性护栏进入后续事项。
- [ ] 生成 Dart/TS 操作构造器与后端类型化输入，保持缺省/null、版本快照。
- [ ] 业务型输入门面显式映射底层槽位；不让任意宿主回调成为 Rust 重放的隐式依赖。
- [ ] 加 Nest `@Handles` / `@Loads` + 提供者发现；接口检查静态类型，装饰器记录运行时元数据。
- [ ] 启动失败测试：重复处理器、漏注册模型/版本、错误描述符；普通函数注册仍能使用全部能力。
- [ ] HTTP 适配器挂载用户服务端；独立监听不是必须运行的第二个服务。

**退出条件：** 一个业务作者可以只读示例完成模型、处理器、加载器、发布集成；所有生成算法护栏与 ABI 测试通过。新编译器不依赖 Oasis。

## 8. M5：平台、迁移、开放准备

- [ ] Dart：macOS 开发、iOS 模拟器/设备、Android 模拟器/设备的构建/加载/重启冒烟测试；精确平台支持表。
- [ ] Node：macOS 与 Linux 的实际原生产物安装、生产构建、容器启动；平台矩阵基于验证，不只基于编译成功。
- [ ] JS/Web：WASM 与浏览器 SQLite/OPFS 或宿主存储的独立可行性试验；多标签页单写者、工作线程、配额、关闭和恢复。未验证前标为未支持。
- [ ] 非 TypeScript 后端：独立 Rust 宿主示例后再考虑 SQLx/SeaORM；不承诺从 ORM A 的事务自动转换为 ORM B 的事务。
- [ ] 旧存储/线协议迁移：选择排空或专门迁移器，保护未发送/已冻结/已接受/伴随/仅本地状态；不默认删除旧数据库。
- [ ] 协议版本兼容表、破坏性变更、故障恢复指南、容量/保留说明。
- [ ] CI 分核心、绑定、适配器、端到端、包冒烟测试；只保留有独立价值的一致性测试，不重复整套算法测试。
- [ ] 作者选择许可证；核查分发文件；源代码先公开，包注册表发布按另行明确的范围推进。

## 9. 测试映射

| 旧一致性测试 | 新测试责任 |
|---|---|
| model-generation | Rust 编译器黄金/类型编译/历史测试；类型化 SDK 冒烟测试 |
| server-client-protocol | 共享 Rust 编解码测试向量 + ABI 值保真 + 跨版本测试夹具 |
| client-storage-contract | Rust ClientStore/SQLite 事务/监听/保存点测试 |
| server-persistence-contract | 真实 Postgres 适配器原子性/锁定/快照测试 |
| end-to-end-sync | 精选真实 SDK→网络→Rust→业务数据库→本地数据库流程 |

保留历史线协议测试向量的原因是协议对外承诺依然存在。共用代码不能发现两端同时写错，所以属性测试判定器和最终数据库状态断言仍独立于生产归约器。

## 10. 计划自检与开始实施前的具体选择

- 本计划覆盖编译器、客户端、服务端、协议、存储、SDK、基础设施、示例、迁移和发布准备。
- 第一闭环不依赖装饰器、完整编译器或所有 ORM，避免先做外围开发体验却未证明事务可行。
- 每个变更单独回执、remove/delete 分开、拉取失败不跳过和 recordRevision 全部延后；当前保留原行为。
- 命名改变只影响新 API 与内部符号；旧线协议/存储字段不批量改名。
- 未定问题均有明确的负责阶段、验收场景和发布门槛。
- 下一次开始实施，先确认 M0 的默认架构选择，再逐个执行；当前已获实施授权，按验证结果更新进度。

## 实施证据

本文保留原始路线图及其更广的平台/发布检查清单。当前实现以及已验证与未验证的精确覆盖范围记录在[实施进度](../../implementation-progress.md)中；未勾选的路线图事项不得视为已验证。专用性能诊断位于 `integration/rust/examples/capacity.rs`；宿主 CI 复用 `scripts/test.sh`。公开发布、浏览器运行时、原数据库导入和新增平台支持均需要各自的证据。
