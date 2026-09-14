# Models

Fields, identities and unique constraints.

Current code: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (`"model" =>` arm of `compile`); descriptor validation in [core/schema.rs](../../../../crates/core/src/schema.rs) (`ModelDescriptor`, `validate`, `record_key`).

## 1. Introduction and Goals

- Declare the records the application stores: their stored fields, the identity that names a record on every runtime, and unique constraints the local database enforces.

## 3. Context and Scope

- Input: `model Name { field Type … @@id(a, b) @@unique(x, y) }`.
- Output: a `ModelDescriptor` `{name, identity, fields, relations, unique}`; relation-typed fields are split off into `relations` ([Relations](relations.md)) and are not stored fields.
- Consumers: [Client / Storage](../client/storage.md) creates one table per model plus a before-image twin; [Compiler / Generate](../compiler/generate.md) emits `Name`, `NameIdentity`, `NamePatch` types and codecs; the server keys loaders by model name ([Backend interface](../server/backend-interface.md)).

## 5. Building Block View

- Fields: `name Type[]?` with optional field directives `@reference`, `@inverse`, `@requires`; any other directive is `unsupported field directive`; a directive may appear once per field.
- Identity: exactly one `@@id(...)` per model (`duplicate identity` otherwise); the descriptor is invalid without one (`identity.is_empty()` in core). Identity fields must exist, be non-nullable scalars and not repeat. Identity order is the `@@id` argument order and becomes the SQLite primary key order.
- Unique: `@@unique(fields)` may repeat; fields must exist and be non-empty and distinct; each becomes `CREATE UNIQUE INDEX "<Model>_<f1>_<f2>_unique"` on the client ([client/ddl.rs](../../../../crates/client/src/ddl.rs) `model_ddl`).
- Names: model and enum names share one namespace; a model name may not start with `ahead_` (framework table prefix); field names must be unique within a model. Identifiers are ASCII `[A-Za-z_][A-Za-z0-9_]*` ([compiler/lib.rs](../../../../crates/compiler/src/lib.rs) `ident`).
- Record key: `Schema::record_key` accepts an identity object with exactly the identity fields, normalizes each value and produces the canonical `RecordKey` used by every table and wire message ([Protocol / Common](../protocol/common.md)).
- State and patch shapes: `validate_state` (wire), `normalize_state` (loader output) and `validate_patch` (identity immutable, unknown fields refused) live on the descriptor; see [Protocol / Common](../protocol/common.md).

## 10. Quality Requirements

- Invalid identities are refused at compile time: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`; composite identities compile: `schema_and_mutations`.
- Unique constraints are atomic within a local transaction: [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) `declared_unique_constraint_is_atomic` (L3).
- The `ahead_` prefix is refused: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`.

## 11. Risks and Technical Debt

- **Confirmed gap: no field default in the grammar.** `FieldDescriptor.default` exists and [client/ddl.rs](../../../../crates/client/src/ddl.rs) uses it to add a non-nullable column, but the compiler never emits it, so adding a non-nullable field to a model with local data fails to open and every `create` must spell out every field. Evidence: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) has no default attribute; the lexer has no numeric literals outside `@@version`. Open: [#27](https://github.com/zanminwang/ahead/issues/27), related [#20](https://github.com/zanminwang/ahead/issues/20).
- **Confirmed limitation: unique constraints are client-only.** The server never sees `unique`; the application's own database schema decides. Evidence: `unique` is absent from [server/lib.rs](../../../../crates/server/src/lib.rs) `Config`. Whether the documentation should promise anything about server-side uniqueness needs deciding.
- **Potential risk: reserved SQLite names are not refused.** Only the `ahead_` prefix is rejected; a model named with SQLite's reserved `sqlite_` prefix would fail at `CREATE TABLE` on open rather than at compile time. Evidence: [core/schema.rs](../../../../crates/core/src/schema.rs) `validate`. Not covered by a test.
- **Confirmed limitation: identity fields must be scalars.** An enum-typed identity is refused (`invalid identity descriptor`). No rationale recorded.
- Unique-index drift after a schema change is owned by [Client / Storage](../client/storage.md).
