# Generate

## 1. Introduction and Goals

Generate emits one runtime descriptor per side and one typed surface per language from the same validated definitions, so client, server and application code cannot disagree about shapes.

## 3. Context and Scope

Files written by the CLI, each through a temporary file and rename:

| File | Content | Consumer |
| --- | --- | --- |
| `schema.json` | client descriptor: enums, models, requirements, prerequisites, `clientPolicies` (every retained mutation version) | [Client / Frontend interface](../client/frontend-interface.md) at open |
| `backend.json` | server config: schema, retained mutation versions with input snapshots and `knownFields`, loaders (model names), inverses, unique constraints | [Server / Backend interface](../server/backend-interface.md) |
| `generated.ts` | types, codecs, mutation builders, model classes, ports, embedded schema | [Typed API / Client](../sdks/typed-api/client.md) |
| `backend.ts` | `Handlers<Tx>`, `Loaders<Tx>`, input types, `RecordRef` helpers, `createBackend` wrapper | [Typed API / Server](../sdks/typed-api/server.md) |
| `client.ts` | `GeneratedClient` over `@ahead/client` | [Typed API / Client](../sdks/typed-api/client.md) |
| `generated.dart` | all of the above for Dart in one file | [Typed API / Client](../sdks/typed-api/client.md) |
| `mutation-history.json` | retained inputs per version | [Validate](validate.md) on the next run |

The CLI currently writes `mutation-history.json` in the output directory by default; `--mutation-history FILE` overrides that location. Commit history to Git so subsequent compilation can retain old contracts.

The import specifiers for the runtime packages are configurable (`--backend-runtime`, `--client-runtime`).

## 5. Building Block View

- **Source versus descriptor.** The `.model` text is the source of truth; the JSON descriptors are what the runtimes validate at load time; generated language code embeds the descriptor verbatim.
- **TypeScript.** Per model: `Name`, `NameIdentity`, `NamePatch`, decode and encode functions; `NameModel` with `get`, `query` (equality `where`, scalar `orderBy`, `limit`) and relation accessors; `NameLiveModel.watch`; `NameTxModel` with direct `create`, `update`, `delete`. Per mutation: a typed args interface and a builder that emits wire operations. Handler registration is one key per mutation, `lowerFirst(name)`, holding a `v<n>` member for every retained version; a mutation retaining only v1 also accepts a bare function ([Typed API / Server](../sdks/typed-api/server.md#9-architecture-decisions)). Input type names stay `NameInput` for the latest version and `NameV<n>Input` for older ones.
- **Dart.** The same surface with `Present<T>` wrappers for patch and filter presence, named parameters for mutations, and a `libraryPath` requirement outside iOS.
- **Dates.** Encoded with `toISOString()` / `toUtc().toIso8601String()`, decoded with `new Date` / `DateTime.parse` ([Types](../schema/types.md)).

Code: descriptors assembled at the end of `validate` in [compiler/validate.rs](../../../../crates/compiler/src/validate.rs); emitters in [compiler/emit.rs](../../../../crates/compiler/src/emit.rs); file output in [compiler/main.rs](../../../../crates/compiler/src/main.rs).

## 9. Architecture Decisions

**History storage — agreed target ([#91](https://github.com/zanminwang/ahead/issues/91)).** Keep compiler-maintained history beside the application's schema, separate from disposable generated code, and commit it to Git:

```text
ahead/
├── schema.model
└── history/
    ├── mutations.json
    └── models.json
```

Compilation reads retained definitions, [validates changes](validate.md), and updates history to generate version-specific types and runtime descriptors. Handlers and loaders remain application code. The target layout and model history are not implemented yet.

Generated APIs must carry the [version deprecation notices](../schema/mutations.md#9-architecture-decisions) without dropping historical definitions or changing runtime behavior. This is planned; current generation does not emit those notices.

## 10. Quality Requirements

- Generated TypeScript and Dart compile against valid usage and forward calls unchanged to the runtime. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) emitter tests; [integration/generated-api/test.ts](../../../../integration/generated-api/test.ts); [generated_test.dart](../../../../integration/generated-api/generated_test.dart).
- Misuse is a TypeScript compile error: identity in a patch, disallowed patch field, wrong filter type, enum typo. Evidence: the `@ts-expect-error` block in `test.ts`. Dart negatives are not asserted.
- Retained mutation versions are grouped under the mutation's handler key, with the bare-function shorthand only for a v1-only mutation. Evidence: `backend_emitter_groups_handler_versions_under_the_mutation_name`, `backend_emitter_accepts_a_bare_function_only_for_a_v1_only_mutation`; the `@ts-expect-error` negatives for a bare function and a `v3` key in [test.ts](../../../../integration/generated-api/test.ts). Executed 2026-09-15: `cargo test -p ahead-compiler --locked` (23 passed), `bash integration/generated-api/verify.sh` (passed).

## 11. Risks and Technical Debt

- **Accepted limitation:** generated `open` signatures still accept a `migration` option the runtime ignores; removing or defining it belongs to [#20](https://github.com/zanminwang/ahead/issues/20).
- **Potential risk:** the Dart schema is embedded in a raw triple-quoted string; a schema string literal containing `'''` would break the file. Only relevant once string-valued attributes such as defaults exist.
