# Architecture

See the [component documentation index](architecture/README.md) for individual design documents.

## Components

- **[Schema](architecture/schema/README.md)** — User-written, language-independent definitions of models, fields, types, identities and mutations.
  - **[Types](architecture/schema/types.md)** — Scalar and enum types, lists and nullability.
  - **[Models](architecture/schema/models.md)** — Fields, identities, unique constraints and read-contract versions.
  - **[Relations](architecture/schema/relations.md)** — References, inverse relations and deletion rules.
  - **[Mutations](architecture/schema/mutations.md)** — Operation groups, argument bindings, versions and sequencing.
  - **[Prerequisites](architecture/schema/prerequisites.md)** — Prerequisite declarations and references.
- **[Protocol](architecture/protocol/README.md)** — Language-independent push, pull, receipt, checkpoint and subscription message formats.
  - **[Common](architecture/protocol/common.md)** — Shared fields, counters and encoding conventions.
  - **[Push](architecture/protocol/push.md)** — Mutation batches, receipts, rejections and checkpoints.
  - **[Pull](architecture/protocol/pull.md)** — Requests, record changes, cursors and pagination.
  - **[Subscriptions](architecture/protocol/subscriptions.md)** — WebSocket subscription requests and acknowledgments.
- **[Compiler (Rust)](architecture/compiler/README.md)** — Compile schemas and generate typed interfaces.
  - **[Parse](architecture/compiler/parse.md)** — Convert schema text into structured definitions.
  - **[Validate](architecture/compiler/validate.md)** — Check types, references and mutations in the parsed definitions.
  - **[Generate](architecture/compiler/generate.md)** — Produce runtime descriptors and typed SDK interfaces from validated definitions.
- **[SDKs (TypeScript, Dart, etc.)](architecture/sdks/README.md)** — Convert typed calls to Rust interfaces and results back.
  - **[Typed API](architecture/sdks/typed-api/README.md)** — Expose strongly typed APIs to applications.
    - **[Client](architecture/sdks/typed-api/client.md)** — Generic client runtime plus generated models, mutations and transactions.
    - **[Server](architecture/sdks/typed-api/server.md)** — Backend runtime with generated handler and loader signatures.
  - **[Bindings](architecture/sdks/bindings.md)** — Bridge calls, arguments, results, errors and events between the language and Rust.
- **[Client runtime (Rust)](architecture/client/README.md)** — Local state, storage and sync.
  - **[Frontend interface](architecture/client/frontend-interface.md)** — Expose reads, writes, subscriptions and status to SDKs.
  - **[Engine](architecture/client/engine/README.md)** — Local reads and writes, mutations, cursors, rollback and settlement.
    - **[Local operations](architecture/client/engine/local-operations/README.md)** — Local reads, writes and transactions.
      - **[Writes](architecture/client/engine/local-operations/writes.md)** — Apply mutations and direct writes optimistically over a before image.
      - **[Queries](architecture/client/engine/local-operations/queries.md)** — Read by identity, filter, order, relation and read-only SQL.
    - **[Push](architecture/client/engine/push/README.md)** — Queue mutations, track dependencies and freeze batches.
      - **[Queue](architecture/client/engine/push/queue.md)** — Persist mutations, operations and their ordering.
      - **[Dependencies](architecture/client/engine/push/dependencies.md)** — Decide which mutations are eligible to send.
      - **[Batching](architecture/client/engine/push/batching.md)** — Freeze eligible mutations and preserve their bytes for retries.
    - **[Pull](architecture/client/engine/pull.md)** — Apply server changes and advance cursors.
    - **[Settlement](architecture/client/engine/settlement.md)** — Process decoded receipts and cursors to confirm mutations, roll back rejections and replay pending changes.
  - **[Storage](architecture/client/storage/README.md)** — Execute Engine-requested SQL and transactions; no sync policy.
    - **[Store](architecture/client/storage/store.md)** — The SQL contract and its SQLite implementation.
    - **[Reconciliation](architecture/client/storage/reconciliation.md)** — Table layout and how an existing database meets a newer schema.
  - **[Connection](architecture/client/connection/README.md)** — HTTP/WebSocket, catch-up and reconnect.
    - **[Transport](architecture/client/connection/transport.md)** — Send and receive HTTP/WebSocket messages.
    - **[Controller](architecture/client/connection/controller/README.md)** — Decide when to push, stream, catch up and retry; coordinate subscriptions, cancellation, reconnect and authentication refresh.
      - **[Scheduling](architecture/client/connection/controller/scheduling.md)** — Per-lane state machine for cycles, retries, pause, resume and close.
      - **[Push lane](architecture/client/connection/controller/push-lane.md)** — Freeze, send, acknowledge, repeat.
      - **[Live session](architecture/client/connection/controller/live-session.md)** — Subscribe, catch up over HTTP, stream pages, recover from gaps and subscription changes.
