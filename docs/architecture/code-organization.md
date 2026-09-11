# 代码组织与语言边界

2026-09-10。已确认：前后端框架协议与状态规则由 Rust 实现；客户端对外只有语言 SDK；Rust runtime 通过确定的 schema 描述工作，不依赖生成的业务类型。

当前范围：先保留现有逻辑完成 Rust 重写；record revision、跨 channel 新行为及其他语义改动放入 [Next things / TODO](../next-things.md)。命名已确认，见 [概念与命名](concepts-and-naming.md)。新命名不修改既有 wire/storage 字段。

目录布局为本轮推荐。下面列出的代码目录按实际交付逐个创建，目前没有空壳 crate 或占位实现。

## 1. 推荐目录

```text
local-first-state/
├── crates/
│   ├── lfs-core/             通用 schema、value、identity、operation、wire
│   ├── lfs-client/           本地状态、queue、replay、query、settlement
│   │   └── src/storage/     ClientStore / ClientTransaction 接口
│   ├── lfs-server/           dispatch、dedup、publish、loading
│   │   └── src/persistence/ ServerPersistence / TransactionPersistence 接口
│   ├── lfs-sqlite/           客户端存储 adapter：SQLite / transaction session
│   ├── lfs-persistence-sqlx/ 后续 Rust 后端 adapter，有需要时再建
│   └── lfs-compiler/         用 Rust 实现的 schema compiler
│       └── src/
│           ├── syntax/      schema 解析与语法诊断
│           ├── semantic/    schema 验证与统一中间表示
│           └── emit/
│               ├── schema/  runtime 加载的通用描述数据
│               ├── dart/    Dart 源码生成器
│               └── typescript/ TypeScript 源码生成器
├── bindings/
│   ├── node/                Rust ↔ Node；Cargo package lfs-node
│   ├── dart/                Rust ↔ Dart；Cargo package lfs-dart
│   └── wasm/                后续浏览器桥接，有验证需求时再建
├── packages/
│   ├── dart/                Dart 对外 client 与类型化 facade 支持
│   ├── client-js/           TypeScript 对外 client
│   ├── server/              TypeScript 后端 facade 与业务 callback 接口
│   │   └── src/persistence/ TS 接口与 Rust persistence port 的对应契约
│   ├── persistence-prisma/  PrismaPersistence，绑定用户 tx 的 adapter
│   └── nest/                可选 decorators / discovery / HTTP 接入
├── fixtures/
│   ├── schemas/             通用 schema 描述与兼容版本样例
│   ├── protocol/            wire / codec golden vectors
│   └── scenarios/           交错时序和独立期望结果
├── integration/
│   ├── rust/               Rust client ↔ Rust server 场景测试
│   ├── bindings/           Dart/TypeScript 接口 ↔ Rust
│   ├── persistence/        各 adapter 的真实数据库契约
│   ├── generated-api/      生成代码的编译及运行测试
│   └── e2e/                少量真实 SDK/网络/数据库完整流程
├── examples/                用户实际能运行的独立应用
└── docs/                    设计、协议、接入、实施计划
```

`crates/` 放不依赖 Node/Dart 的 Rust 实现；`bindings/` 放依赖语言运行环境的 Rust glue；`packages/` 放用户 import 的语言库。

不要复制一套 core 放在每个 SDK 内。测试属于具体 crate/package 的就放在旁边；跨边界测试才放 integration。不要建通用 utils 大包。

## 2. Runtime schema 是数据，不是业务 Rust 类型

Rust 中可以有稳定的通用结构：`Schema`、`ModelDescriptor`、`FieldDescriptor`、`RecordKey`、`Value`、`Operation`。它不应出现根据用户 schema 生成的 `struct Entry` 或 `struct Book`。

路径是：

```text
用户的 schema 源文件
        ↓ compiler
经过验证的、语言无关的 schema 描述
        ├── runtime 初始化加载 → Rust generic engine
        ├── Dart generator → Entry / EntryQuery / MutationInput
        └── TypeScript generator → Entry / EntryQuery / MutationInput
```

compiler 的稳定中间产物是 schema 描述；Dart/TypeScript 生成器依此产生语言习惯的 API。描述包括字段、identity、关系、约束、mutation slots 和历史输入版本。传输可以是序列化 bytes，或语言 SDK 注册的等价描述值；不能把语言对象 layout 当作协议。

Rust 在 runtime open 时校验 schema、索引和 compatibility fingerprint，缓存解析后的 descriptor；不是每次字段操作重新解析 JSON。未知 model、无效 patch、类型不符都在通用 engine 中有确定错误。

应用增加一个 model，只需重新生成语言代码与 schema metadata、执行必要的存储迁移，不需要重编 framework Rust binary。改变框架支持的操作语义或 scalar 类型，才可能需要升级 Rust runtime。

