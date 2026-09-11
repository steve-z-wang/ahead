# PostgreSQL 事务契约

[English](README.md) | [简体中文](README.zh-CN.md)

从仓库根目录运行 `bash integration/persistence/transaction-probe/run.sh`。
脚本创建自己的临时 PostgreSQL 集群，并在成功或失败后清理。
Prisma schema 和测试 package 一起放在 `integration/bindings/node` 下，
使 client generation 能解析固定版本的 package，无需在仓库其他位置安装依赖。
Native binding 和生命周期说明见 [Node binding 说明](../../../bindings/node/README.zh-CN.md)。

契约覆盖业务与 framework 共同回滚、刻意使用全局 client 的反向对照、成功提交与关闭 handle、
捕获错误后仍将事务标为失败、host 写入后的 Rust 失败、资源释放、事务超时、并发事务作用域、
真实的延迟约束提交失败、同步回调抛错、未 await 的工作，
以及在前面的工作仍提交时回滚某个 Mutation savepoint。
