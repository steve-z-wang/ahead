# local-first-state

[English](README.md) | [简体中文](README.zh-CN.md)

一个采用共享 Rust runtime、提供强类型 Dart/TypeScript API 的 local-first state framework。

第一版通过嵌入式 Node 后端和 Prisma/PostgreSQL，为使用本地 SQLite 的客户端提供服务。Rust 负责 schema 校验、乐观状态、持久化 Mutation batch、Channel Cursor，以及 ACK/Pull 结算。业务代码提供 Handler、Loader，并在应用自己管理的事务内显式向 Channel 发布变化。生成的业务类型保留在 Dart/TypeScript 中。

## 试用

安装 Rust、Node 22.18+、Python 3 和 PostgreSQL 命令行工具后运行：

```sh
bash examples/rust-round-trip/run.sh
```

在另一个终端中运行：

```sh
node examples/rust-round-trip/client.mts
```

使用 `sync`、`edit TEXT`、`show` 和 `status` 观察离线编辑、服务端规范化和持久化重试。[示例说明](examples/rust-round-trip/README.zh-CN.md) 提供完整的启动步骤。安装 Dart 后，可通过 `bash integration/e2e/run.sh` 让两种客户端连接真实后端运行。

## Packages

| 领域 | 实现 |
| --- | --- |
| 共享值与协议 | `crates/lfs-core` |
| 客户端状态与调度 | `crates/lfs-client` |
| 服务端状态机 | `crates/lfs-server` |
| 本地持久化与只读 SQL | `crates/lfs-sqlite` |
| Schema compiler 与语言生成器 | `crates/lfs-compiler` |
| Native 边界 | `bindings/common`、`bindings/node`、`bindings/dart` |
| 前端 API | [TypeScript](packages/client-js/README.zh-CN.md)、[Dart](packages/dart/README.zh-CN.md) |
| 嵌入式后端 | [Server](packages/server/README.zh-CN.md)、[Prisma](packages/persistence-prisma/README.zh-CN.md)、[Nest](packages/nest/README.zh-CN.md) |

## 测试与设计

`bash scripts/test.sh` 构建并验证受支持的 native host。[测试说明](integration/README.zh-CN.md) 介绍三层测试及共享 fixture 目录。[实现验证记录](docs/zh-CN/implementation-progress.md) 记录已验证的覆盖范围和剩余的平台限制。

- [概念与已确认命名](docs/zh-CN/architecture/concepts-and-naming.md)
- [代码组织与语言边界](docs/zh-CN/architecture/code-organization.md)
- [兼容性与恢复](docs/zh-CN/architecture/compatibility-and-recovery.md)
- [后续事项](docs/zh-CN/next-things.md)
- [架构决策](docs/zh-CN/superpowers/specs/2026-09-10-rust-core-design.md)
- [实施路线图](docs/zh-CN/superpowers/plans/2026-09-10-rust-rebuild.md)
- [参考行为清单](docs/zh-CN/superpowers/specs/2026-09-10-existing-logic-audit.md)

- [文档语言与维护约定](docs/zh-CN/documentation.md)

这是源码 alpha 版本。跨 Channel 的 Record Revision 及相应的新冲突规则仍留待后续实现。目前保留原有的逐条跳过无效 Pull change 的行为，以及 Channel 重叠的限制。实时唤醒仅在当前进程内生效；多进程部署需要 host 提供提交后的通知机制。第一版 SQLite 实现在内存中保留快照，并写入发生变化的文档；大规模缓存性能仍需专门优化。它不会导入原有数据库布局。

参考实现保留在 Git 历史提交 `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8` 中。本分支是从零实现的版本，共享 wire 行为有测试覆盖；它不提供可直接替换的数据库迁移。尚未发布 package，也未授予许可。
