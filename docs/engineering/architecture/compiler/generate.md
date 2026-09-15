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

The import specifiers for the runtime packages are configurable (`--backend-runtime`, `--client-runtime`).

## 5. Building Block View

- **Source versus descriptor.** The `.model` text is the source of truth; the JSON descriptors are what the runtimes validate at load time; generated language code embeds the descriptor verbatim.
- **TypeScript.** Per model: `Name`, `NameIdentity`, `NamePatch`, decode and encode functions; `NameModel` with `get`, `query` (equality `where`, scalar `orderBy`, `limit`) and relation accessors; `NameLiveModel.watch`; `NameTxModel` with direct `create`, `update`, `delete`. Per mutation: a typed args interface and a builder that emits wire operations. Handler keys are `lowerFirst(name)` for the latest version and `lowerFirst(name)V<n>` for older ones.
- **Dart.** The same surface with `Present<T>` wrappers for patch and filter presence, named parameters for mutations, and a `libraryPath` requirement outside iOS.
- **Dates.** Encoded with `toISOString()` / `toUtc().toIso8601String()`, decoded with `new Date` / `DateTime.parse` ([Types](../schema/types.md)).

Code: descriptors assembled at the end of `compile` in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs); emitters in [compiler/emit.rs](../../../../crates/compiler/src/emit.rs); file output in [compiler/main.rs](../../../../crates/compiler/src/main.rs).

## 10. Quality Requirements

- Generated TypeScript and Dart compile against valid usage and forward calls unchanged to the runtime (guarantee S2). Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) emitter tests; [integration/generated-api/test.ts](../../../../integration/generated-api/test.ts); [generated_test.dart](../../../../integration/generated-api/generated_test.dart).
- Misuse is a TypeScript compile error: identity in a patch, disallowed patch field, wrong filter type, enum typo. Evidence: the `@ts-expect-error` block in `test.ts`. Dart negatives are not asserted (guarantee S2 note).
- Older mutation versions get suffixed handler keys. Evidence: `backend_emitter_suffixes_older_mutation_versions`.

## 11. Risks and Technical Debt

- **Accepted limitation:** generated `open` signatures still accept a `migration` option the runtime ignores; removing or defining it belongs to [#20](https://github.com/zanminwang/ahead/issues/20).
- **Potential risk:** the Dart schema is embedded in a raw triple-quoted string; a schema string literal containing `'''` would break the file. Only relevant once string-valued attributes such as defaults exist.
