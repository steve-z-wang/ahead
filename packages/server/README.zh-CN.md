# TypeScript 后端 SDK

[English](README.md) | [简体中文](README.zh-CN.md)

这个 TypeScript SDK 将共享 Rust server runtime 嵌入你的 Node 应用。业务 Handler 和 Loader 使用 TypeScript 实现。

`index.mts` 运行于支持 TypeScript 的 Node（Node 22.18+），也可以使用 TypeScript 编译。通过 `node bindings/node/build.mjs` 构建本地 native module。如果将 native artifact 打包到其他位置，可注入 `native` 实现。

```ts
import {createBackend, MutationRejected} from './packages/server/index.mts';
import {PrismaPersistence, prismaTransactions} from './packages/persistence-prisma/index.mts';

const backend = createBackend({
  config: generatedServerConfig,
  transaction: prismaTransactions(prisma),
  persistence: tx => new PrismaPersistence(tx),
  principalChannel: userId => userId,
  authorize: async ({transaction, viewerUserId, channel}) => canRead(transaction, viewerUserId, channel),
  handlers: {
    editTask: {1: async ({transaction, actorUserId, publish}, {task}) => {
      if (!await canEdit(transaction, actorUserId, task.identity)) throw new MutationRejected('task.forbidden');
      await transaction.task.update({where: task.identity, data: task.patch});
      await publish([{model: 'Task', identity: task.identity}], ['team:example']);
      return {channel: 'team:example'};
    }},
  },
  loaders: {
    Task: {
      load: async ({transaction, viewerUserId, channel}, identities) =>
        Promise.all(identities.map(identity => loadVisibleTask(transaction, viewerUserId, channel, identity))),
    },
  },
});
const receiptJson = await backend.push(authenticatedUserId, requestBytes);
const pageJson = await backend.pull(authenticatedUserId, requestBytes);
```

外层事务由应用管理。Persistence、Handler、可选的 `prepareForViewer`、授权、Loader 和 Publish 回调均接收同一个事务。后台任务和其他业务写入也可以在现有事务内调用 `backend.publish(transaction, changes, channels)`。Runner 必须提供一致的快照（Repeatable Read 或更强），在 Promise 被拒绝时回滚，并重试序列化冲突。`prismaTransactions` 提供这一契约。Framework 驱动的 Push 和 Pull 即使在 Handler 捕获发布错误后，也会保留该错误、等待未完成的回调结束，并在操作未被 await 时拒绝完成事务。

成功的 Handler 返回 `{channel: string}` 来选择 receipt 的 Checkpoint，或返回 `undefined` 使用 principal Channel。Publish 是显式操作，可以面向多个 Channel。显式的 `MutationRejected` 或已注册的 `translateRejection` code 会回滚该 Mutation 的 savepoint，包括业务影响和发布；其他所有异常都会中止整个 batch。异常转换必须产生稳定的机器可读 code。已知 Mutation 的不受支持版本会在任何 Handler 执行前中止 batch。

配置内部使用 `{schema, mutations, loaders}`；SDK 从注册项中获取 Loader 名称。每个 Mutation 包含 `{name, version, slots, input?}`。历史 `input` 是对应版本的完整 schema。Slot 包含 `{name, model, operation, cardinality, allowedPatchFields?, bindings?}`。Operation 为 `create`、`update` 或 `delete`；cardinality 为 `single`、`optional` 或 `list`。Binding 使用 `{slot, fields}` 将一条 create 记录绑定到另一个 single slot 的 Identity。Create 的参数为 `{identity, data}`，update 为 `{identity, patch}`，delete 为 `{identity}`。List slot 产生数组；缺失的 optional slot 产生 null。

Wire 词汇仍为 `scope`、`syncId`、`requiredScope`、`requiredSyncId` 和 `requiredCheckpoints`。Loader 必须严格按照传入的顺序，为每个 Identity 返回一个 state object 或 null。缺失或无权访问的行返回 null。Loader 缺陷会让请求失败，绝不会跳过行或将 Cursor 推进到错误之后。Pull 最多扫描 50 条压缩后的 invalidation，并加载它们的当前状态。

运行 `integration/persistence/server/run.sh` 可执行一次性 PostgreSQL/Prisma 集成测试。数据库由 runner 创建、使用和销毁。

对于外部业务事务，绑定一个完成检查，并在事务回调返回前调用它：

```ts
const notifyCommitted = await prisma.$transaction(async tx => {
  const session = backend.bindTransaction(tx);
  try {
    await session.publish(changes, channels);
    await session.assertCommittable();
    return session.afterCommit();
  } finally { session.close(); }
}, {isolationLevel: 'RepeatableRead'});
notifyCommitted();
```

返回的 hook 只能在事务 Promise resolve 之后运行：这是用于唤醒实时订阅者的显式提交边界。仍可直接调用 `backend.publish(tx, ...)`，但由于 backend 不管理事务提交，它无法承诺实时唤醒。外部事务管理者如果捕获发布错误，必须回滚；只有 `bindTransaction` 能保留被吞掉的错误以供完成检查。业务 Handler 必须 await 所有数据库工作。Session tracking 覆盖 framework 发布和 host 回调，不覆盖任意未 await 的 ORM 调用。

`createHttpHandler({backend, authenticate})` 提供处理 POST `/sync/mutations` 和 `/sync/pull` 的 Node HTTP handler。认证返回可信的 owner ID 或 null。它返回 JSON 响应和稳定的错误 code，默认将 body 限制为 1 MiB，并提供可选 `onError` 日志入口，不会向客户端返回内部错误细节。将它挂载到 Node HTTP server；TLS 和认证由应用负责。

将实时路由挂载到同一个应用管理的 server，并在关闭时解除挂载：

```ts
const http = createServer(createHttpHandler({backend, authenticate}));
const live = attachLive(http, {backend, authenticate});
await live.close();
```

`/sync/live` 只接受一个 `{type:"subscribe",scopes:[...]}` frame。它在同一个一致事务中为每个 scope 授权并获取 head，安装所有唤醒 listener，然后发送 `subscribed` 响应。客户端发送第二个 frame 会以 code 1002 关闭连接。成功的 framework 事务在提交后唤醒订阅者；回滚和重复 Mutation receipt 不触发唤醒。每次唤醒都会从已捕获的 Cursor 开始持续获取旧版 PullPage wire 数据；只要一页包含 50 条 change，就自动继续获取。
