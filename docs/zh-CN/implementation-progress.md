# 第一版实现验证记录

[English](../implementation-progress.md) | [简体中文](implementation-progress.md)

用户于 2026-09-10 批准端到端实现。Rust 重写版本现已通过两种语言 SDK 连接嵌入式后端和真实数据库运行。这一实现以 private 源码 alpha 的形式开发，不是公开 package 发布，也不代表未来平台路线图已全部完成。

## 已实现

| 领域 | 已交付内容 |
| --- | --- |
| 共享 Rust runtime | Schema 作为数据、规范化、Identity、旧版 wire codec 和请求 hash。Rust 中没有生成的业务类型。 |
| 持久化客户端 | SQLite transaction/savepoint、直接与乐观写入、稀疏 before image、持久化 queue/frozen batch、ACK Checkpoint barrier 和 accepted-prefix 结算。 |
| 原有客户端行为 | Channel claim、companion/cascade 影响、生命周期/sequence 依赖、prerequisite、拒绝 inbox/status、查询/关系/watch、只读 SQL 和后台调度。 |
| 后端 | 通用 Rust Push/Pull/Publish 状态机、应用管理的事务回调、逐 Mutation savepoint、持久化 batch receipt 和一致的 Loader 快照。 |
| 集成 | Node/N-API 与 Dart FFI worker、带可复用 `bind` 的 Prisma/PostgreSQL persistence、挂载到应用 server 的 HTTP/WebSocket、普通注册和 Nest decorator。 |
| Compiler | Rust `.model` parser/校验/history；生成的 Dart 和 TypeScript Identity、Model/patch 类型、operation builder、强类型查询、关系和后端 input。 |
| 开发流程 | 独立可运行示例、构建/测试脚本、host CI 定义、共享 fixture、兼容性/恢复文档，以及可重复的小规模容量诊断。 |

## 验证

`bash scripts/test.sh` 在本地 macOS arm64 上通过。最终 [GitHub 验证运行](https://github.com/steve-z-wang/local-first-state/actions/runs/34555679980) 针对代码提交 `92bf410` 在全新 `macos-14` 和 `ubuntu-24.04` runner 上通过，包含完整检查、优化 Rust/Node 构建和优化 binding smoke。第一次 CI 运行发现的全新安装时 Nest 依赖缺失已在此次成功运行前修复。完整检查包括：

| 检查 | 观察到的结果 |
| --- | --- |
| Rust format、workspace tests、将 warning 视为错误的 Clippy | 通过 |
| Core 契约 | 11 个测试，包含共享 wire fixture |
| SQLite 客户端行为 | 28 个测试，包含拒绝迁移后保留原数据库/冻结字节 |
| Rust connection driver | 2 个测试 |
| 通用 native command 边界 | 2 个测试 |
| Rust client ↔ Rust server | 64 个确定性交错/重启场景 |
| Rust server 契约 | 8 个测试 |
| Compiler | 10 个测试；实现期间也编译了参考 `.model` corpus |
| Node client 边界 | close/start 回归修复后共 13 个测试，含有序事务、嵌套 savepoint、prerequisite 和 connection 生命周期 |
| 真实 Node/Prisma transaction bridge | 12 个测试 |
| Native backend + PostgreSQL + HTTP/WS | 23 个测试，含安全范围内的 BigInt 标量/列表及溢出拒绝 |
| Nest | 5 个 runtime 测试，以及对无效强类型 Handler input 的预期拒绝 |
| Dart native client | close/start 回归修复后共 6 个测试；analysis 在完整检查中通过 |
| 生成的 API | TypeScript 正/反例编译及 native 调用；Dart analysis 和 2 个 native 测试 |
| 真实 HTTP 端到端 | Node 和 Dart 连接 Rust/Prisma/PostgreSQL/SQLite；ACK 丢失重试、规范化、业务拒绝、离线重新打开、响应延迟期间的本地写入、后台暂停/恢复 |
| 优化 native build | Rust workspace 和 Node addon 构建成功 |
| 小规模容量诊断 | 10 次和 1,000 次真实 SQLite commit 的队列；[方法与测量](../../integration/rust/README.zh-CN.md) |

测试使用临时数据库和一次性 PostgreSQL 集群，不访问应用数据库，也不修改 Oasis。

## 审查

一次广泛的只读审查检查了 `97faef6..26e3f99`，并对后续修复做了专项审查。发现的问题包括不支持的 Identity 迁移、过期 connection 的归属/控制、安全 BigInt Loader 序列化，以及 close/start 生命周期竞态。每个问题都有回归测试和对应修复；专项复审批准了全部四项修复。更早的针对性审查还修正了 savepoint 生命周期、companion cascade 结算、迟到的 prerequisite 完成、实时唤醒竞态，以及异步 Nest provider 初始化。

## 平台与发布边界

| 平台 | 观察到的支持情况 |
| --- | --- |
| macOS，Node + Dart | 本地 arm64 和全新 hosted runner：已验证 native build、persistence、完整 HTTP E2E 和优化 artifacts。 |
| iOS arm64 simulator | Rust 静态库和 Flutter app 链接/构建已验证。Runtime smoke 在一次性 iOS 18.5 simulator 上未到达第一个 Dart main 标记；不能声称 FFI/SQLite 应用重启已通过。见[平台验证记录](../../integration/platform/README.zh-CN.md)。 |
| iOS device / Android | 未验证。本机没有 Android SDK/emulator。 |
| Linux，Node + Dart | 全新 Ubuntu 24.04 runner：完整 host 检查、真实 PostgreSQL/HTTP E2E、优化构建和 native binding smoke 均通过。 |
| Browser/WASM / Windows | 第一版源码实现未支持/验证。 |

源码 alpha 使用新的本地数据库。尚未实现原数据库/history 导入、任意 Identity/类型转换、生产规模索引、分布式提交后唤醒交付，以及更广泛的平台打包。保留原有 Channel 重叠限制和逐条跳过格式错误 Pull change 的行为。Record Revision、protocol reset/GC 和其他语义变化仍列于[后续事项](next-things.md)。

依赖审计：根目录开发工具，以及更新后的 Nest 11.2.3 package/测试依赖集，均报告零 npm 发现。示例/测试工具固定使用的 Prisma 6.19 CLI 报告了四项涉及 `effect` 和 `deepmerge-ts` 的 high 级别传递依赖问题；未执行强制大版本降级或 override。Framework runtime adapter 不依赖 Prisma CLI。公开分发前需要解决并重新验证这组工具依赖。

原实现保留在 Git 历史提交 `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8` 中。重写在 `codex/rust-rebuild` 上开发，并已合并到 `main`。在这个实现里程碑时，upstream 仓库为 private；当时尚未发布到 registry，也未授予许可。
