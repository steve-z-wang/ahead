# Server

## 1. Introduction and Goals

A backend author writes handlers (one per mutation) and loaders (one per model) against their own database transaction; the server typed API gives them typed inputs, a `notify` to publish changes, and an HTTP and WebSocket server, while the Rust engine decides what runs and what the client is told.

## 3. Context and Scope

`createBackend({database, authenticate, handlers, loaders, loaderHooks?, translateRejection?, onError?})` returns `{listen, notify, bindTransaction, …}`. Generated `backend.ts` supplies `Handlers<Tx>` and `Loaders<Tx>` so a missing or misnamed handler is a type error, and wraps `createBackend` with the compiled config ([Compiler / Generate](../../compiler/generate.md)). The behavior behind each option is owned by the [backend interface](../../server/backend-interface.md); this page is about the shape an application sees.

| Piece | Shape |
| --- | --- |
| Handler | `({input, tx, userId, notify}) => Promise<void \| {channel}>`; `input` is one typed value per slot |
| Loader | `({ids, tx, userId, channel}) => Promise<(Row \| null)[]>`, aligned with `ids` |
| Rejecting one mutation | throw `MutationRejected(code)`, or throw anything `translateRejection` maps to a code |
| Publishing | `notify({channel, records})` inside a handler; `backend.bindTransaction(tx).notify(...)` outside one |
| Serving | `backend.listen({port, host?})` → `{url, close}` |
| Development auth | `devAuth()` treats the bearer token as the user id; documented as development only |

## 5. Building Block View

The runtime package holds `createBackend`, the HTTP and WebSocket servers and the Prisma-agnostic `Database<T>` contract; the Prisma adapter is a separate package ([Persistence](../../server/persistence.md)). Slot arguments handed to a handler are tagged with a hidden record reference, which is why `notify({records: [input.entry]})` works without spelling out model and identity.

Code: [server/index.mts](../../../../../packages/server/index.mts); generated signatures from `backend_typescript` in [compiler/emit.rs](../../../../../crates/compiler/src/emit.rs).

## 9. Architecture Decisions

**Handler and loader registration by version ([#91](https://github.com/zanminwang/ahead/issues/91)).** Group versions under the mutation or model name. For an initial v1-only contract, a function is shorthand for `{v1: implementation}`. Once multiple versions are supported, register each explicitly:

```ts
handlers: {
  edit: {
    v1: handleOriginalEdit,
    v2: handleNewEdit,
  },
},
loaders: {
  task: {
    v1: loadOriginalTask,
    v2: loadNewTask,
  },
}
```

Handlers receive generated input types for their mutation version; loaders return generated record types for their independent [model version](../../schema/models.md#9-architecture-decisions). Registration keys use `v1`, `v2`; wire versions remain numbers. Shorthand always means v1, never the latest version. Client calls remain `tx.mutate.edit(...)`, with their generated version fixed in the request.

Handler registration implements this decision. Generated `Handlers<Tx>` holds one key per mutation, `lowerFirst(name)`, whose value carries a `v<n>` member for every retained version; a mutation retaining only v1 also accepts the bare function. The runtime refuses at startup: a bare function whenever the retained versions are not exactly v1, a missing version, an unknown `v<n>` key and a non-function value, each naming the mutation and version. Dispatch stays keyed by name and version, so a request never falls back to another version.

Loader registration is still by model name only and has no version dispatch; it waits on [model versions](../../schema/models.md#9-architecture-decisions).

## 10. Quality Requirements

- **Startup fails on an invalid config or a missing handler or loader.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `backend validates config and complete registrations at startup`.
- **Registration names every retained version; a bare function registers v1 only.** Evidence: `handler registration names every retained version and a function means v1 only`.
- **A version reaches only its own handler, whichever way v1 was registered.** Evidence: `a version dispatches only to its own handler and a function registers v1`.
- **Slot arguments can be passed to `notify` directly.** Evidence: `slot arguments are tagged so notify accepts them directly`.
- **Generated handlers group the retained versions of a mutation.** Evidence: [compiler/tests/compiler.rs](../../../../../crates/compiler/tests/compiler.rs) `backend_emitter_groups_handler_versions_under_the_mutation_name`, `backend_emitter_accepts_a_bare_function_only_for_a_v1_only_mutation`.

Executed 2026-09-15: `bash integration/persistence/server/run.sh` (41 passed) and `cargo test -p ahead-compiler --locked` (23 passed).

## 11. Risks and Technical Debt

**Accepted limitation.** The backend runtime exists for TypeScript only; the compiler emits no server signatures for other languages.
