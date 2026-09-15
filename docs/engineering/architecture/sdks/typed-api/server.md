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

**Handler and loader registration by version — agreed, not implemented ([#91](https://github.com/zanminwang/ahead/issues/91)).** Group versions under the mutation or model name. For an initial v1-only contract, a function is shorthand for `{v1: implementation}`. Once multiple versions are supported, register each explicitly:

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

The current implementation still uses `edit` for the latest version and `editV1` for an older one. Loaders currently have no version dispatch. The compiler and server registration must change together to implement this decision.

## 10. Quality Requirements

- **Startup fails on an invalid config or a missing handler or loader.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `backend validates config and complete registrations at startup`.
- **Slot arguments can be passed to `notify` directly.** Evidence: `slot arguments are tagged so notify accepts them directly`.
- **Generated handler keys follow mutation versions.** Evidence: [compiler/tests/compiler.rs](../../../../../crates/compiler/tests/compiler.rs) `backend_emitter_suffixes_older_mutation_versions`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation.** The backend runtime exists for TypeScript only; the compiler emits no server signatures for other languages.