## 3. 各层必须守住的边界

| 层 | 做什么 | 不应混进来的东西 |
|---|---|---|
| lfs-core | 校验 schema/identity/operation，wire 编解码 | SQLite、HTTP、Prisma、业务 model struct |
| lfs-client | 状态规则、query IR、queue/replay/settlement；定义客户端存储接口 | Flutter widget、React hook、宿主业务 callback replay |
| lfs-server | 去重、publish 语义、下行和 receipt；定义后端 persistence 接口 | Nest DI、应用领域服务、私自创建的用户 DB transaction |
| lfs-sqlite | ClientStore 实现、原生本地事务、commit notifications | 重新定义协议或 optimistic 规则 |
| bindings | handle、owned values、错误、异步调用 | 独立的 scheduler 或 conflict resolver |
| language client | typed API、model 转换、Stream/subscription | 第二套 queue/reducer/cursor 规则 |
| server facade | 调用 TS handler/loader，返回完成结果 | 自己决定 ACK 可以结算 |
| server persistence adapter | 将用户 tx 适配为 TransactionPersistence，执行原子操作与 snapshot 读取 | 新开连接冒充同事务、静默降级原子性 |
| language generator | 语言类型、builders、descriptor 引用、转发 | 用户业务算法或复制 Rust 状态机 |

Dart/JS 自己的 Stream、订阅生命周期和平台 I/O 仍由语言代码接入。Rust 决定什么时候发请求、重试和结算；具体 HTTP、凭证、媒体上传实现可以由宿主提供。

## 4. 依赖方向

- `lfs-client` 和 `lfs-server` 都依赖 `lfs-core`，互不依赖。
- `lfs-sqlite` 实现 client 的存储接口；`lfs-client` 不反向依赖具体 SQLite crate。
- bindings 组合 core/runtime/store；语言 packages 通过 bindings 调用。
- compiler 依赖通用 schema 定义，runtime 不依赖 compiler。
- Nest 依赖 server facade，server facade 不依赖 Nest。
- 后端 runtime 依赖 ServerPersistence / TransactionPersistence trait，不依赖 Prisma、SQLx 等具体实现。
- Prisma adapter 实现 TypeScript 侧对应契约，经 Node binding 接入 Rust；Prisma tx 留在 TypeScript。
- 原生 Rust adapter 可直接实现同一后端 trait；SQLx adapter 不经过 Node。
- 客户端存储接口与后端 persistence 接口分别归属 lfs-client 和 lfs-server，不抽成一个混合大接口。
- adapter 可以复用通用 SQL/driver 工具；trait 的并发与事务保证由 framework 定义，不能随 driver 改变。
- 示例可以组合所有这些层，但框架代码不 import 示例或 Oasis。

## 5. Persistence 接口与可扩展 adapter

接口归 framework，具体数据库实现归 adapter。Rust 用 trait 表达契约；TypeScript 可以用 interface 配合 class。先定义稳定能力和生命周期，再确定具体方法签名。

### 后端：长期 adapter 与事务内对象分开

当前保留 batch 外层事务和每 mutation savepoint；由用户提供外层 transaction runner。不能在各 handler 独立 commit 后仍声称保留 batch rollback。

- `ServerPersistence`：后端持久化的接入边界；提供事务绑定和一致性读取的接入方式。宿主负责实际事务生命周期。
- `TransactionPersistence`：已经绑定用户某个真实 transaction 的操作接口。包含 receipt claim/read/save、channel counter、invalidation 和所需 savepoint 能力。
- `PrismaPersistence`：可长期复用的 adapter class。`bind(tx)` 创建仅在当前事务内有效的对象；不 begin、commit 或另开连接。
- 后续 `SqlxPersistence` 或其他 adapter 实现同一语义契约；具体数据库支持范围随 adapter 明确声明，不承诺所有数据库操作天然等价。

以下为使用形状示意，具体 import/type 在接口实现阶段确定：

```ts
const persistence = new PrismaPersistence();

await prisma.$transaction(async tx => {
  const store = persistence.bind(tx);

  await tx.entry.update({
    where: { id: entryId },
    data: { text },
  });

  await publisher.publish(store, {
    channels: [bookChannel(bookId)],
    model: Entry,
    identity: { id: entryId },
  });
});
```

这个例子只展示直接业务写入与 publish 共用事务；处理 push 时，仍需 batch wrapper 在业务写入之前执行去重，并在同一事务中写 receipt。不能把直接 publish 示例当成完整 handler 协议。

Rust 决定框架记录的意义与流程；adapter 实现真正的数据库操作，包括原子递增、锁定 claim、事务内 upsert 和 snapshot 读取。不能只做方法同名的 CRUD 包装，却不满足这些保证。

