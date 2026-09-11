# Prisma 事务持久化

[English](README.md) | [简体中文](README.zh-CN.md)

在应用部署期间，将 `migration.sql` 应用到 PostgreSQL。把现有 Prisma interactive transaction 传入 `new PrismaPersistence(tx)`。Adapter 既不创建 Prisma client，也不启动事务。

Client 行锁将同一客户端的 batch 串行化，并将客户端绑定到其已认证 owner。Channel head 递增和压缩后的 invalidation upsert 共用调用方的事务。Savepoint 由经过校验的数字 Mutation ordinal 生成。SQL 值使用 PostgreSQL 参数；只有经过校验的 savepoint 标识符会被插入 SQL 字符串。

Rust、adapter 和数据库约束都会将 counter 限制在 JavaScript 安全整数范围内。Receipt 文本原样存储，并在语义完全一致的重试中返回。表名使用 `lfs_` 前缀，目前为固定名称。应用接入方式见 [Server README](../server/README.zh-CN.md)。
