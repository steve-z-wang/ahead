# Nest 集成

[English](README.md) | [简体中文](README.zh-CN.md)

`@Handles(name, version)` 和 `@Loads(model)` 用来标记普通单例业务 provider 上的方法。Nest adapter 在 provider 构造完成后发现这些方法，包括异步依赖完成后的情况，并绑定真实实例。重复或缺失的注册会导致应用启动失败。Backend provider 不允许使用 request scope 或 transient 生命周期；请求信息通过 Handler/Loader context 传递。

```ts
@Injectable()
class EntryService {
  @Handles('Edit', 1)
  async edit(ctx: WriteContext<Transaction>, input: EditInput) {
    await ctx.transaction.entry.update({
      where: input.entry.identity,
      data: input.entry.patch,
    });
    await ctx.publish(
      [{model: 'Entry', identity: input.entry.identity}],
      ['book:example'],
    );
    return {channel: 'book:example'};
  }

  @Loads('Entry')
  async load(ctx: ReadContext<Transaction>, identities: readonly EntryIdentity[]) {
    return Promise.all(identities.map(identity =>
      ctx.transaction.entry.findUnique({where: identity})));
  }
}
```

将 `LocalFirstModule.register({config, transaction, persistence, principalChannel, authorize})` 与业务 provider 一起导入。Nest 初始化完成后，获取 `LOCAL_FIRST_BACKEND`，将常规 HTTP/WebSocket adapter 挂载到现有 server。Module 不会监听自己的端口。业务 provider 可以正常注入；在 Nest 初始化完成前调用 backend 方法会明确失败。

`NestHandler<Transaction, Input>` 和 `NestLoader<Transaction, Identity>` 提供结构化方法类型。Decorator 提供 runtime 注册元数据，本身不会校验 TypeScript 方法的 input 类型。`registrationsFromProviders(instances)` 也可在没有 Nest application 的情况下使用，返回普通函数注册映射。

真实 Nest application-context 测试和编译期无效 input fixture 位于 `integration/nest`。

Provider discovery 在单例构造完成后的 `onModuleInit` 中执行。不支持在 provider constructor 中调用 backend；请等待 Nest application 初始化。方法保持绑定到构造出的实例，因此异步注入依赖和私有字段均可正常使用。
