# Prerequisites

Prerequisite declarations and references.

Current code: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (`prerequisite` declarations and the `requirements` pass); descriptor validation in [core/schema.rs](../../../../crates/core/src/schema.rs) (`RequirementDescriptor`); runtime in [client/policies.rs](../../../../crates/client/src/policies.rs) (`derive`) and [client/queue.rs](../../../../crates/client/src/queue.rs) (prerequisite rows); SDK runner in [client-js/index.mts](../../../../packages/client-js/index.mts) and [dart/client.dart](../../../../packages/dart/lib/src/client.dart) (`runPrerequisites`).

## 1. Introduction and Goals

- Let a mutation wait, on the client, for application work that must finish before the server may see it (an upload, for example), while the optimistic write stays visible.

## 3. Context and Scope

- Input: `prerequisite Name(field Type, …)` at the top level and `@requires(Name(field: self))` on a model field.
- Output: `prerequisites: [{name, fields}]` and `requirements: [{model, field, name, arguments}]` in the schema descriptor.
- Runtime interface: the client derives task keys when a mutation is enqueued; the SDK exposes `pendingTasks()`, `setReadiness(key, state)` and `runPrerequisites(handlers)`; the server never sees prerequisites.

## 5. Building Block View

- Declaration checks: names unique; field names unique; field types limited to `String`, `UUID`, `DateTime`, `Int`, `Float`, `Bool`/`Boolean` (no enums or lists).
- Requirement checks: exactly one invocation per `@requires`; the prerequisite must exist; every declared field must be supplied; every argument must be `self` (`prerequisite argument currently requires self`); the source field's type must equal the declared field type. Core repeats the `self`-only rule.
- Task key derivation ([client/policies.rs](../../../../crates/client/src/policies.rs)): for each wire operation whose `values` contain the required field with a non-null value, the key is the canonical JSON of `{"name": Name, "arguments": {field: value}}`; keys are sorted and deduplicated per mutation and stored in `ahead_mutation_prerequisite (ordinal, key, error)`.
- Gating ([client/push.rs](../../../../crates/client/src/push.rs) `freeze`): a mutation with any key still in the table is skipped, whether pending or failed; independent later mutations may be sent ahead of it.
- Readiness: `Ready` deletes every row with the key; `Failed` records an error string; `Pending` clears it. `pending_tasks` returns one entry per key with `state` `pending` or `failed`; schema-derived keys parse back into `name` and `arguments`.
- SDK runner: `runPrerequisites(handlers)` loops over `pending` tasks, calls `handlers[task.name](task.arguments)`, marks `ready` on success and `failed` on exception; a failed task is retried only after the application sets it back to `pending`.

## 10. Quality Requirements

- Compile-time: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `relationships_bindings_and_dependency_metadata`, `rejects_dependency_typos`.
- Gating and durability (P3, R3): [sqlite/tests/push.rs](../../../../crates/sqlite/tests/push.rs) `schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation`, `failed_prerequisite_stays_optimistic_independent_work_can_overtake`, `late_task_completion_does_not_resurrect_unused_readiness`.
- SDK: [prerequisite.test.mjs](../../../../integration/bindings/client-js/prerequisite.test.mjs) `prerequisite failure stays optimistic and explicit retry unlocks Rust push`. No Dart test exercises `runPrerequisites`.

## 11. Risks and Technical Debt

- **Confirmed limitation: `self` is the only argument expression.** A prerequisite cannot take a constant or another field. Evidence: the compiler error text and [core/schema.rs](../../../../crates/core/src/schema.rs) `unsupported prerequisite argument expression`. The wording "currently" implies a planned extension that is not tracked in an issue.
- **Confirmed limitation: tasks derive from operation values only.** A create that leaves the required field `null`, or an update that does not touch it, creates no task; the rule is not documented for schema authors. Evidence: [client/policies.rs](../../../../crates/client/src/policies.rs) `derive`.
- **Potential risk: opaque keys break the SDK runner.** The Rust API accepts arbitrary `prerequisites` strings; a non-JSON key has no `name`, so `runPrerequisites` throws `Missing prerequisite handler: undefined` and stops the loop. Evidence: [client/lib.rs](../../../../crates/client/src/lib.rs) `pending_tasks`; [client-js/index.mts](../../../../packages/client-js/index.mts) `runPrerequisites`. Affects Rust callers mixing both mechanisms only.
