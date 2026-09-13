# Ahead

Local-first state for TypeScript and Dart. Write your API as handlers. Call it like a local function. It works offline, and the client is always one step ahead of the server.

Ahead is a library, not a service. Mutations settle in your own database transaction, and your app reads from a local SQLite copy that catches up as the server confirms.

## How it works

### 1. Describe your data and your mutations

```
model Todo {
  id    String
  title String
  done  Boolean
  @@id(id)
}

mutation AddTodo      { todo Todo.create }
mutation CompleteTodo { todo Todo.update<done> }
```

The compiler turns this file into a typed client for TypeScript and Dart, and into `Handlers` and `Loaders` types for the backend.

### 2. Read and write on the client

```ts
// Read.
const open = await client.models.todo.query({ where: { done: false } });

// Watch. Re-runs on every change.
client.models.todo.watch({ where: { done: false } }, (todos) => render(todos));

// Write, inside a transaction.
await client.transaction(async (tx) => {
  await tx.mutate.addTodo({
    todo: { id: "t1", title: "Buy milk", done: false },
  });
  await tx.mutate.completeTodo({
    todo: { identity: { id: "t1" }, values: { done: true } },
  });
});
```

```ts
// Open the local database and connect.
import { GeneratedClient, httpTransport } from "./generated/client.ts";

const client = await GeneratedClient.open({
  path: "local.sqlite",
  transport: httpTransport({
    url: "http://127.0.0.1:4242",
    token: "demo-user",
  }),
});

// Subscribe to the channels you want to sync.
await client.channels.subscribe("todos");
```

The connection sends queued mutations when the network allows, retries on its own, and pulls every record the backend notified about.

### 3. Write the backend

```ts
import {
  createBackend,
  devAuth,
  type Handlers,
  type Loaders,
} from "./generated/backend.ts";

// Implement a handler for each mutation. notify tells subscribers what to reload.
const handlers: Handlers<Tx> = {
  async addTodo({ input, tx, notify }) {
    await tx.todo.create({ data: input.todo });
    notify({ channel: "todos", records: [input.todo] });
  },
  async completeTodo({ input, tx, notify }) {
    await tx.todo.update({
      where: input.todo.identity,
      data: input.todo.patch,
    });
    notify({ channel: "todos", records: [input.todo] });
  },
};

// Load records by id.
const loaders: Loaders<Tx> = {
  todo: ({ ids, tx }) =>
    Promise.all(ids.map((identity) => tx.todo.findUnique({ where: identity }))),
};

// Start the server.
const backend = createBackend({
  database: prisma(new PrismaClient()),
  authenticate: devAuth(),
  handlers,
  loaders,
});
await backend.listen({ port: 4242 });
```

## What you get

- **Offline writes.** Mutations queue locally and are sent in order when a connection is available.
- **Reads that never wait.** Every read is a local SQLite read, including changes the server has not confirmed yet.
- **Your transaction, your rules.** A handler can reject a mutation. The client rolls the optimistic change back and keeps the server's state.
- **No vendor service.** The backend is a function you host. Data lives in your database.

## Try it

You need Rust, Node 22.18+, Python 3 and the PostgreSQL command-line tools.

```sh
bash examples/rust-round-trip/run.sh
```

In another terminal:

```sh
node examples/rust-round-trip/client.mts
```

Type `edit some text`. The entry prints twice: first the local change, then the server's version. Stop the server, edit again, and start it back up to watch the queue settle. The [example README](examples/rust-round-trip/README.md) walks through the setup.

## Status

Ahead is a source alpha. There is no package release and no license grant yet. The client runs on native macOS through Node and Dart; browser and mobile builds are separate targets.

Everything else lives on the [documentation site](website/README.md): concepts, the wire protocol, testing, and the architecture decisions behind the Rust core.
