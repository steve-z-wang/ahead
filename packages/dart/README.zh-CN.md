# Dart 客户端

[English](README.md) | [简体中文](README.zh-CN.md)

生成的 Model 类型位于通用 `Client` 之上；schema 校验、本地状态、SQL 读取、乐观重放、Channel Cursor、Mutation 调度与结算在 Rust 中执行。Native 调用在 worker isolate 中运行。

先从根目录运行 `bash scripts/build.sh` 构建 native library。`Client.open(path: ..., schema: schema, owner: userId, libraryPath: ...)` 在开发期间保留显式选择 native library 的能力。iOS 在未提供路径时使用链接到进程中的 native symbols；链接/构建步骤见 platform smoke harness。

核心操作包括 `transaction`、`mutate`、`read`、`querySpec`、`related`、`referencing`、`readSql`、`watch`、`subscribe`、`sync` 和 `close`。Compiler 生成强类型查询、过滤器、排序字段、关系访问器、不可变 Identity 和可空 patch。`Present(null)` 清空字段；省略 patch 字段则保持不变。

必须 await 每个事务操作。`tx.savepoint` 支持正确嵌套的回调；并发或未完成的回调会中止事务，不能逃逸 native session。Watch stream 发出初始结果和去重后的已提交结果。SQL 读取当前乐观快照，并拒绝写语句。

Transport 接收 `(kind, frozenJsonBody)` 并返回响应 JSON，只负责 I/O。`sync` 执行一轮追赶同步。`connect` 使用 Rust 调度维持后台工作和重试。返回的 `RuntimeConnection` 提供 `pause`、`resume`、`wake` 和 `close`。暂停/关闭会放弃待返回的网络响应，同时保留冻结请求以供稍后重试。从 transport 抛出 `AuthenticationExpired` 可触发可选的 `refreshAuth` 回调。Framework 不强制指定认证实现。

`runPrerequisites` 接收 host I/O 回调映射。任务逐个运行，必须能容忍重启后的重试。失败任务保留乐观状态，直到通过 `setReadiness(key, 'pending')` 重试，或丢弃尚未发送的 Mutation。`recordStatus` 提供 queued/frozen/accepted 阶段和持久化拒绝上下文；`dismissRejection` 清除用户已确认的本地 inbox 条目。

显式修改 schema 时，可提供 `migration: {'defaults': {'Entry': {'addedField': null}}, 'replayPull': true}`。迁移仅在 descriptor 变化时原子执行，并保留客户端 Identity、排队操作和冻结请求字节。它不会导入旧 framework 的 SQL 数据库，也不执行任意 Identity/类型转换。

Host 测试使用真实 SQLite 和 native Rust。Simulator/平台验证记录单独保存；这个 FFI package 未实现 browser/WebAssembly 支持。
