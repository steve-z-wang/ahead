# 代码组织与语言边界

2026-09-10。已确认：前后端框架协议与状态规则由 Rust 实现；客户端对外只有语言 SDK；Rust runtime 通过确定的 schema 描述工作，不依赖生成的业务类型。

目录布局为本轮推荐。下面列出的代码目录按实际交付逐个创建，目前没有空壳 crate 或占位实现。

## 1. 推荐目录

```text
local-first-state/
├── crates/
│   ├── lfs-core/             通用 schema、value、identity、operation、wire
│   ├── lfs-client/           本地状态、queue、replay、query、settlement
│   ├── lfs-server/           dispatch、dedup、publish、materialization
│   ├── lfs-sqlite/           原生客户端 SQLite 和 transaction session
│   └── lfs-compiler/         schema 解析/验证、IR、各语言生成器
├── bindings/
│   ├── node/                Rust ↔ Node；Cargo package lfs-node
│   ├── dart/                Rust ↔ Dart；Cargo package lfs-dart
│   └── wasm/                后续浏览器桥接，有验证需求时再建
├── packages/
│   ├── dart/                Dart 对外 client 与类型化 facade 支持
│   ├── client-js/           TypeScript 对外 client
│   ├── server/              TypeScript 后端 facade 与业务 callback 接口
│   ├── persistence-prisma/  在用户 Prisma transaction 中执行数据库操作
│   └── nest/                可选 decorators / discovery / HTTP 接入
├── fixtures/
│   ├── schemas/             通用 schema 描述与兼容版本样例
│   ├── protocol-v2/         wire / codec golden vectors
│   └── scenarios/           交错时序和独立期望结果
├── integration/             ABI、真实数据库、端到端测试
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
| lfs-client | 状态规则、query IR、queue/replay/settlement | Flutter widget、React hook、宿主业务 callback replay |
| lfs-server | 去重、publish 语义、下行和 receipt | Nest DI、应用领域服务、私自创建的用户 DB transaction |
| lfs-sqlite | ClientStore 实现、原生本地事务、commit notifications | 重新定义协议或 optimistic 规则 |
| bindings | handle、owned values、错误、异步调用 | 独立的 scheduler 或 conflict resolver |
| language client | typed API、model 转换、Stream/subscription | 第二套 queue/reducer/cursor 规则 |
| server facade | 调用 TS handler/materializer，返回完成结果 | 自己决定 ACK 可以结算 |
| persistence adapter | 通过绑定 tx 执行原子操作与 snapshot | 用新连接假装加入旧事务 |
| language generator | 语言类型、builders、descriptor 引用、转发 | 用户业务算法或复制 Rust 状态机 |

Dart/JS 自己的 Stream、订阅生命周期和平台 I/O 仍由语言代码接入。Rust 决定什么时候发请求、重试和结算；具体 HTTP、凭证、媒体上传实现可以由宿主提供。

## 4. 依赖方向

- `lfs-client` 和 `lfs-server` 都依赖 `lfs-core`，互不依赖。
- `lfs-sqlite` 实现 client 的存储接口；`lfs-client` 不反向依赖具体 SQLite crate。
- bindings 组合 core/runtime/store；语言 packages 通过 bindings 调用。
- compiler 依赖通用 schema 定义，runtime 不依赖 compiler。
- Nest 依赖 server facade，server facade 不依赖 Nest。
- Prisma adapter 依赖 persistence port 定义，不让 Prisma 类型进入 Rust core。
- 示例可以组合所有这些层，但框架代码不 import 示例或 Oasis。

## 5. 第一个实现范围

先建立 `lfs-core` 的最小 schema/operation 描述及测试，同时验证 Node transaction bridge 和 Dart SQLite session。先让 Entry 仅作为 fixture 里的 schema 数据存在，以测试证明 runtime 没有编译期业务类型依赖。

必须有一个回归测试：同一个已编译 Rust runtime 先加载 schema A，再在另一个实例加载包含新增 model 的 schema B；不重编 Rust，两者均可完成合法查询/写入。schema B 若增加 runtime 不支持的能力，明确 compatibility error。

接着打通单 scope 的完整闭环。多 scope、record revision、compiler 全量迁移和 Nest DX 按实施计划扩展。第一版不要同时创建所有目录和空 package。

## 6. 本轮仓库动作

- 新 worktree：`/Users/stevewang/Github/local first state/.worktrees/rust-rebuild`。
- 新 branch：`codex/rust-rebuild`，从包含设计文档的 `370e1f1` 创建。
- 删除该分支的旧 runtime、compiler、conformance、示例、CI、构建脚本和旧准备文档。
- 保留新设计/审查/计划，重写 README 和 ignore 配置。
- 旧代码保留在 main 和已有 Git 历史，当前工作目录没有旧实现副本。
