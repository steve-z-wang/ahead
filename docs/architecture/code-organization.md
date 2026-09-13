# Code organization and language boundaries

> Historical design record (2026-09-10): status statements and proposed APIs below reflect the original planning stage. See [implementation evidence](../implementation-progress.md) for the current delivered scope and verified limitations.

2026-09-10. Confirmed: Rust implements the frontend/backend framework protocol and state rules; clients expose only language SDKs; the Rust runtime works from a defined schema description and does not depend on generated business types.

Current scope: complete the Rust rewrite while preserving existing logic first; record revisions, new cross-channel behavior and other semantic changes belong in [Next things / TODO](../next-things.md). Naming is confirmed; see [Concepts and naming](concepts-and-naming.md). New names do not change existing wire/storage fields.

This is the recommended layout for this phase. The code directories below are created as their implementations are delivered; there are currently no empty crates or placeholder implementations.

## 1. Recommended directories

```text
otter-sync/
├── crates/
│   ├── otter-core/             Generic schema, value, identity, operation, wire
│   ├── otter-client/           Local state, queue, replay, query, settlement
│   │   └── src/storage/     ClientStore / ClientTransaction interfaces
│   ├── otter-server/           Dispatch, deduplication, publication, loading
│   │   └── src/persistence/ ServerPersistence / TransactionPersistence interfaces
│   ├── otter-sqlite/           Client storage adapter: SQLite / transaction session
│   ├── otter-persistence-sqlx/ Future Rust backend adapter, created when needed
│   └── otter-compiler/         Schema compiler implemented in Rust
│       └── src/
│           ├── syntax/      Schema parsing and syntax diagnostics
│           ├── semantic/    Schema validation and shared intermediate representation
│           └── emit/
│               ├── schema/  Generic description data loaded by the runtime
│               ├── dart/    Dart source generator
│               └── typescript/ TypeScript source generator
├── bindings/
│   ├── node/                Rust ↔ Node; Cargo package otter-node
│   ├── dart/                Rust ↔ Dart; Cargo package otter-dart
│   └── wasm/                Future browser bridge, created when validation needs it
├── packages/
│   ├── dart/                Public Dart client and typed facade support
│   ├── client-js/           Public TypeScript client
│   ├── server/              TypeScript backend facade and business callback interfaces
│   │   └── src/persistence/ Corresponding TS contract for the Rust persistence port
│   └── persistence-prisma/  PrismaPersistence adapter bound to the user's tx
├── fixtures/
│   ├── schemas/             Generic schema descriptions and compatible version samples
│   ├── protocol/            Wire / codec golden vectors
│   └── scenarios/           Interleaved timelines and independent expected results
├── integration/
│   ├── rust/               Rust client ↔ Rust server scenario tests
│   ├── bindings/           Dart/TypeScript interfaces ↔ Rust
│   ├── persistence/        Real database contracts for each adapter
│   ├── generated-api/      Generated-code compilation and runtime tests
│   └── e2e/                A few complete SDK/network/database flows
├── examples/                Standalone applications users can actually run
└── docs/                    Design, protocol, integration, implementation plans
```

`crates/` holds Rust implementations independent of Node/Dart; `bindings/` holds Rust glue that depends on language runtimes; `packages/` holds the language libraries users import.

Do not copy a separate core into each SDK. Tests belonging to a crate/package live beside it; only cross-boundary tests belong in integration. Do not create a large generic utilities package.

## 2. Runtime schema is data, not business Rust types

Rust may define stable generic structures: `Schema`, `ModelDescriptor`, `FieldDescriptor`, `RecordKey`, `Value`, and `Operation`. It should not contain `struct Entry` or `struct Book` generated from the user's schema.

The flow is:

```text
User schema source files
        ↓ compiler
Validated, language-independent schema description
        ├── Loaded at runtime initialization → Rust generic engine
        ├── Dart generator → Entry / EntryQuery / MutationInput
        └── TypeScript generator → Entry / EntryQuery / MutationInput
```

The compiler's stable intermediate output is the schema description; Dart/TypeScript generators use it to produce idiomatic APIs. The description includes fields, identities, relationships, constraints, mutation slots and historical input versions. It can be transferred as serialized bytes or equivalent description values registered by the language SDK; language object layouts must not become the protocol.

When the runtime opens, Rust validates the schema, indexes and compatibility fingerprint, and caches parsed descriptors; it does not reparse JSON for every field operation. Unknown models, invalid patches and type mismatches have defined errors in the generic engine.

