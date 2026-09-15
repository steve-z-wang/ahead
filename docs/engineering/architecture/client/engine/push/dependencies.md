# Dependencies

## 1. Introduction and Goals

- Prevent a mutation from being sent before its required work, while allowing independent mutations to proceed.

## 3. Context and Scope

- Inputs: explicit dependencies, schema relations, mutation sequence policies and prerequisite readiness.
- Metadata is stored in the [Queue](queue.md) and checked by [Batching](batching.md).
- Rejection propagation belongs to [Settlement](../settlement.md).

## 5. Building Block View

- Lifecycle dependencies protect record existence, including references to pending creates.
- Sequence dependencies express the order declared by [mutation policies](../../../schema/mutations.md).
- [Prerequisites](../../../schema/prerequisites.md) wait for application work such as uploads.
- Code: derivation in [policies.rs](../../../../../../crates/client/src/policies.rs), storage in [queue.rs](../../../../../../crates/client/src/queue.rs), eligibility checks in [push.rs](../../../../../../crates/client/src/push.rs).

## 6. Runtime View

- A lifecycle dependent waits for its parent's receipt and cannot share the parent's batch. A rejected parent removes its lifecycle dependents.
- A sequence dependent can share a batch when its predecessor appears earlier in that batch.
- Pending or failed prerequisites block their mutation. Independent later mutations can overtake blocked work.

## 10. Quality Requirements

- Selection must preserve these dependency rules, rather than enforce a global FIFO queue.
- Evidence: [dependency and prerequisite scenarios](../../../../../../crates/sqlite/tests/push.rs). Coverage gaps in the named P3 scenarios are recorded in [guarantees](../../../../guarantees.md).