一致性读取必须保证 head、invalidation 和 loader 的相关业务读取来自相容的 snapshot。adapter 绑定 tx 时应验证/声明能力；不支持必要隔离、锁或 savepoint 就明确失败，不提供无事务 fallback。

`store` 不能逃逸到事务结束后使用。绑定的操作全部被 await；失败传回用户事务以触发 rollback。事务内 publish 完成不代表业务已 commit，ACK 和 live wake 的提交时机仍由外层完成边界控制。失败后的 session 必须阻止继续生成有效 accepted completion。

### 客户端：独立的本地存储契约

`ClientStore` / `ClientTransaction` 覆盖 visible records、authoritative base、pending queue、readiness、channel cursor/claims、查询和提交后的变更通知。默认 `lfs-sqlite` 实现它们，Rust client 管理本地事务流程。

它与 server persistence 不共用一个大 class：后端加入用户事务，客户端默认拥有自己的本地数据库；两边的存储对象和查询需求也不同。未来其他客户端存储 adapter 实现客户端契约即可。

### 扩展与验收

增加 adapter 时，新增实现 package 和契约测试，不修改核心状态机。共享测试至少验证 rollback、相同 batch 并发 claim、channel 原子递增、snapshot 一致性以及 transaction 结束后 handle 失效；客户端 adapter 另外验证 read-your-writes、savepoint 和 commit-only 通知。

原生 Rust adapter 与通过语言 bridge 接入的 adapter 都要满足同一语义。bridge 自身再验证值转换、异步错误和生命周期，不能以 adapter 单元测试代替跨语言事务测试。

## 6. Compiler 与各语言生成器

compiler 用 Rust 实现。它读取 schema，解析和校验为统一的描述，再由不同 emitter 写出目标文件；生成过程不需要先实例化 Dart 或 TypeScript 的业务 class。

```text
schema 源文件
    ↓ Rust parser / validator
统一 schema 描述
    ├── schema emitter → runtime metadata
    ├── Dart emitter → .dart 类型、转换函数、typed API
    └── TypeScript emitter → .ts 类型、转换函数、typed API
```

例如同一个 Entry 描述，Dart emitter 可以输出 `class Entry`，TypeScript emitter 可以输出 `interface Entry` 或适合 SDK API 的 class。生成器负责各语言的语法、类型映射、命名与转义；这些业务类型不会生成到 Rust runtime 中。

实现可以使用模板或源码构造器；不强制把 Dart/TypeScript compiler 嵌入 Rust compiler。写出的文件之后交给用户项目的 Dart/TypeScript 工具链分析、编译和运行。是否调用 formatter 是独立的开发工具选择，不影响 runtime 边界。

### 生成内容

- 业务 model、identity、mutation input 和允许修改的字段类型。
- 通用 record/value 与业务类型之间的转换函数。
- 类型化 query/operation builder 和向 SDK/Rust 转发的方法。
- 对应的 schema metadata 或其引用，保证类型 API 与 runtime 描述来自同一份 schema。

TypeScript interface 只提供静态类型，不自动执行运行时解码。Dart class 也需要显式构造；转换函数负责 null、数值、时间、bytes 等映射。Rust 保留通用 schema 校验，生成代码不复制 queue、replay 或 settlement 算法。

compiler 可以复用 lfs-core 的 schema 数据结构和验证规则；runtime 不反向依赖 compiler 或任何语言 emitter。第一阶段 emitter 放在 lfs-compiler 的独立模块内，有独立分发需求时再拆 crate。

## 7. Testing 分层

已确认按三层组织：Rust 核心（模块与两端状态场景）、边界契约（bindings/persistence/generated API）、少量完整 E2E。以下表格是三层的具体测试责任。单模块测试与数据放各 crate/package 旁；共享固定输入与预期数据放根目录 fixtures；跨组件测试放 integration。测试过程写在测试代码中，不引入场景 DSL。测试数据库使用独立临时目录/实例，不提交运行产物。

主要边界是 Rust 内部/两端之间，以及各语言接口与 Rust 之间；真实 persistence 和生成代码工具链分别验证各自的保证。

| 层 | 位置 | 验证重点 |
|---|---|---|
| Rust 模块测试 | 各 crate 的单元测试与 tests/ | schema、operation、reducer、queue、调度和结算不变量 |
| Rust client ↔ Rust server | integration/rust/ | 用可控运输模拟 ACK/page 乱序、丢失、重试、拒绝和重启；检查最终状态 |
| Dart/TypeScript 接口 ↔ Rust | integration/bindings/ | 类型和值转换、异步错误、transaction callback、订阅、取消和 handle 生命周期 |
| persistence adapter ↔ DB | integration/persistence/ | 真实 SQLite/Postgres 的 rollback、并发 claim/counter、snapshot、提交边界 |
| compiler / generated API | compiler 测试与 integration/generated-api/ | 确定性生成、源码合法性、类型约束、数据转换和 facade 转发 |
| 完整 E2E | integration/e2e/ | 少量真实 SDK、网络、Rust runtime、业务 callback、数据库组成的完整流程 |