Adding a model requires only regenerating language code and schema metadata and applying any necessary storage migration, without recompiling the framework's Rust binary. Changes to supported operation semantics or scalar types may require a Rust runtime upgrade.

## 3. Boundaries each layer must preserve

| Layer | Responsibilities | What must stay out |
|---|---|---|
| otter-core | Validate schema/identity/operation; wire encoding and decoding | SQLite, HTTP, Prisma, business model structs |
| otter-client | State rules, query IR, queue/replay/settlement; define client storage interfaces | Flutter widgets, React hooks, replay of host business callbacks |
| otter-server | Deduplication, publish semantics, downlink and receipts; define backend persistence interfaces | Application domain services, independently created user DB transactions |
| otter-sqlite | ClientStore implementation, native local transactions, commit notifications | Redefining protocol or optimistic rules |
| bindings | Handles, owned values, errors, async calls | Independent scheduler or conflict resolver |
| language client | Typed API, model conversion, Stream/subscription | A second set of queue/reducer/cursor rules |
| server facade | Invoke TS handlers/loaders and return completion results | Independently deciding an ACK can settle |
| server persistence adapter | Adapt the user's tx to TransactionPersistence; perform atomic operations and snapshot reads | Opening a new connection and claiming it is the same transaction; silently weakening atomicity |
| language generator | Language types, builders, descriptor references, forwarding | User business algorithms or copies of Rust state machines |

Dart/JS code still connects its own Streams, subscription lifecycles and platform I/O. Rust decides when to send requests, retry and settle; the host may provide concrete HTTP, credential and media-upload implementations.

## 4. Dependency direction

- `otter-client` and `otter-server` both depend on `otter-core`, not on each other.
- `otter-sqlite` implements the client's storage interface; `otter-client` does not depend back on a concrete SQLite crate.
- Bindings compose core/runtime/store; language packages call through bindings.
- The compiler depends on generic schema definitions; the runtime does not depend on the compiler.
- The backend runtime depends on the ServerPersistence / TransactionPersistence traits, not concrete Prisma or SQLx implementations.
- The Prisma adapter implements the corresponding TypeScript contract and connects to Rust through the Node binding; the Prisma tx stays in TypeScript.
- A native Rust adapter can implement the same backend trait directly; the SQLx adapter does not go through Node.
- Client storage and backend persistence interfaces belong to otter-client and otter-server respectively; do not extract a single combined interface.
- Adapters may reuse generic SQL/driver tools; the framework defines trait concurrency and transaction guarantees, which must not change with the driver.
- Examples may combine all these layers, but framework code does not import examples or Oasis.

## 5. Persistence interfaces and extensible adapters

The framework owns interfaces; adapters own concrete database implementations. Rust expresses contracts with traits; TypeScript can use interfaces with classes. Define stable capabilities and lifecycles before finalizing method signatures.

### Backend: separate reusable adapters from transaction-bound objects

Retain the outer batch transaction and per-mutation savepoints, with a user-provided outer transaction runner. Do not claim to preserve batch rollback if each handler commits independently.

- `ServerPersistence`: the backend persistence integration boundary, exposing transaction binding and consistent reads. The host owns the actual transaction lifecycle.
- `TransactionPersistence`: the operation interface already bound to a real user transaction. It includes receipt claim/read/save, channel counters, invalidations and required savepoint capabilities.
- `PrismaPersistence`: a reusable adapter class. `bind(tx)` creates an object valid only within that transaction; it does not begin, commit or open another connection.
- Future `SqlxPersistence` or other adapters implement the same semantic contract; each adapter explicitly declares its supported databases rather than promising all database operations are equivalent.

The following illustrates usage; concrete imports/types will be determined during interface implementation:

> This section is a historical record of the pre-implementation design sketch; the code block below was updated on 2026-09-12 to the current surface.

```ts
export const handlers: Handlers<Tx> = {
  async edit({ input, tx, notify }) {
    const { identity, patch } = input.entry;
    await tx.entry.update({ where: identity, data: patch });
    notify({ channel: "book:demo", records: [input.entry] });
  },
};
```

This example only shows direct business writes and notification sharing a transaction. When processing Push, a batch wrapper must still deduplicate before business writes and store the receipt in the same transaction. A direct-notify example is not the complete handler protocol.

Rust defines the meaning and workflow of framework records; the adapter implements actual database operations, including atomic increments, locking claims, transactional upserts and snapshot reads. A CRUD wrapper with matching method names is insufficient if it cannot provide these guarantees.

Consistent reads must ensure heads, invalidations and related business reads by loaders come from compatible snapshots. When binding a tx, the adapter should validate/declare its capabilities; it must fail explicitly if required isolation, locks or savepoints are unsupported, without a nontransactional fallback.