- **[Server runtime (Rust)](architecture/server/README.md)** — Sync protocol and backend execution.
  - **[Backend interface](architecture/server/backend-interface.md)** — Invoke application handlers and loaders.
  - **[Engine](architecture/server/engine/README.md)** — Process mutations, pulls, receipts and checkpoints.
    - **[Push](architecture/server/engine/push.md)** — Validate and deduplicate mutation batches, invoke handlers and produce receipts.
    - **[Pull](architecture/server/engine/pull.md)** — Find changes by channel cursor and invoke loaders to return records.
    - **[Notify](architecture/server/engine/notify.md)** — Record changed records and channels, and update cursors and stamps.
  - **[Persistence](architecture/server/persistence.md)** — Persist sync metadata within the application's transaction; no business logic.
  - **[Connection](architecture/server/connection/README.md)** — HTTP/WebSocket, subscriptions and streaming.
    - **[Transport](architecture/server/connection/transport.md)** — Send and receive HTTP/WebSocket messages.
    - **[Controller](architecture/server/connection/controller.md)** — Manage WebSocket subscriptions and stream pages as commits arrive.

## Component graph

Target architecture. Both connection controllers are Rust: the client's live session (`LiveSession`) and the server's subscription controller (`Subscriptions`); the language packages execute their actions and keep no sync decision.

Solid lines show composition; dashed lines are labeled with contract use or data flow.

```mermaid
flowchart LR
    A["Ahead"]

    A --> C["Compiler · Rust"]
    C --> CP["Parse"]
    C --> CV["Validate"]
    C --> CG["Generate"]

    A --> SDK["SDKs"]
    SDK --> API["Typed API"]
    API --> APIC["Client"]
    API --> APIS["Server"]
    SDK --> B["Bindings"]

    A --> CL["Client runtime · Rust"]
    CL --> CF["Frontend interface"]
    CL --> CE["Engine"]
    CE --> CEL["Local operations"]
    CEL --> CELW["Writes"]
    CEL --> CELQ["Queries"]
    CE --> CEP["Push"]
    CEP --> CEPQ["Queue"]
    CEP --> CEPD["Dependencies"]
    CEP --> CEPB["Batching"]
    CE --> CER["Pull"]
    CE --> CES["Settlement"]
    CL --> CS["Storage"]
    CS --> CSS["Store"]
    CS --> CSR["Reconciliation"]
    CL --> CC["Connection"]
    CC --> CCT["Transport"]
    CC --> CCC["Controller"]
    CCC --> CCCS["Scheduling"]
    CCC --> CCCP["Push lane"]
    CCC --> CCCL["Live session"]

    A --> SR["Server runtime · Rust"]
    SR --> SB["Backend interface"]
    SR --> SE["Engine"]
    SE --> SEP["Push"]
    SE --> SER["Pull"]
    SE --> SEN["Notify"]
    SR --> SP["Persistence"]
    SR --> SC["Connection"]
    SC --> SCT["Transport"]
    SC --> SCC["Controller"]

    SCH["Schema"]
    PRO["Protocol"]

    CP -. reads .-> SCH
    CP -. parsed definitions .-> CV
    CV -. validated definitions .-> CG
    CG -. generates typed interfaces .-> APIC
    CG -. generates typed interfaces .-> APIS

    CCC -. uses .-> PRO
    SCC -. uses .-> PRO

    classDef contract fill:#edf4ff,stroke:#6485b5,color:#243247;
    class SCH,PRO contract;
```

## Code map

Current code locations for the components above. Some responsibilities still share files. Each leaf document records known risks and implementation gaps in its section 11.

