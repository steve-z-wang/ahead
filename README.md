# LocalSync

A schema-driven, offline-first synchronization framework for Dart clients and
TypeScript servers. LocalSync keeps reads in a local SQLite database, records
optimistic writes as durable named mutations, and reconciles them with an
authoritative server over HTTP and WebSocket.

**Status:** experimental standalone source preparation. Package publication is
disabled. A license has not yet been selected; this checkout is not yet a licensed
open-source release. See [release preparation](docs/preparation.md).

## Try it

Install Dart and Node.js with npm on your PATH. Package manifests declare Dart
`^3.10.3`; the imported CI configuration uses Dart 3.10.3 and Node 26.
First-run dependency resolution and SQLite native assets require internet access.

From the repository root:

```bash
./examples/round-trip/run.sh
```

The walkthrough starts an in-memory TypeScript server on loopback, runs a real
Dart client against it, reads the result from SQLite, and checks each result.
It demonstrates multi-scope synchronization, a held optimistic mutation, and
rejection rollback. It requires no cloud account or application credentials.
Read the [walkthrough](examples/round-trip/README.md) for the code and output.

Run the full framework checks:

```bash
./tool/gate.sh
```

## What it provides

- **Schema compiler:** `.model` definitions generate typed Dart models, TypeScript
  server bindings, SQL schema statements, and a model contract.
- **Local reads and writes:** SQLite stores the visible view. A transaction can
  make device-local changes or enqueue named mutations with optimistic state.
- **Durable delivery:** mutation queues, dependency scheduling, retries and frozen
  batches preserve intent across interrupted connections and process restarts.
- **Server authority:** application resolvers accept or refuse named mutations;
  the client reconciles canonical state with pending changes.
- **Scoped synchronization:** applications choose opaque scope strings. Each scope
  has its own durable cursor; HTTP catch-up and live WebSocket delivery use the
  same page application path.

The framework does not supply your production authentication system, server
persistence adapter, model loaders, business rules, or schema migration policy.
The example uses test-only authentication and in-memory server storage.

## Structure

| Directory | Responsibility |
|---|---|
| [compiler](compiler/) | Schema parser, semantic analysis and code generation |
| [client/local_sync](client/local_sync/) | Dart runtime, optimistic state, uplink and downlink |
| [client/local_sync_database](client/local_sync_database/) | Database abstraction |
| [client/local_sync_database_sqlite](client/local_sync_database_sqlite/) | SQLite implementation |
| [server](server/) | TypeScript runtime, host and persistence contracts |
| [conformance](conformance/) | Five executable contracts spanning the layers |
| [examples/round-trip](examples/round-trip/) | Guided executable walkthrough |

There is no dependency on the original application's mobile or backend code.
Internal package dependencies remain relative paths within this repository.

## Generate models

The conformance definitions provide a complete, executable schema to inspect:

```bash
cd compiler
dart pub get
dart run bin/local_sync_compiler.dart \
  --definitions ../conformance/definitions \
  --mutation-history ../conformance/definitions/mutation-contract.json \
  --dart-out ../conformance/lib/src/generated \
  --contract-out ../conformance/generated/model-contract.json \
  --typescript-backend-out ../conformance/generated/backend
```

Consumers own their schema and migration history. Generated declarations describe
models; handwritten runtime code implements transactions and the sync protocol.
To understand a complete integration, start with the
[example reading guide](examples/round-trip/README.md#read-the-code).

## Development

See [contributing](CONTRIBUTING.md) and [test ownership](docs/testing.md).
The first standalone release is a source repository; npm and pub.dev releases,
a production server adapter, and a separate starter application are future work.