### Rust 场景测试

大多数协议场景直接驱动 Rust client/server，不必每次启动 Dart 和 Node。transport、clock 和故障点可控；涉及持久化恢复的场景必须关闭并重新打开真实测试存储，不能仅清空内存变量。

client/server 共用代码不能代替正确性断言。测试需手工定义预期状态，或使用独立的小型参考模型检查不变量，避免两端共享同一个错误却相互验证通过。最终可见数据、authoritative base、pending 队列和 cursor 都有明确期望。

### Binding 与 adapter 测试

各语言只重复验证自己的边界，不复制整套 Rust replay 测试。保留一个同 binary 加载不同 schema 的测试，确认业务类型确实没有编译进 Rust。

数据库测试使用测试自行创建的资源。后端必须证明业务写入、publication 与 receipt 在同一真实事务回滚；mock adapter 无法证明这一点。各具体 adapter 复用语义契约测试，跨语言 adapter 还要跑一次真实 bridge + transaction 集成。

### 生成器测试

1. schema parser/validator 测合法定义和带定位信息的错误；历史输入与兼容规则有固定 fixtures。
2. golden tests 检查确定性输出、字段映射和目标语法；不能只更新快照就认定行为正确。
3. 对生成的 Dart 代码实际运行 Dart analyzer；对生成的 TypeScript 代码运行 `tsc --noEmit`。
4. 合法调用样例必须通过；错误字段、错误类型、非法 mutation patch 等负例必须产生预期诊断。负例分开组织，不能让任意无关编译错误也算通过。
5. 运行 record↔model 转换与生成 API 的调用测试，覆盖 absent/null、整数、Unicode、时间与集合；调用 Rust 后验证实际结果。

测试运行器由所在语言选择；Rust 不需要实现 Dart/TypeScript 编译器。CI 负责分别运行这些工具链。只减少重复算法实现带来的 conformance 负担，保留对外协议 vectors、跨版本兼容和少量真实 E2E。

## 8. 第一个实现范围

先建立 `lfs-core` 的最小 schema/operation 描述及测试，同时验证 Node transaction bridge 和 Dart SQLite session。先让 Entry 仅作为 fixture 里的 schema 数据存在，以测试证明 runtime 没有编译期业务类型依赖。

必须有一个回归测试：同一个已编译 Rust runtime 先加载 schema A，再在另一个实例加载包含新增 model 的 schema B；不重编 Rust，两者均可完成合法查询/写入。schema B 若增加 runtime 不支持的能力，明确 compatibility error。

接着打通单 channel 的完整闭环。现有多 channel 行为、compiler 全量迁移和 Nest DX 按实施计划补齐。record revision 和新的跨 channel 仲裁之后再做。第一版不要同时创建所有目录和空 package。

## 9. 本轮仓库动作

- 新 worktree：`/Users/stevewang/Github/local first state/.worktrees/rust-rebuild`。
- 新 branch：`codex/rust-rebuild`，从包含设计文档的 `370e1f1` 创建。
- 删除该分支的旧 runtime、compiler、conformance、示例、CI、构建脚本和旧准备文档。
- 保留新设计/审查/计划，重写 README 和 ignore 配置。
- 旧代码保留在 main 和已有 Git 历史，当前工作目录没有旧实现副本。

## First implementation layout

The executable Rust workspace is now `crates/{lfs-core,lfs-client,lfs-server,lfs-sqlite,lfs-compiler}` plus `bindings/{common,dart}`; `bindings/node` has its own N-API build manifest. Public host packages are `packages/{client-js,dart,server,persistence-prisma,nest}`. Cross-component tests live in `integration/{rust,bindings,persistence,generated-api,nest,e2e,platform}`, and reusable inputs remain in `fixtures/`. `scripts/test.sh` runs the native host gate; platform simulator tests have separate scripts.

The Rust client contains generic records and schema descriptors. Language generators emit business types, encoding/decoding, typed query options, relation accessors and mutation builders. They do not emit replay, settlement or scheduling algorithms. Host connection classes supply timers/network cancellation; Rust selects actions and retry delays. Backend registration remains available as ordinary functions or Nest decorators, and HTTP/WebSocket attach to an application-owned server.

The initial SQLite adapter stores changed keyed documents and keeps a full in-memory state snapshot. Read-only SQL evaluates that optimistic snapshot in an isolated SQLite connection. These choices make the first implementation verifiable; dedicated projection tables/indexes and large-cache optimization require performance work before claiming production scale.
