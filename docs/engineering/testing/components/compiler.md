# Compiler tests

Verify that accepted schemas produce the intended descriptors and APIs, and invalid schemas fail with useful diagnostics. See [Compiler architecture](../../architecture/compiler/README.md).

[Existing tests](../../../../crates/compiler/tests) cover parsing and validation, mutation history, CLI output and emitter content.

```sh
cargo test -p ahead-compiler --locked
```

Add a small schema fixture with an assertion on the resulting descriptor, generated output or diagnostic. When the claim is that generated code typechecks or runs, use [SDK integration tests](../integration/bindings.md) as well.

Next review: map individual compiler requirements to assertions, especially error locations and generated-language negative cases.

## Coverage review

Reviewed 2026-09-14 against [Parse](../../architecture/compiler/parse.md), [Validate](../../architecture/compiler/validate.md) and [Generate](../../architecture/compiler/generate.md); tests read, not executed.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| A syntax error reports its line | [compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_unknown_with_location` | covered (syntax only) | Semantic errors (relations, bindings, sequences, descriptor rules) report the end of input; this is a *defect* recorded in Validate §11. A test that asserts the offending line for a semantic error will fail today; write it as the regression for the fix. |
| Multi-file input maps a line back to its file | none found | missing | [cli.rs](../../../../crates/compiler/tests/cli.rs) uses one file. Add a two-file directory with an error in the second file. |
| Structural validation refuses bad identities, unknown prerequisites, duplicate versions, ambiguous inverses | `rejects_invalid_identity`, `rejects_dependency_typos`, `singular_inverse_requires_a_unique_foreign_key` | partial | Many refusal branches (unknown reference argument, sequence path mismatch, binding parent not single, invalid patch field) have no assertion. Prioritize the ones a schema author is likely to hit. |
| History and fence ([Mutations](../../architecture/schema/mutations.md)) | [history.rs](../../../../crates/compiler/tests/history.rs); `cli_retains_history_and_does_not_overwrite_on_break` | covered | `--initialize-mutation-history` refusal paths (existing history, non-1 versions) and a missing explicit history file are not asserted. |
| Same input produces identical output | none | missing | Compile twice and compare bytes to check the determinism requirement. |
| Emitters produce the documented surfaces; older versions get suffixed handler keys | `emitters_include_typed_conversion`, `backend_emitter_declares_handlers_loaders_and_references`, `backend_emitter_suffixes_older_mutation_versions`, `generated_clients_expose_one_server_connection`, `cli_writes_backend_ts_with_the_requested_runtime_import` | covered | Content checks are substring assertions; the executable checks are in [SDK integration](../integration/bindings.md). |
| Generated code rejects misuse at compile time | [test.ts](../../../../integration/generated-api/test.ts) `@ts-expect-error` block; [verify.sh](../../../../integration/generated-api/verify.sh) fails if `backend-missing.ts` typechecks | covered (TypeScript) | No Dart negative fixture; `dart analyze` runs only on valid code. |
