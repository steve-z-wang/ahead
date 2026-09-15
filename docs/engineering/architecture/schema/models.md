# Models

## 1. Introduction and Goals

A model declares the records an application stores: the stored fields, the identity that names a record on every runtime, and the unique constraints the local database enforces.

## 3. Context and Scope

- Source: `model Name { field Type[]? … @@id(a, b) @@unique(x, y) }`.
- Descriptor: `{name, identity, fields, relations, unique}`. Fields typed as another model are not stored fields; they become [Relations](relations.md).
- Consumers: [Client / Storage](../client/storage/README.md) creates one table per model plus a before-image twin; [Compiler / Generate](../compiler/generate.md) emits the `Name`, `NameIdentity` and `NamePatch` types; the server keys loaders by model name ([Backend interface](../server/backend-interface.md)).

## 5. Building Block View

- **Fields.** `name Type[]?` with at most one each of the directives `@reference`, `@inverse` and `@requires`. Names are ASCII identifiers and unique within the model.
- **Identity.** Exactly one `@@id(...)` naming non-nullable scalar fields. Its order is the primary-key order. A model without `@@id` is invalid.
- **Unique constraints.** Any number of `@@unique(fields)` over existing, distinct fields. The client creates a unique index per constraint; the server never sees them.
- **Names.** Models and enums share one namespace. Model names starting with `ahead_` (framework tables) or `sqlite_` (SQLite's own reserved prefix) are refused; the comparison ignores case because SQLite table names do.
- **Record key.** The identity object with exactly the identity fields, normalized; its canonical encoding is the record's key in every table and message ([Protocol / Common](../protocol/common.md)).
- **State and patch shapes.** Received states must carry every non-identity field or a nullable default; patches may name only known non-identity fields; identity is immutable ([Protocol / Common](../protocol/common.md)).

Code: parsing in [compiler/parse.rs](../../../../crates/compiler/src/parse.rs); name, identity and unique checks in [compiler/validate.rs](../../../../crates/compiler/src/validate.rs); descriptor rules and record keys in [core/schema.rs](../../../../crates/core/src/schema.rs); tables and indexes in [client/ddl.rs](../../../../crates/client/src/ddl.rs).

## 10. Quality Requirements

- An invalid identity (nullable, non-scalar, missing, duplicated) is refused at compile time. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`, `schema_and_mutations`.
- A unique constraint holds atomically within a local transaction: a violating write rolls back only its own savepoint (guarantee L3). Evidence: [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) `declared_unique_constraint_is_atomic`.
- A reserved model name is refused at compile time at its declaration and again at load time; names that merely contain the words stay valid. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_reserved_model_names_at_the_declaration`; [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`.
- Duplicate model or enum names, a missing `@@id` and an identity over a nullable or list field are refused at the declaration. Evidence: `semantic_errors_report_the_offending_declaration`.

## 11. Risks and Technical Debt

- **Problem: no field default in the grammar.** `FieldDescriptor.default` exists and reconciliation uses it, but the compiler cannot emit it. Consequence: every `create` must spell out every non-nullable field, and adding a non-nullable field to a model with local data cannot open ([Reconciliation](../client/storage/reconciliation.md)). Evidence: no default attribute in [compiler/parse.rs](../../../../crates/compiler/src/parse.rs). Tracked in [#27](https://github.com/zanminwang/ahead/issues/27).
- **Accepted limitation:** unique constraints and identities are enforced on the client only; the application's database schema is authoritative on the server.
