# TypeScript 客户端

[English](README.md) | [简体中文](README.zh-CN.md)

`Client.open({path,schema,owner})` 打开共享 Rust runtime，并使用真实 SQLite 持久化。导入这个源码 package 前，请先构建 `bindings/node`。生成的 Model API 包装通用客户端；schema 是 runtime 数据，添加 Model 不需要重新编译 Rust。

```ts
const client = await Client.open({path: 'local.sqlite', schema, owner: userId});
const models = new GeneratedClient(client);
await client.subscribe('book:example');
await models.edit({entry: {identity: {id: 'entry-1'}, values: {text: 'offline'}}});
await client.sync(transport);
```

Transport 接收 `push` 或 `pull` 及冻结的 JSON body，返回响应 JSON。HTTP/网络错误应抛出异常。示例后端将它们映射到 `/sync/mutations` 和 `/sync/pull`。`sync` 执行一轮追赶同步。等待网络 I/O 时，本地事务仍可使用。

`connect(transport, {onError, refreshAuth})` 在后台运行，由 Rust 控制重试时机。返回的 connection 支持 `pause`、`resume`、`wake` 和 `close`。Transport 可以接受可选的 `AbortSignal`；即使 transport 忽略取消，close 也会放弃其响应。给认证错误设置 `status: 401`，可触发可选的刷新回调。Runtime 不内置认证或凭据。

`transaction(async tx => ...)` 支持读取自己在事务中的写入，以及嵌套的 `tx.savepoint(async () => ...)`。每个操作都必须 await。调用会串行执行；失败或未完成的回调不能逃逸提交/回滚边界。Watcher 会发出初始结果和已提交的变化，并抑制重复结果。`querySpec`、`related`、`referencing` 和 `readSql` 都在 Rust 中执行。SQL 读取隔离的乐观快照，不能写入持久化表。

`pendingTasks` 描述排队的 Mutation 所需的 prerequisite I/O。`runPrerequisites({Upload: async args => ...})` 逐个执行这些任务。回调必须能容忍进程终止后的重试。失败任务继续保留乐观状态；使用 `setReadiness(key, 'pending')` 重试，或使用 `drop(ordinal)` 取消尚未发送的 Mutation。Rust 决定 readiness 并保留失败状态。

显式升级 schema 时，在用新 descriptor 打开数据库的调用中提供 `migration: {defaults: {Entry: {newField: null}}, replayPull: true}`。迁移会以原子方式改变缓存行的结构，并可选择回退 Channel Cursor，同时保留冻结请求和离线队列。每次 schema 变更只应用一次迁移；重复打开不会重置进度。需要自定义数据转换的 Identity/类型转换，以及原 framework 数据库的导入，尚未实现。

使用 `close()` 释放 native handle 和 connection。第一版源码 package 已在 native macOS 上运行验证；browser/WebAssembly 和分发用二进制属于其他目标。
