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

## 9. Architecture Decisions

**Model versions — agreed, not implemented ([#91](https://github.com/zanminwang/ahead/issues/91)).** Declare the read contract version on the model with `@@version(n)`, defaulting to 1, independently of mutation versions and record stamps. Compatible changes keep the version; breaking changes retain the old definition and loader alongside the new one. Read compatibility needs its own rules: adding a field or enum value is not automatically safe for an old client. The field-evolution rules below are agreed; other compatibility rules and read-protocol version selection remain to be designed.

**Adding a nullable field — agreed read contract.** Adding an ordinary nullable stored field, without changing identity or constraints, keeps the model version. An older client ignores the unknown extra field while applying the fields it recognizes; a newer client reads a missing nullable field as `null`. For example, adding `description String?` preserves reads of `Task {id, title}`. The local SQLite layout still needs the new column ([Reconciliation](../client/storage/reconciliation.md)). This permits ignoring extra fields, not wrong types in known fields; handling malformed records remains owned by [#51](https://github.com/zanminwang/ahead/issues/51). This decision does not settle mutation-input compatibility or cache refresh after previously ignoring a field.

**Adding a required field — agreed read contract.** A new non-nullable stored field requires a model version bump: older records lack the required value. The new loader supplies valid values; Ahead must not invent a value. Local schema detection and replica rebuilding are framework responsibilities under [#20](https://github.com/zanminwang/ahead/issues/20).

**Adding a returned enum value — agreed read contract.** Expanding an enum used by a model's existing read contract requires a new model version: an older client may recognize the field but cannot interpret the new value. For example, adding `archived` to `open | closed` requires retaining the old record definition and loader. The application implements the old loader's conversion into values allowed by that old contract; the framework does not guess a fallback or forward the new value to old readers. This is an output rule, not a change to mutation-input enum compatibility.

**Renaming, removing or changing a field's type — agreed read contract.** Each is a breaking change and requires a model version bump. While supporting the old version, retain its definition and loader, returning the old field names and types. The application supplies the mapping or conversion; the compiler must not infer a rename or silently coerce values. This rule covers the public record contract, not permission to migrate identities, relations or persisted client data automatically.

Model versions follow the same [deprecation lifecycle](mutations.md#9-architecture-decisions) as mutations. See [Typed API / Server](../sdks/typed-api/server.md#9-architecture-decisions) for loader registration and [Generate](../compiler/generate.md#9-architecture-decisions) for history storage. Contract history does not migrate existing local records; that belongs to [Reconciliation](../client/storage/reconciliation.md) and [#20](https://github.com/zanminwang/ahead/issues/20).

## 10. Quality Requirements

- An invalid identity (nullable, non-scalar, missing, duplicated) is refused at compile time. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`, `schema_and_mutations`.
- A unique constraint holds atomically within a local transaction: a violating write rolls back only its own savepoint (guarantee L3). Evidence: [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) `declared_unique_constraint_is_atomic`.
- A reserved model name is refused at compile time at its declaration and again at load time; names that merely contain the words stay valid. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_reserved_model_names_at_the_declaration`; [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`.
- Duplicate model or enum names, a missing `@@id` and an identity over a nullable or list field are refused at the declaration. Evidence: `semantic_errors_report_the_offending_declaration`.

## 11. Risks and Technical Debt

- **Problem: no field default in the grammar.** `FieldDescriptor.default` exists and reconciliation uses it, but the compiler cannot emit it. Consequence: every `create` must spell out every non-nullable field, and adding a non-nullable field to a model with local data cannot open ([Reconciliation](../client/storage/reconciliation.md)). Evidence: no default attribute in [compiler/parse.rs](../../../../crates/compiler/src/parse.rs). Tracked in [#27](https://github.com/zanminwang/ahead/issues/27).
- **Accepted limitation:** unique constraints and identities are enforced on the client only; the application's database schema is authoritative on the server.
