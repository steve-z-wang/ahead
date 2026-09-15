# Prerequisites

## 1. Introduction and Goals

Some mutations must not reach the server until the application has finished other work, such as uploading a file the record refers to. A prerequisite expresses that wait in the schema, so the client holds the mutation back while the optimistic write stays visible, and nothing about uploads leaks into the sync engine.

## 3. Context and Scope

```
prerequisite Uploaded(key String)
model Attachment {
  id  UUID
  key String @requires(Uploaded(key: self))
  @@id(id)
}
```

The descriptor carries `prerequisites: [{name, fields}]` and `requirements: [{model, field, name, arguments}]`. The client derives *tasks* from them when a mutation is enqueued; the SDK exposes `pendingTasks()`, `setReadiness(key, state)` and `runPrerequisites(handlers)`. The server never sees prerequisites.

## 5. Building Block View

A declaration has a unique name and typed fields (`String`, `UUID`, `DateTime`, `Int`, `Float`, `Bool`). A requirement invokes one declaration, supplies every field, and today every argument must be `self`, meaning the value of the annotated field.

A **task key** is what ties them to the queue. When a wire operation carries a non-null value for an annotated field, the client forms the key `{"name": Uploaded, "arguments": {"key": <value>}}` in canonical JSON and stores it against the mutation. Two mutations that need the same upload share one key; marking it ready releases both. A mutation is not frozen while any of its keys is pending or failed ([Dependencies](../client/engine/push/dependencies.md)).

The SDK runner walks the pending tasks, calls `handlers[name](arguments)`, and marks the task ready on success or failed on exception. A failed task is retried only after the application resets it to pending, so a permanent failure does not spin.

Code: compiler checks in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs); key derivation in [client/policies.rs](../../../../crates/client/src/policies.rs); rows in [client/queue.rs](../../../../crates/client/src/queue.rs); the runner in [client-js/index.mts](../../../../packages/client-js/index.mts) and [dart/client.dart](../../../../packages/dart/lib/src/client.dart).

## 10. Quality Requirements

- **A mutation with an unready prerequisite is not frozen, stays optimistic and survives restart, while independent mutations may be sent ahead of it** (guarantee P3). Evidence: [sqlite/tests/push.rs](../../../../crates/sqlite/tests/push.rs) `schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation`, `failed_prerequisite_stays_optimistic_independent_work_can_overtake`.
- **Readiness arriving after the mutation was dropped leaves nothing behind.** Evidence: `late_task_completion_does_not_resurrect_unused_readiness`.
- **The SDK runner marks failure and an explicit reset unlocks the push.** Evidence: [prerequisite.test.mjs](../../../../integration/bindings/client-js/prerequisite.test.mjs). No Dart test drives `runPrerequisites`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation.** `self` is the only argument expression. The compiler message says "currently"; no issue tracks an extension.

**Potential risk.** The Rust API accepts opaque prerequisite keys; a non-JSON key has no `name`, so the SDK runner throws `Missing prerequisite handler` and stops. Affects only Rust callers that also use the SDK runner.
