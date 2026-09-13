# Rust round trip

An embedded Node backend, Prisma/PostgreSQL business database, shared Rust protocol runtime, generated TypeScript/Dart models, and local SQLite clients. Everything needed belongs to this repository; no Oasis checkout is used.

On macOS with Node 22.18+ (verified with 26.4), Rust (pinned by `rust-toolchain.toml`), Python 3 and PostgreSQL command-line tools on PATH:

```sh
bash examples/rust-round-trip/run.sh
```

The script builds the native runtime, generates models, and starts a private disposable PostgreSQL cluster and HTTP server on `127.0.0.1:4242`. It removes only its temporary PostgreSQL cluster on exit. Development authentication is `Bearer demo-user`.

In another terminal, from the repository root:

```sh
node examples/rust-round-trip/client.mts
```

Try `edit   hello   `. The entry prints twice: first the local optimistic text with its whitespace, then the backend's trimmed version once the Pull checkpoint arrives. `edit reject` demonstrates rejection and restoration. Stop the server, edit, and start it again to watch the queued change settle; close and reopen the CLI to observe durable offline changes. Client data stays in `example-client.sqlite`; `OTTER_DATABASE` selects another path.

- `models/entry.model`: the source schema and mutation contract.
- `generated/`: generated schema, mutation history, and language-specific facades.
- `server.mts`: handlers and loaders implementing the generated `Handlers` and `Loaders` interfaces; `createBackend` from `generated/backend.ts`; `listen` serves HTTP and WebSocket on one port.
- `client.mts`: generated TypeScript API over the generic Rust client.
- `integration/e2e/dart_client.dart` (repository root): real Dart client exercising the same backend.

To run both languages automatically, install Dart and run `bash integration/e2e/run.sh` from the root. The test uses its own temporary server/database and verifies lost-response retries, normalization, rejection, restart, and edits while a network response is delayed.
