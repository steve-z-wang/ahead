# Validate

Check types, references and mutations in the parsed definitions.

Current code: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (passes after the declaration loop in `compile`, then `ahead_core::Schema::from_value`); history and fence in [compiler/history.rs](../../../../crates/compiler/src/history.rs) (`reconcile_history`, `check_fence`).

## 1. Introduction and Goals

- Refuse schemas the runtimes could not execute consistently, and refuse schema changes that would break queued mutations or published records.

## 3. Context and Scope

- Input: the parsed JSON declarations, the previous `mutation-history.json` and the previous `schema.json` (fence) when present.
- Output: validated descriptors for [Generate](generate.md); the reconciled history.
- Errors: positioned strings from the parser's `err`, core `Error::Invalid` messages wrapped by `p.err`, and plain history/fence messages.

## 5. Building Block View

- Structural passes in `compile`, in order: relation and inverse resolution ([Relations](../schema/relations.md)); requirement collection ([Prerequisites](../schema/prerequisites.md)); type resolution ([Types](../schema/types.md)); binding resolution and default `allowedPatchFields` ([Mutations](../schema/mutations.md)); inverse uniqueness; prerequisite declarations and `@requires` arguments; `@@sequence` paths.
- Descriptor validation: `Schema::from_value` re-checks everything the runtimes check at load time (non-empty models, unique names, identity rules, list rules, unique sets, relation arity and types, requirement arguments), so a schema the compiler accepts is one both runtimes accept.
- Mutation-level checks after core validation: unique mutation names, at least one slot, unique slot names, existing models, valid `allowedPatchFields`; unique constraint fields exist.
- History (`reconcile_history`): see [Mutations](../schema/mutations.md); it is the compile-time fence for guarantee C3 and the source of `backendMutations`.
- Fence (`check_fence`): every previously published model and field name must still exist. The source comment states stronger type/identity fences are deferred.
- CLI policy: `--initialize-mutation-history` refuses to overwrite an existing history and requires every mutation at version 1; an explicit `--mutation-history` path that is missing is an error unless initializing.

## 10. Quality Requirements

- [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`, `rejects_dependency_typos`, `singular_inverse_requires_a_unique_foreign_key`; [compiler/tests/history.rs](../../../../crates/compiler/tests/history.rs); [compiler/tests/cli.rs](../../../../crates/compiler/tests/cli.rs) `cli_retains_history_and_does_not_overwrite_on_break` (fence failure leaves `schema.json` untouched).

## 11. Risks and Technical Debt

- **Confirmed limitation: semantic errors report the end of input.** Every pass after the declaration loop calls `p.err`, which formats the position of the current token; by then the parser sits at `<eof>`, so relation, binding, sequence and core-validation errors point at the last line of the last file. Guarantee S1's "locates errors" holds for syntax errors only; the only positional test is a syntax error. Evidence: [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) `Parser::err`; [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_unknown_with_location`.
- **Confirmed limitation: the fence checks names only.** A field's type or a model's identity can change without tripping `check_fence`; the client refuses such a database at open instead ([Client / Storage](../client/storage.md)). Evidence: the comment above `check_fence`. Related: [#20](https://github.com/zanminwang/ahead/issues/20).
- **Confirmed limitation: determinism is assumed, not asserted.** Output ordering follows source order and `serde_json`'s sorted maps, but no test compiles twice and compares bytes (guarantee S1 note).
