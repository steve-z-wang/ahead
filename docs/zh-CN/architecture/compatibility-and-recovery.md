# 兼容性与恢复

[English](../../architecture/compatibility-and-recovery.md) | [简体中文](compatibility-and-recovery.md)

这个源码 alpha 版本使用新的本地 SQLite 布局。请打开一个新的数据库路径，不要指向 Oasis 数据库。历史实现仍保留在 Git 历史提交 `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8` 中。迁移现有应用需要先处理完待写入操作，或另行设计 importer；此版本不会删除或转换旧数据库。

## 边界

| 边界 | 第一版契约 |
| --- | --- |
| Wire 名称 | 保留旧版 `scope`、`syncId`、`requiredScope`、`requiredSyncId` 和 `requiredCheckpoints`；公开 API 使用 Channel、Cursor 和 Checkpoint。 |
| 数字 | JavaScript 安全范围内的 JSON 整数。Counter 编码不变。 |
| Mutation 版本 | Compiler 保留历史 input 快照；后端注册每个受支持的名称/版本。不支持的版本在 Handler 执行前失败。 |
| 增量 schema 演进 | 旧 schema 可以接收新增的可空字段。接收到的未知字段被忽略；Loader 输出按其声明的 schema 校验。 |
| 已有本地缓存 | Descriptor 变化需要显式增量迁移。默认值以原子方式填充缺失字段。冻结请求逐字节保持不变。Identity/类型转换及移除会被拒绝。 |
| Channel 重叠 | Channel Cursor 相互独立。没有跨 Channel 的 Record Revision 或全序。仍受原有 claim 和到达顺序的限制。 |
| Browser | JavaScript SDK 使用 native Node binding。尚不支持 WASM/browser persistence。 |

## 应用恢复

- Push 响应丢失后，使用已存储的字节和 batch sequence 重试。保留同一本地数据库和客户端 Identity；后端 receipt 防止业务被执行第二次。
- 收到 ACK 后，会保留乐观修改直到所需的 Pull Checkpoint 到达。尝试清除本地状态前，先排查 Channel 访问/发布和网络连接。
- 业务拒绝会出现在持久化 inbox 中。展示 code，检查 `recordStatus`，并在用户看过后 dismiss 拒绝。一次新的编辑是新的 Mutation。
- 失败的 prerequisite 工作继续在本地可见。Host 将其 readiness key 设回 `pending`，并再次运行 prerequisite 回调以重试。回调必须能容忍重启后的重试。
- SQLite commit 使用 generation 检查。过期 writer 会失败，不会覆盖较新的 commit。每个本地数据库只使用一个活跃 Client；重试应用工作前，先关闭并重新打开过期实例。
- 外部业务事务使用已绑定的 publisher，在事务内检查 `assertCommittable()`，在关闭 session 前获取 `notify = session.afterCommit()`，然后在应用事务 resolve 后调用 `notify()`。这会唤醒当前进程中的订阅者。多进程部署必须通过自己的基础设施转发已提交的 Channel 通知。
- 权限变化需要发布由此产生的可见性变化。取消订阅不能替代服务端授权或权威撤回。

不要为了处理错误而手动删除 pending batch、before image、Cursor 或 framework receipt 行。它们之间的关系属于结算/重试协议。保留数据库备份用于诊断。此版本没有自动 protocol reset 或垃圾回收器。

## 容量

服务端 invalidation 按 Channel/Model/Identity 压缩，但不同 Identity 和客户端 receipt 仍会累积。本地排队的 Mutation、拒绝详情和缓存 Record 会持久保存。这些表没有 TTL 上限。取消订阅会停止期望的同步；缓存 Record 和 claim 会保留到权威撤回或其他现有清理发生，并不会因此设置全局缓存大小上限。

当前 SQLite adapter 将状态加载到内存中，并提交发生变化的文档。只读 SQL 为每次查询创建隔离的 projection。这些选择适合验证行为，不能证明生产规模的吞吐量。上线前应测量工作集，并跟踪数据库大小、pending 存续时间/数量、被拒绝条目以及 Pull 滞后。
