# Validate

## 1. Introduction and Goals

Validate refuses schemas the runtimes could not execute consistently and schema changes that would break queued mutations or published records.

## 3. Context and Scope

- Input: parsed declarations; when present, the previous `mutation-history.json` and the previous `schema.json` (the fence).
- Output: validated descriptors for [Generate](generate.md) and the reconciled history.

## 5. Building Block View

Checks run in this order:

1. **Structure.** Relations and inverses ([Relations](../schema/relations.md)), requirements ([Prerequisites](../schema/prerequisites.md)), field types ([Types](../schema/types.md)), slot bindings and default patch fields, inverse uniqueness, `@@sequence` paths ([Mutations](../schema/mutations.md)).
2. **Descriptor.** `Schema::from_value` applies the same rules the runtimes apply at load time, so a schema the compiler accepts is one both runtimes accept.
3. **Mutations.** Unique names, at least one slot, unique slots, existing models, valid patch fields.
4. **History.** Version and compatibility rules per mutation ([Mutations](../schema/mutations.md)); this checks mutation-history compatibility at compile time.
5. **Fence.** Every previously published model and field name must still exist.

CLI policy: initializing a history refuses to overwrite one and requires every mutation at version 1; a named history file that is missing is an error unless initializing.

Code: passes in `compile` in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs); `reconcile_history` and `check_fence` in [compiler/history.rs](../../../../crates/compiler/src/history.rs).

## 10. Quality Requirements

- Invalid identities, unknown prerequisites, duplicate versions and non-unique singular inverses are refused. Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`, `rejects_dependency_typos`, `singular_inverse_requires_a_unique_foreign_key`.
- Incompatible input changes require a version bump; a fence violation fails without touching existing output. Evidence: [compiler/tests/history.rs](../../../../crates/compiler/tests/history.rs); [compiler/tests/cli.rs](../../../../crates/compiler/tests/cli.rs) `cli_retains_history_and_does_not_overwrite_on_break`.

## 11. Risks and Technical Debt

- **Problem: semantic errors report the end of input.** Every check after parsing formats the position of the current token, which by then is end-of-file, so relation, binding, sequence and descriptor errors point at the last line of the last file. The only positional test covers a syntax error. Evidence: `Parser::err` in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs).
- **Accepted limitation:** the fence checks names only; a type or identity change passes the compiler and is refused by the client at open ([Reconciliation](../client/storage/reconciliation.md)). The source comment records this as deferred.
- **To confirm:** determinism (identical bytes for identical input) is assumed from source order and sorted maps but not asserted.