`store` must not escape and be used after the transaction ends. All bound operations are awaited; failures propagate to the user transaction to trigger rollback. Completion of publication inside a transaction does not mean the business transaction has committed; the outer completion boundary still controls ACK and live-wake timing. A failed session must prevent further valid accepted completions.

### Client: a separate local storage contract

`ClientStore` is a SQL executor: `begin`/`commit`/`rollback`, savepoints, `execute`, `query` on the writer connection and `query_committed` on a read-only connection. `otter-client` owns the schema of the local database: one table per model named as the model, `otter_before_<Model>` twins that hold server truth while a row has pending edits, and the `otter_` framework tables (`otter_client`, `otter_record`, `otter_claim`, `otter_subscription`, `otter_mutation` and its `_operation`, `_dependency`, `_prerequisite` children, `otter_push_checkpoint`, `otter_rejection`). The engine works row by row inside SQLite transactions; nothing is held in memory between calls. Every write transaction increments `otter_client.generation` with a `WHERE generation = ?` fence so a stale instance fails instead of overwriting.

They do not share a large class with server persistence: the backend participates in user transactions, while the client owns its local database by default; their storage objects and query needs also differ. Future client storage adapters need only implement the client contract.

### Extension and acceptance

Add an implementation package and contract tests for a new adapter, without changing the core state machines. Shared tests must cover at least rollback, concurrent claims of the same batch, atomic channel increments, snapshot consistency and handle invalidation after transaction completion; client adapters additionally verify read-your-writes, savepoints and commit-only notifications.

Native Rust adapters and adapters connected through language bridges must satisfy the same semantics. The bridge also verifies value conversion, async errors and lifecycles; adapter unit tests cannot replace cross-language transaction tests.

## 6. Compiler and language generators

The compiler is implemented in Rust. It reads, parses and validates schema into a shared description, then separate emitters write target files; generation does not require instantiating Dart or TypeScript business classes first.

```text
Schema source files
    ↓ Rust parser / validator
Shared schema description
    ├── Schema emitter → runtime metadata
    ├── Dart emitter → .dart types, conversion functions, typed API
    └── TypeScript emitter → .ts types, conversion functions, typed API
```

For the same Entry description, the Dart emitter may output `class Entry`, while the TypeScript emitter may output `interface Entry` or a class suited to the SDK API. Generators handle each language's syntax, type mapping, naming and escaping; these business types are not generated into the Rust runtime.

Implementations may use templates or source builders; embedding Dart/TypeScript compilers into the Rust compiler is not required. The user's Dart/TypeScript toolchain later analyzes, compiles and runs the generated files. Whether to call a formatter is an independent development-tool choice and does not affect runtime boundaries.

### Generated content

- Business model, identity, mutation input and allowed-field types.
- Conversion functions between generic records/values and business types.
- Typed query/operation builders and methods forwarding to the SDK/Rust.
- Corresponding schema metadata or references, ensuring the typed API and runtime description come from the same schema.

TypeScript interfaces provide static types only, without automatic runtime decoding. Dart classes also require explicit construction; conversion functions handle null, numbers, time, bytes and other mappings. Rust retains generic schema validation; generated code does not duplicate queue, replay or settlement algorithms.

The compiler may reuse otter-core schema data structures and validation rules; the runtime does not depend back on the compiler or any language emitter. Initially, emitters live in separate otter-compiler modules; split them into crates only if independent distribution is needed.

## 7. Testing layers

Three layers are confirmed: Rust core (modules and two-sided state scenarios), boundary contracts (bindings/persistence/generated API), and a few full E2E tests. The table below assigns specific test responsibilities within these layers. Single-module tests and data live beside each crate/package; shared fixed inputs and expected data live in root fixtures; cross-component tests live in integration. Test procedures are written in test code, without introducing a scenario DSL. Test databases use isolated temporary directories/instances; runtime artifacts are not committed.

The main boundaries are within Rust/between its two sides, and between language interfaces and Rust; real persistence and generated-code toolchains each verify their own guarantees.

