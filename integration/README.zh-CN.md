# 测试

[English](README.md) | [简体中文](README.zh-CN.md)

三层测试共享数据，各自独立实现测试逻辑：

1. Crate 测试与 Rust 模块放在一起。`integration/rust` 连接真实 Rust 客户端和服务端状态机，将确定性的 ACK/Pull/重启轨迹与预期可见状态进行比较。
2. `bindings` 测试语言回调和 native 生命周期；`persistence` 使用真实 PostgreSQL/Prisma 测试调用方管理的事务；`generated-api` 编译 TypeScript 正例/反例 fixture，并让生成的 Dart/TypeScript 调用 native Rust。
3. `e2e` 启动真实 HTTP 后端、PostgreSQL 和本地 SQLite，验证两种语言、规范化、拒绝、响应丢失，以及不被阻塞的本地编辑。

`fixtures/schemas` 和 `fixtures/protocol` 存放可复用的输入数据。`fixtures/compiler` 存放 `.model` 源定义。测试代码留在其所属模块或 integration package 中；临时 SQLite 和 PostgreSQL 状态在每次测试运行时创建，结束后删除。应用缓存和提交到仓库的二进制数据库都不作为 fixture。

从根目录运行完整的受支持 host 检查：

```sh
bash scripts/test.sh
```

要求 PATH 中有 Rust、Node 22.18+（使用 Node 26.4 测试）、Dart 3.12+、Python 3 和 PostgreSQL 命令行工具。脚本会安装仓库内的 JS/Dart 依赖、构建 native artifacts，并创建自己的临时 PostgreSQL 集群。它们不会使用个人数据库或 Oasis checkout。特定平台的 simulator 测试与常规 host 检查分开运行。

`.github/workflows/verify.yml` 在 macOS 和 Linux 上运行相同的 host 检查，然后构建优化后的 native artifacts 并执行 binding smoke。Workflow 定义本身不能证明 hosted runner 已通过；实际运行结果见验证记录。Action 配置参考官方 [checkout](https://github.com/actions/checkout)、[Node](https://github.com/actions/setup-node)、[Dart](https://github.com/dart-lang/setup-dart) 和 [Rust](https://github.com/dtolnay/rust-toolchain) action 文档。

[容量诊断](rust/README.zh-CN.md) 是单独运行的手动测量，不会作为容易波动的性能阈值加入正确性检查。
