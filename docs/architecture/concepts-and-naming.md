# 概念与命名

2026-09-10：用户已确认以下命名。用于新 Rust 实现、语言 SDK、拟议接口与当前设计文档。命名调整不改变参考实现的行为；本分支当前只有文档。

## 统一术语

| 旧名称 | 确认名称 | 含义 |
|---|---|---|
| Model | Model | 客户端数据模型，不要求对应后端的一张表。 |
| Record | Record | 某个 Model 的一条数据。 |
| Identity | Identity | 单字段或复合身份；同一 Model 内识别 Record。 |
| Mutation | Mutation | 客户端提交的业务操作，可先在本地乐观呈现。 |
| Handler | Handler | 业务作者提供的 Mutation 后端实现。 |
| Materializer | Loader | 给定上下文与 identities，读取、聚合或转换当前后端数据，返回客户端权威状态。 |
| Scope | Channel | 应用显式命名、可动态订阅的数据分发范围，有独立的接收进度。 |
| Publish | Publish | 显式向 Channels 声明哪些 Records 发生变化；在用户事务内持久化 invalidation。 |
| Client | Client | 前端查询、监听、修改本地状态的入口。 |
| Persistence | Persistence | 持久化契约；PrismaPersistence、SqlitePersistence 等名称表达具体实现。 |
| Uplink / Downlink | Push / Pull | 发送待处理操作 / 获取权威变化的路径与内部模块。 |
| Sync ID | Cursor / Checkpoint | Cursor 表达当前位置；Checkpoint 表达操作结算要求达到的位置。 |

## API 与模块命名

- 单数 `channel`，复数 `channels`，业务构造函数例如 `bookChannel(bookId)`。
- 回调称为 `Loader`，拟议注册入口为 `Entry.loader(...)`；调度接口为 `LoaderDispatcher`。若实现可选 Nest decorator，采用 `@Loads`，与操作的 `@Handles` 对应。
- 路径使用 `push` / `pull`，类型使用 `Push…` / `Pull…`；例如 `PullPage`。
- `ChannelCursor` 表达某个 Channel 的当前位置；`ChannelCheckpoint` 表达需要到达的位置。必须携带或通过上下文确定 Channel，不能只比较脱离 Channel 的数字。
- `requiredCheckpoints` 是结算条件；概念命名不决定具体 wire 属性拼写。
- `ServerPersistence` / `TransactionPersistence` 和 `ClientStore` / `ClientTransaction` 保留职责区分。默认客户端 SQLite adapter 的 crate 仍是 `lfs-sqlite`；无需为符合词表把所有存储接口强行改名。

以下仅示意名称，完整 callback 签名、注册机制按实现阶段确定：

```ts
Entry.loader(async (ctx, identities) => {
  return entries.readVisible(ctx, identities);
});

// store 已绑定应用当前事务；完整 Handler 的 batch 去重与 receipt 流程另见架构。
await publisher.publish(store, {
  channels: [bookChannel(bookId)],
  model: Entry,
  identity: { id: entryId },
});
```

## 语义边界

Channel 用于分发，不参与 Record Identity 的组成。同一 Channel 可以包含多个 Model；同一 Record 的现有多 Channel 行为按参考实现保留，不因为改名承诺解决跨 Channel 乱序。

Publish 声明变化，Pull 通过 Loader 读取当前完整权威状态。Channel 不是保证交付每次历史变更的事件日志。Loader 名称也不新增只读限制：原 prepareForViewer 的行为、身份对齐、可见性与事务契约都保留。

Push/Pull 表示数据流方向，不限制 HTTP/WS 或通知驱动的调度方式；不因为叫 Pull 就改成仅轮询。Mutation ACK 仍需结合 required checkpoints 与原 accepted-prefix 规则才能撤下 optimism。

Cursor 与 Checkpoint 可以使用同一位置数值，但用途不同。发布时递增的是每 Channel 的持久化 counter/head；它不是新的全局计数器，也不是 Record Revision。不同 Channel 的 Cursor 不能比较新旧。

## 旧名称与兼容边界

本轮更新设计、拟议 API 与未来模块名。旧源码审查中的真实路径、符号和引用保留原名，便于在参考提交定位。旧 wire 字段、数据库列名、持久化数据和历史 fixtures 不自动重命名；新 API/内部符号在边界映射到既有表示。未来若改 wire/storage，需要单独列出兼容与迁移方案。

新的 record revision、跨 Channel 仲裁及其他语义变化见 [Next things / TODO](../next-things.md)，不是此次改名的一部分。