| Component | Code location |
|---|---|
| Schema | Source syntax in [compiler/parse.rs](../../crates/compiler/src/parse.rs) |
| Protocol | [core/protocol.rs](../../crates/core/src/protocol.rs), including the shared `limits` and the subscription messages |
| Compiler / Parse | [compiler/parse.rs](../../crates/compiler/src/parse.rs); file concatenation and error relocation in [compiler/main.rs](../../crates/compiler/src/main.rs) |
| Compiler / Validate | `validate` and the `Validated` types in [compiler/validate.rs](../../crates/compiler/src/validate.rs); version history and fence in [compiler/history.rs](../../crates/compiler/src/history.rs) |
| Compiler / Generate | Descriptors in [compiler/generate.rs](../../crates/compiler/src/generate.rs), represented by [core/schema.rs](../../crates/core/src/schema.rs); typed interfaces in [compiler/emit.rs](../../crates/compiler/src/emit.rs); output files in [compiler/main.rs](../../crates/compiler/src/main.rs) |
| SDKs / Typed API / Client | [client-js](../../packages/client-js), [dart](../../packages/dart/lib); model-specific classes are compiler output |
| SDKs / Typed API / Server | [server/index.mts](../../packages/server/index.mts); typed signatures are compiler output |
| SDKs / Bindings | [bindings/common](../../bindings/common), [bindings/node](../../bindings/node), [bindings/dart](../../bindings/dart) |
| Client / Frontend interface | [client/lib.rs](../../crates/client/src/lib.rs); per-transaction handle in [client/engine.rs](../../crates/client/src/engine.rs) |
| Client / Engine / Local operations / Writes | [client/mutate.rs](../../crates/client/src/mutate.rs), [client/rows.rs](../../crates/client/src/rows.rs) |
| Client / Engine / Local operations / Queries | [client/query.rs](../../crates/client/src/query.rs) |
| Client / Engine / Push / Queue | [client/queue.rs](../../crates/client/src/queue.rs), [client/ddl.rs](../../crates/client/src/ddl.rs) |
| Client / Engine / Push / Dependencies | [client/policies.rs](../../crates/client/src/policies.rs), [client/queue.rs](../../crates/client/src/queue.rs); eligibility checks in [client/push.rs](../../crates/client/src/push.rs) |
| Client / Engine / Push / Batching | [client/push.rs](../../crates/client/src/push.rs); push assignment in [client/queue.rs](../../crates/client/src/queue.rs) |
| Client / Engine / Pull | [client/downlink.rs](../../crates/client/src/downlink.rs), [client/ledger.rs](../../crates/client/src/ledger.rs); incoming-page dispositions in [client/transport.rs](../../crates/client/src/transport.rs) (`receive_downlink`) |
| Client / Engine / Settlement | [client/push.rs](../../crates/client/src/push.rs) (`settle_push`, `remove_rejected`); replay in [client/mutate.rs](../../crates/client/src/mutate.rs) (`rebuild`) |
| Client / Storage / Store | [client/store.rs](../../crates/client/src/store.rs), [sqlite/lib.rs](../../crates/sqlite/src/lib.rs) |
| Client / Storage / Reconciliation | [client/ddl.rs](../../crates/client/src/ddl.rs) |
| Client / Connection / Transport | [client-js/transport.mts](../../packages/client-js/transport.mts), [client-js/live.mts](../../packages/client-js/live.mts), [dart/live.dart](../../packages/dart/lib/src/live.dart) |
| Client / Connection / Controller / Scheduling | [client/connection.rs](../../crates/client/src/connection.rs); host loops in [client-js/connection.mts](../../packages/client-js/connection.mts) and [dart/connection.dart](../../packages/dart/lib/src/connection.dart) |
| Client / Connection / Controller / Push lane | [client/transport.rs](../../crates/client/src/transport.rs) (`SyncCycle`); loops in [client-js/runtime.mts](../../packages/client-js/runtime.mts) and [dart/client.dart](../../packages/dart/lib/src/client.dart) |
| Client / Connection / Controller / Live session | [client/live.rs](../../crates/client/src/live.rs) (`LiveSession`); dispositions in [client/transport.rs](../../crates/client/src/transport.rs); executors `startLiveLane` in [client-js/connection.mts](../../packages/client-js/connection.mts) and `LiveLane` in [dart/connection.dart](../../packages/dart/lib/src/connection.dart) |
| Server / Backend interface | Operation contract in [server/host.rs](../../crates/server/src/host.rs) and [server/host-contract.mts](../../packages/server/host-contract.mts); `Host` in [server/lib.rs](../../crates/server/src/lib.rs); handler/loader dispatch in [server/index.mts](../../packages/server/index.mts) |
| Server / Engine / Push | [server/lib.rs](../../crates/server/src/lib.rs) (`process_push`) |
| Server / Engine / Pull | [server/lib.rs](../../crates/server/src/lib.rs) (`process_pull`) |
| Server / Engine / Notify | [server/lib.rs](../../crates/server/src/lib.rs) (`publish`) |
| Server / Persistence | Interface in [server/index.mts](../../packages/server/index.mts); adapter in [persistence-prisma](../../packages/persistence-prisma); tables in [migration.sql](../../packages/persistence-prisma/migration.sql) |
| Server / Connection / Transport | [server/index.mts](../../packages/server/index.mts) |
| Server / Connection / Controller | [server/live.rs](../../crates/server/src/live.rs) (`Subscriptions`); executor `serveLive` in [server/index.mts](../../packages/server/index.mts) |
