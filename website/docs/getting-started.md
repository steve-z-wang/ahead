# Getting started

Run a complete Ahead app from source: a generated TypeScript client with local SQLite, and your own TypeScript backend using Prisma/PostgreSQL. You will make a local edit, see the backend normalize it, work offline and observe a business rejection.

## Prerequisites

Use a macOS or Linux development environment with:

- Node.js 22.18 or newer and npm.
- Rust/rustup, using the repository's `rust-toolchain.toml`.
- Python 3 and a C/C++ build toolchain for the native Node addon.
- PostgreSQL tools `initdb` and `pg_ctl` on `PATH`.
- Internet access for the first dependency/build setup.

Run all commands below from the repository root. Packages have not been published; these instructions use the checked-in source and generated APIs.

## 1. Start the backend

```sh
git clone https://github.com/zanminwang/ahead.git
cd ahead
bash examples/rust-round-trip/run.sh
```

The runner builds the native runtime, generates the interfaces, installs example dependencies, and starts a private disposable PostgreSQL cluster. It creates the example tables and seeds `Entry` with ID `entry-1`.

Wait for:

```text
Example listening at http://127.0.0.1:4242
```

The server uses development authentication, `Bearer demo-user`. Keep this terminal open. Stopping the runner removes its temporary backend database; it is not a persistent application deployment.

## 2. Open a client

In another terminal, from the repository root:

```sh
node examples/rust-round-trip/client.mts
```

The client opens `example-client.sqlite`, connects to the backend and subscribes to `book:demo`. It catches up over HTTP and receives subsequent changes over WebSocket. It may first print null while its cache is empty, then the entry with text `Hello from the server`.

The CLI accepts `edit TEXT`, `offline`, `online`, `status` and `quit`. `AHEAD_DATABASE` selects a different local SQLite file, and `AHEAD_URL` selects a backend URL.

## 3. Make an edit

Enter this in the client terminal (the extra spaces are intentional):

```text
edit   hello
```

The local record changes immediately. The handler trims whitespace in the backend; synchronization then supplies `hello`. The watcher reports the resulting changes. The corresponding application call is:

```ts
await client.transaction(tx => tx.mutate.edit({
  entry: { identity: { id: 'entry-1' }, values: { text: '  hello' } },
}));
```

The transaction resolves after local commit. It does not wait for the handler to accept the mutation.

### Watch another client

Keep the first client open and start a second one from another terminal, using its own local database:

```sh
AHEAD_DATABASE=example-client-peer.sqlite node examples/rust-round-trip/client.mts
```

Edit the entry in either client. After the backend accepts it, the other client's watcher updates through WebSocket without a manual sync call. Each client reads its own SQLite file; the shared channel carries the server's record changes.

## 4. Work offline

Enter one command at a time:

```text
offline
edit   offline draft
status
```

The edit is visible locally and `status` shows pending work. The backend remains unchanged because the connection is paused. Resume synchronization:

```text
online
```

The backend normalizes the text to `offline draft`; the receipt carries that result and the pending work completes as soon as it arrives. To observe persistence, pause, edit, `quit`, then reopen the same client while keeping the backend running. The queued edit survives reopening and sync resumes automatically.

## 5. See a rejection

```text
edit reject
```

The handler rejects this exact text with `entry.denied`. The local value may appear briefly, then the runtime removes that mutation's optimistic change. `status` includes the durable rejection. Applications can use `recordStatus` and `dismissRejection` to explain and acknowledge it in the UI.

## 6. Stop the example

Enter `quit` in the client, then stop the backend runner with Ctrl-C. Client SQLite persists; the example's temporary PostgreSQL database does not.

For a new backend run, use a **new local database path** so old receipt/cursor history is not paired with a reset server:

```sh
AHEAD_DATABASE=example-client-second-run.sqlite node examples/rust-round-trip/client.mts
```

Choose a fresh filename for each fresh backend cluster. Do not delete an application's pending state as a general recovery technique.

## Understand the files

| File | Role |
| --- | --- |
| [models/entry.model](https://github.com/zanminwang/ahead/blob/main/examples/rust-round-trip/models/entry.model) | Record schema and local mutation contract |
| [generated/client.ts](https://github.com/zanminwang/ahead/blob/main/examples/rust-round-trip/generated/client.ts) | Generated TypeScript client entry point |
| [generated/backend.ts](https://github.com/zanminwang/ahead/blob/main/examples/rust-round-trip/generated/backend.ts) | Generated typed handlers/loaders and bound `createBackend` |
| [generated/generated.dart](https://github.com/zanminwang/ahead/blob/main/examples/rust-round-trip/generated/generated.dart) | Generated Dart client and model types |
| [server.mts](https://github.com/zanminwang/ahead/blob/main/examples/rust-round-trip/server.mts) | Business handler, loader and example database setup |
| [client.mts](https://github.com/zanminwang/ahead/blob/main/examples/rust-round-trip/client.mts) | Local queries, mutation call, channel subscription and connection controls |

Next, [define your own schema](schema/define.md), browse the [API reference](api-index.md), or use the [client setup guide](frontend/setup.md).

## Verify the round trip

With Dart installed, `bash integration/e2e/run.sh` runs both languages against a temporary backend. It verifies retry after a lost response, normalization, business rejection, offline reopen, local writes during a delayed response and connection controls.
