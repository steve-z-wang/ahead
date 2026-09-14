# Relations

References, inverse relations and deletion rules.

Current code: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (relation and inverse passes after parsing); descriptor validation in [core/schema.rs](../../../../crates/core/src/schema.rs) (`RelationDescriptor`); runtime use in [client/mutate.rs](../../../../crates/client/src/mutate.rs) (`descendants`), [client/policies.rs](../../../../crates/client/src/policies.rs) (`reference`) and [client/query.rs](../../../../crates/client/src/query.rs) (`related`, `referencing`).

## 1. Introduction and Goals

- Let a model point at another by its identity, expose the reverse navigation, and declare whether deleting the target deletes the referencing rows on the client.

## 3. Context and Scope

- Input: a field whose type is a model name. With `@reference(via: [localFields], onTargetDelete: delete|none)` it is a reference; without it, it is an inverse of some reference and may name the relation with `@inverse(RelationName)`.
- Output: `relations: [{name, target, fields, targetFields, onDelete}]` on the referencing model; `inverses: [{model, name, target, list, nullable, relationName, reference, fields}]` at the top level of the compiler output, consumed only by [Compiler / Generate](../compiler/generate.md).
- Consumers: client cascade and dependency derivation; generated `related` and `referencing` accessors; mutation slot bindings ([Mutations](mutations.md)).

## 5. Building Block View

- Reference validation: singular only (`reference must be singular`); arguments limited to positional name, `via` and `onTargetDelete`; `via` arity equals the target identity arity; each local field must exist, be non-list and have the same source type as the corresponding target identity field; `onTargetDelete` defaults to `none`.
- Inverse resolution: candidates are the target's reference fields typed as this model, filtered by `@inverse` name when given; exactly one must remain (`use a shared relation name`). A singular inverse (`Child?`) requires the reference fields to be the referencing model's identity or one of its `@@unique` sets.
- Core re-validates descriptors: relation names unique per model, `targetFields` equal the target identity, `onDelete` is `delete` or `none`, field types match.
- Client cascade: `descendants` walks every relation with `onDelete == "delete"` whose target is the deleted record, over both the main and before tables, with a `seen` set for cycles; results become `effects` on a queued delete, are deleted directly on a direct delete, and are deleted when an authoritative delete arrives ([Local operations](../client/engine/local-operations.md), [Client Pull](../client/engine/pull.md)).
- Dependency derivation: a queued create of a record referenced by a new operation becomes a lifecycle dependency ([Client Push](../client/engine/push/README.md)).
- Navigation: `related` follows a reference from a loaded row (null when a reference field is null); `referencing` filters the source model by the reference fields.

## 10. Quality Requirements

- Reference metadata compiles: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `relationships_bindings_and_dependency_metadata`; singular inverses need a unique key: `singular_inverse_requires_a_unique_foreign_key`.
- Cascades (L5): [sqlite/tests/client.rs](../../../../crates/sqlite/tests/client.rs) `schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations`, `direct_cascade_handles_cyclic_relationships_once`; [sqlite/tests/downlink.rs](../../../../crates/sqlite/tests/downlink.rs) `delete_cascades_to_descendants_and_their_claims`.
- Navigation: [sqlite/tests/query.rs](../../../../crates/sqlite/tests/query.rs) `query_normalizes_filters_orders_nulls_and_resolves_relationships`.

## 11. Risks and Technical Debt

- **Unresolved question: `onTargetDelete` is a client-side rule only.** The server crate has no relation handling; cascading on the server is the handler's job, and cascaded local deletes are never sent (`effects` are not wire operations). The docs do not say whether a schema author should expect symmetric server behavior. Evidence: [server/lib.rs](../../../../crates/server/src/lib.rs) never reads `relations`; [crates/sim/tests/local.rs](../../../../crates/sim/tests/local.rs) `l5_delete_cascades_locally_and_on_the_server` relies on the simulation host's own cascade.
- **Confirmed limitation: inverses are generation-only.** `inverses` are not part of the runtime schema descriptor, so the Rust client cannot answer an inverse by name; generated code translates each inverse into a `referencing` call with the reference name. Evidence: [compiler/emit.rs](../../../../crates/compiler/src/emit.rs) `ts_models`, `dart_models`.
