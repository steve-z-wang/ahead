# Node native transaction probe（M0）

[English](README.md) | [简体中文](README.zh-CN.md)

这是可行性探针，不是 server SDK 或通用 persistence adapter。
Rust 通过 NAPI-RS 在进程内运行，不管理数据库连接。`run_probe`
通过 thread-safe function 调用 Node host，等待返回的 JavaScript
Promise，再调用读取回调、等待其完成，最后返回观察到的计数。
JavaScript closure 只捕获应用提供的事务。

`committedResult(userTransactionRunner, body)` 注册事务作用域，
在 body 返回前拒绝被捕获的持久化错误或未完成的 native 操作，
并在 `finally` 中关闭所有 handle。调用方的 runner 管理 begin、
commit 和 rollback。只有 runner resolve 后（包括成功提交），
accepted result 才能返回到外部。在该作用域外直接构造 `TransactionProbe`
会被拒绝。显式业务拒绝使用应用的 savepoint；
它是领域结果，不是将持久化事务标为失败的异常。

从仓库根目录运行：

```sh
bash integration/persistence/transaction-probe/run.sh
```

要求：Rust/Cargo、Node/npm、PostgreSQL `initdb`/`pg_ctl`、Python 3。
如果仓库内 `.tools` 中有 Rust，脚本会使用它。脚本构建 native library，
安装锁定版本的 Prisma 依赖，生成 fixture client，在空闲本地端口创建自己的
临时 PostgreSQL 集群，运行 12 个测试，并在退出时停止/删除集群。
它不会使用外部 `DATABASE_URL`。

如果已有隔离的测试数据库，安装并生成后可运行：

```sh
node bindings/node/build.mjs
DATABASE_URL=postgresql://USER@127.0.0.1:PORT/postgres node --test integration/bindings/node/transaction-bridge.test.mjs
```

直接测试命令会创建/删除 probe table 数据；只能使用可丢弃的
probe 数据库。在集成到 release workspace 前，native crate 是独立的 Cargo workspace，
拥有自己的 lockfile。构建产物和生成的 Prisma client 已被忽略。
`.d.mts` 文件描述 M0 接口。

2026-09-10 在 macOS arm64 上验证：Rust 1.98.1、Node 26.4.0、PostgreSQL 14、
Prisma 6.19.0、napi 3.12.2、napi-derive 3.6.4、napi-build 2.4.2。
最初的契约测试中有八个因缺少 bridge 而失败的测试，以及一个通过的全局 client 反向对照；
最终隔离测试结果为 12 通过、0 失败。另一个新增指标断言
在实现前失败，重新构建后通过。

成功的往返报告两次回调、native 耗时微秒数，以及
18 个逻辑 payload 字节（UTF-8 操作名加上两个 u32 回调结果）。
其中不包含 NAPI object/Promise 开销和最终结果 object；
这里没有 JSON serializer。该探针不对延迟或语言速度作出结论。

限制：不包含生产用 receipt/publication API、HTTP ACK encoder，
或通用 runtime cancellation 实现。Accepted-result 检查使用真实的
延迟约束提交失败，在 runner 边界进行测试。事务超时使用延迟回调测试；
任意永不完成的 host 代码无法被该探针强制中断。关闭会阻止后续 host DB
操作，但无法撤销已经执行中的 host 操作；回滚由外层事务提供。
并发隔离测试使用 Repeatable Read。

`npm audit` 当前报告固定版本 Prisma 6 工具链中有四项 high 级别发现
（`@prisma/config`、`deepmerge-ts`、`effect`、`prisma`）。未通过强制降级或
不兼容 override 掩盖这些结果。该依赖集用于本地集成测试工具，
在生产打包前需要审查发布依赖。

API 依据：NAPI-RS 官方 `ThreadsafeFunction` Promise 示例，
以及可捕获同步抛错的 `call_async_catch` API：
https://github.com/napi-rs/napi-rs/blob/main/examples/napi/src/threadsafe_function.rs
