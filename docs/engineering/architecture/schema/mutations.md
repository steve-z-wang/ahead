# Mutations

Operation groups, argument bindings, versions and sequencing.

Current code: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (`"mutation" =>` arm and the binding, patch-field and sequence passes); version history in [compiler/history.rs](../../../../crates/compiler/src/history.rs); server decoding in [server/lib.rs](../../../../crates/server/src/lib.rs) (`Config`, `decode`); client policies in [client/policies.rs](../../../../crates/client/src/policies.rs).

## 1. Introduction and Goals

- Name every server-visible write, fix the shape of its operations so both runtimes decode it the same way, and version it so old queued mutations keep executing after the schema moves on.

## 3. Context and Scope

- Input: `mutation Name { slot Model.op<fields>(relation: parentSlot)[] … @@version(n) @@sequence(after: [Other(targetSlot: slot.path)]) }`.
- Output: `mutations: [{name, version, slots, sequence}]`; each slot is `{name, model, operation, cardinality, allowedPatchFields?, bindings?}`. The same list is copied into `schema.clientPolicies` for the client; the CLI replaces both with every retained version ([Compiler / Generate](../compiler/generate.md)).
- Wire form of an instance: `{name, version, operations:[{model, op, identity, values?}]}` ([Protocol / Push](../protocol/push.md)).
- Consumers: generated mutation builders and `Handlers` interfaces; the server decodes operations into slot arguments; the client derives sequence dependencies.

## 5. Building Block View

- Slots: `op` is `create`, `update` or `delete`; `<a,b>` restricts an update's patch fields (only with `update`); an update without `<…>` may patch every non-identity field; cardinality is `single`, `optional` (`?`) or `list` (`[]`).
- Bindings: `(relation: parentSlot)` requires `relation` on the slot model, a parent slot of the relation's target model with `single` cardinality; the compiled binding is `{slot, fields}` with the relation's local fields.
- Version: default `1`, positive, at most 2^53−1, declared once.
- Sequence: `@@sequence(after: [Target(targetSlot: sourceSlot.relation.path)])`; the compiler checks the target mutation and slot exist and that the path, followed through relations from the source slot's model, ends at the target slot's model.
- History ([compiler/history.rs](../../../../crates/compiler/src/history.rs)): `reconcile_history` snapshots each mutation's input models, enums, requirements and sequence per version; a version may not decrease; a retained mutation may not be removed; changing the input at the same version is refused unless compatible (patch fields may grow, enum values may grow, existing fields identical, no new non-nullable field on a model a `create` slot targets, requirements and sequence unchanged).
- Server decoding ([server/lib.rs](../../../../crates/server/src/lib.rs) `decode`): operations are matched to slots in order by `(model, op)`; a `list` slot consumes every consecutive match; identity keeps only identity fields; `create` fills omitted nullable fields with `null`; `update` refuses known fields outside `allowedPatchFields` with `<machine_name>.not_allowed`; leftover or missing operations are `mutation.invalid`; bindings are checked so the child's foreign key equals the parent's identity (`<machine_name>.invalid`).
- Client policies ([client/policies.rs](../../../../crates/client/src/policies.rs)): slots are matched the same way to resolve `sequence` paths against queued mutations of the named predecessor.

## 6. Runtime View

- A schema change that alters a mutation's input requires `@@version(n+1)`; the CLI keeps the previous snapshot so the server keeps a `nameVn` handler and the client keeps a policy for queued instances of the old version.
- A batch naming a known mutation with an unregistered version aborts before any handler runs ([Server Push](../server/engine/push.md), guarantee C4).

## 10. Quality Requirements

- Compile-time checks: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `schema_and_mutations`, `relationships_bindings_and_dependency_metadata`, `rejects_dependency_typos`.
- History: [compiler/tests/history.rs](../../../../crates/compiler/tests/history.rs) `versions_retain_original_inputs`, `nullable_addition_compatible_and_fence_blocks_removal`; CLI retention: [compiler/tests/cli.rs](../../../../crates/compiler/tests/cli.rs) `cli_retains_history_and_does_not_overwrite_on_break`.
- Server decoding: [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs) `ordered_slot_decodes_known_fields_and_ignores_new_fields`, `known_disallowed_patch_is_explicit_refusal`, `create_binding_mismatch_refuses_the_whole_act`, `historical_known_field_outside_capability_is_refused`.

## 11. Risks and Technical Debt

- **Potential risk: adjacent slots with the same model and operation decode greedily.** Matching is positional by `(model, op)`; a `list` slot consumes every following matching operation, so in `RemoveEntries { entries Entry.delete[] maybe Entry.delete? }` the `maybe` slot can never receive an operation. The compiler does not warn. Evidence: [server/lib.rs](../../../../crates/server/src/lib.rs) `decode` loop; [client/policies.rs](../../../../crates/client/src/policies.rs) `slots`; the shape is in [fixtures/compiler/example.model](../../../../fixtures/compiler/example.model). Whether to refuse or reorder such declarations needs deciding.
- **Confirmed limitation: `Model.update<>` compiles but can never succeed.** An update slot with no patch fields produces a `Pick<Patch, never>` input and an empty patch, which the server refuses as `mutation.invalid` (`data.is_empty()`). Evidence: [server/lib.rs](../../../../crates/server/src/lib.rs) `decode`; [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) compiles `Parent.update<>`.
- **Confirmed limitation: version pinning covers input shape only.** History compares slots, inputs, requirements and sequence; handler semantics are the application's responsibility, and the fence (`check_fence`) protects only model and field names ([Compiler / Validate](../compiler/validate.md)).
- Server-side rejection codes are machine strings derived from the mutation name; there is no registry of codes a client can rely on beyond `mutation.invalid`, `<name>.not_allowed`, `<name>.invalid` and the client-side `dependency.rejected` and `dropped` ([Protocol / Push](../protocol/push.md)).
