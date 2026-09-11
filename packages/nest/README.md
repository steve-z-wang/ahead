# Nest integration

`@Handles(name, version)` and `@Loads(model)` mark methods on ordinary singleton business providers. The Nest adapter discovers them after provider construction, including asynchronous dependencies, and binds the real instance. Duplicate or missing registrations fail application startup. Request-scoped and transient backend providers are rejected; pass request information through the handler/loader context.

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

Import `LocalFirstModule.register({config, transaction, persistence, principalChannel, authorize})` alongside your business providers. After Nest initialization, obtain `LOCAL_FIRST_BACKEND` and attach the normal HTTP/WebSocket adapters to your existing server. The module does not listen on its own port. Business providers may be injected normally; backend methods intentionally fail if called before Nest initialization finishes.

`NestHandler<Transaction, Input>` and `NestLoader<Transaction, Identity>` provide structural method types. Decorators provide runtime registration metadata; they do not validate TypeScript method input types by themselves. `registrationsFromProviders(instances)` also works without a Nest application and returns ordinary function registration maps.

Real Nest application-context tests and a compile-time invalid-input fixture live in `integration/nest`.

Provider discovery runs in `onModuleInit`, after singleton construction. Backend calls in provider constructors are unsupported; wait for Nest application initialization. Methods remain bound to the constructed instance, so asynchronous injected dependencies and private fields work correctly.
