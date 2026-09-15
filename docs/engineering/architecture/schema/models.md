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
- **Names.** Models and enums share one namespace. `ahead_` is reserved for framework tables.
- **Record key.** The identity object with exactly the identity fields, normalized; its canonical encoding is the record's key in every table and message ([Protocol / Common](../protocol/common.md)).
- **State and patch shapes.** Received states must carry every non-identity field or a nullable default; patches may name only known non-identity fields; identity is immutable ([Protocol / Common](../protocol/common.md)).

Code: parsing in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs); descriptor rules and record keys in [core/schema.rs](../../../../crates/core/src/schema.rs); tables and indexes in [client/ddl.rs](../../../../crates/client/src/ddl.rs).

## 10. Quality Requirements

- An invalid identity (nullable, non-scalar, missing, duplicated) is refused at compile time. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`, `schema_and_mutations`.
- A unique constraint holds atomically within a local transaction: a violating write rolls back only its own savepoint (guarantee L3). Evidence: [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) `declared_unique_constraint_is_atomic`.
- The reserved prefix is refused at load time. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`.

## 11. Risks and Technical Debt

- **Problem: no field default in the grammar.** `FieldDescriptor.default` exists and reconciliation uses it, but the compiler cannot emit it. Consequence: every `create` must spell out every non-nullable field, and adding a non-nullable field to a model with local data cannot open ([Reconciliation](../client/storage/reconciliation.md)). Evidence: no default attribute in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs). Tracked in [#27](https://github.com/zanminwang/ahead/issues/27).
- **Accepted limitation:** unique constraints and identities are enforced on the client only; the application's database schema is authoritative on the server.
- **Potential risk:** only the `ahead_` prefix is refused, so a model named with SQLite's reserved `sqlite_` prefix fails at table creation on open rather than at compile time. Not covered by a test.
