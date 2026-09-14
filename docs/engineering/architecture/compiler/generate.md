# Generate

Produce runtime descriptors and typed SDK interfaces from validated definitions.

Current code: descriptors assembled at the end of `compile` in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) and represented by [core/schema.rs](../../../../crates/core/src/schema.rs); output files and history splicing in [compiler/main.rs](../../../../crates/compiler/src/main.rs); typed interfaces in [compiler/emit.rs](../../../../crates/compiler/src/emit.rs).

## 1. Introduction and Goals

- Emit one runtime descriptor per side and one typed surface per language from the same validated definitions, so the client, server and application code cannot disagree about shapes.

## 3. Context and Scope

- Output files written by the CLI (temp file plus rename each):
  - `schema.json`: the client descriptor (`enums`, `models`, `requirements`, `prerequisites`, `clientPolicies` = every retained mutation version).
  - `backend.json`: server config (`schema`, `mutations` = retained versions with `input` snapshot and `knownFields`, `loaders` = model names, `inverses`, `uniqueConstraints`, `requirements`, `prerequisites`).
  - `generated.ts`: types, codecs, mutation builders, `Model`/`LiveModel`/`TxModel` classes, `Mutate`, `GeneratedTransaction`, the `ReadPort`/`WritePort`/`LivePort` interfaces and an embedded `schema` constant.
  - `backend.ts`: `Handlers<Tx>`, `Loaders<Tx>`, per-mutation `Input` types, `RecordRef` helpers and a `createBackend` wrapper importing `@ahead/server` (or `--backend-runtime`).
  - `client.ts`: `GeneratedClient` over `@ahead/client` (or `--client-runtime`).
  - `generated.dart`: everything above for Dart in one file, importing `package:ahead/ahead.dart`.
  - `mutation-history.json`.
- Consumers: [SDKs / Typed API](../sdks/typed-api.md) (generated code is the typed surface), [Client / Frontend interface](../client/frontend-interface.md) (`schema.json` at open), [Server / Backend interface](../server/backend-interface.md) (`backend.json` config).

## 5. Building Block View

- Source definitions versus runtime descriptors: the `.model` text is the source; `schema.json` and `backend.json` are what the runtimes validate at load time (`Schema::from_value`, `Config::decode`); generated language code embeds the same descriptor verbatim.
- `typescript(v)`: per model `Name`, `NameIdentity`, `NamePatch` (all optional), `decodeName`, `encodeName{,Identity,Patch,Where}`; per mutation `NameArgs` and a builder producing wire operations (identity encoded separately from values); `NameModel` (`get`, `query` with equality `where`, scalar `orderBy`, `limit`, relation and inverse accessors), `NameLiveModel.watch`, `NameTxModel.create/update/delete` (direct writes).
- `backend_typescript(v, runtime)`: handler keys are `lowerFirst(name)` for the latest version and `lowerFirst(name)V<n>` for older ones; loader keys are `lowerFirst(model)`.
- `client_typescript(runtime)`: schema-independent; rejects removed `transport`/`live` options; opens the client then connects when `server` is given.
- `dart(v)`: `Present<T>` wrappers express patch and filter presence; `NameFilter`, `NameOrderField`, `NameOrder`; mutation functions take named parameters; `GeneratedClient.open` needs `libraryPath` outside iOS.
- Type mapping is in [Types](../schema/types.md); `dateTime` values are encoded with `toISOString()` / `toUtc().toIso8601String()` and decoded with `new Date` / `DateTime.parse`.

## 10. Quality Requirements

- Emitter content: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `emitters_include_typed_conversion`, `backend_emitter_declares_handlers_loaders_and_references`, `backend_emitter_suffixes_older_mutation_versions`, `generated_clients_expose_one_server_connection`; [compiler/tests/cli.rs](../../../../crates/compiler/tests/cli.rs) `cli_writes_backend_ts_with_the_requested_runtime_import`.
- Generated code against native Rust (S2, partial): [integration/generated-api/test.ts](../../../../integration/generated-api/test.ts) (TypeScript positives and `@ts-expect-error` negatives), [generated_test.dart](../../../../integration/generated-api/generated_test.dart) (Dart positives only).

## 11. Risks and Technical Debt

- **Confirmed limitation: negative type tests exist for TypeScript only.** Dart misuse (identity in a patch, wrong filter type) is not asserted to fail compilation (guarantee S2 note). Evidence: [generated_test.dart](../../../../integration/generated-api/generated_test.dart).
- **Confirmed debt: generated code carries an accepted-but-ignored `migration` option.** Both `GeneratedClient.open` signatures forward it to a runtime that discards it. Evidence: [compiler/emit.rs](../../../../crates/compiler/src/emit.rs) `client_typescript`, `dart`; [bindings/common/src/lib.rs](../../../../bindings/common/src/lib.rs) comment in `open`. Open: [#20](https://github.com/zanminwang/ahead/issues/20).
- **Potential risk: emitters build code by string formatting without escaping.** Model and field names are identifiers, so injection is impossible today; the Dart `schema` is embedded in a raw triple-quoted string, which would break if a string literal in the schema contained `'''`. Evidence: [compiler/emit.rs](../../../../crates/compiler/src/emit.rs) `dart`. Low likelihood; noted for anyone adding string-valued attributes such as defaults.
- **Confirmed limitation: multi-file output is not atomic.** Each file is renamed into place individually; a failure after the first write leaves a mixed output directory. The fence and history checks run before any write, so the tested failure mode leaves everything untouched. Evidence: [compiler/main.rs](../../../../crates/compiler/src/main.rs).