| Layer | Location | Verification focus |
|---|---|---|
| Rust module tests | Each crate's unit tests and tests/ | Schema, operation, reducer, queue, scheduling and settlement invariants |
| Rust client ↔ Rust server | integration/rust/ | Controlled transport simulates ACK/page reordering, loss, retry, rejection and restart; verify final state |
| Dart/TypeScript interfaces ↔ Rust | integration/bindings/ | Type/value conversion, async errors, transaction callbacks, subscriptions, cancellation and handle lifecycles |
| Persistence adapter ↔ DB | integration/persistence/ | Real SQLite/Postgres rollback, concurrent claims/counters, snapshots, commit boundaries |
| Compiler / generated API | Compiler tests and integration/generated-api/ | Deterministic generation, valid source, type constraints, data conversion and facade forwarding |
| Full E2E | integration/e2e/ | A few complete flows through real SDKs, network, Rust runtime, business callbacks and databases |

### Rust scenario tests

Most protocol scenarios drive Rust client/server directly without starting Dart and Node each time. Transport, clock and failure points are controlled; persistence-recovery scenarios must close and reopen real test storage rather than merely clear memory variables.

Shared client/server code does not replace correctness assertions. Tests must define expected state by hand or use a small independent reference model to check invariants, avoiding mutual validation of the same shared bug. Final visible data, authoritative base, pending queue and cursors all have explicit expectations.

### Binding and adapter tests

Each language repeats only its own boundary checks, not the whole Rust replay suite. Keep a test that loads different schemas with the same binary to confirm business types are not compiled into Rust.

Database tests use resources they create themselves. The backend must prove business writes, publication and receipts roll back in the same real transaction; mocks cannot prove this. Concrete adapters reuse semantic contract tests; cross-language adapters also run a real bridge + transaction integration.

### Generator tests

1. Schema parser/validator tests cover valid definitions and located errors; historical inputs and compatibility rules use fixed fixtures.
2. Golden tests verify deterministic output, field mapping and target syntax; updating snapshots alone does not establish correctness.
3. Run the Dart analyzer on generated Dart code and `tsc --noEmit` on generated TypeScript code.
4. Valid call samples must pass; negative cases for incorrect fields/types and invalid mutation patches must produce expected diagnostics. Organize negative cases separately so unrelated compilation errors do not count as success.
5. Run record↔model conversions and generated API calls, covering absent/null, integers, Unicode, time and collections; verify actual results after calling Rust.

Each language chooses its test runner; Rust need not implement Dart/TypeScript compilers. CI runs those toolchains separately. Reduce the conformance burden caused by duplicated algorithms while retaining external protocol vectors, cross-version compatibility and a few real E2E tests.

## 8. First implementation scope

First establish minimal `otter-core` schema/operation descriptions and tests, while validating the Node transaction bridge and Dart SQLite session. Entry initially exists only as schema data in fixtures, proving the runtime has no compile-time business-type dependency.

A required regression test loads schema A into one instance of the compiled Rust runtime, then schema B containing an additional model into another instance. Both must perform valid queries/writes without recompiling Rust. If schema B requires unsupported runtime capabilities, return an explicit compatibility error.

Next, complete a full single-channel loop. Fill in existing multi-channel behavior, full compiler migration according to the implementation plan. Record revisions and new cross-channel arbitration come later. Do not create every directory and empty package at once in the first version.

## 9. Repository actions in this phase

- New worktree: `/Users/stevewang/Github/local first state/.worktrees/rust-rebuild`.
- New branch: `codex/rust-rebuild`, created from `370e1f1`, which contains the design documents.
- Delete the old runtime, compiler, conformance, examples, CI, build scripts and preparation documents from this branch.
- Retain the new design/audit/plan; rewrite README and ignore configuration.
- The old code remains on main and in existing Git history; the current working directory contains no copy of the old implementation.

## First implementation layout

The executable Rust workspace is now `crates/{otter-core,otter-client,otter-server,otter-sqlite,otter-compiler}` plus `bindings/{common,dart}`; `bindings/node` has its own N-API build manifest. Public host packages are `packages/{client-js,dart,server,persistence-prisma}`. Cross-component tests live in `integration/{rust,bindings,persistence,generated-api,e2e,platform}`, and reusable inputs remain in `fixtures/`. `scripts/test.sh` runs the native host gate; platform simulator tests have separate scripts.

The Rust client contains generic records and schema descriptors. Language generators emit business types, encoding/decoding, typed query options, relation accessors and mutation builders. They do not emit replay, settlement or scheduling algorithms. Host connection classes supply timers/network cancellation; Rust selects actions and retry delays. Backend registration remains available as ordinary functions, and `listen()` serves HTTP and WebSocket on the framework's own port.

The initial SQLite adapter stores changed keyed documents and keeps a full in-memory state snapshot. Read-only SQL evaluates that optimistic snapshot in an isolated SQLite connection. These choices make the first implementation verifiable; dedicated projection tables/indexes and large-cache optimization require performance work before claiming production scale.
