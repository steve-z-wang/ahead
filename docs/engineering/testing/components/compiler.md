# Compiler tests

Verify that accepted schemas produce the intended descriptors and APIs, and invalid schemas fail with useful diagnostics. See [Compiler architecture](../../architecture/compiler/README.md).

[Existing tests](../../../../crates/compiler/tests) cover parsing and validation, mutation history, CLI output and emitter content.

```sh
cargo test -p ahead-compiler --locked
```

Add a small schema fixture with an assertion on the resulting descriptor, generated output or diagnostic. When the claim is that generated code typechecks or runs, use [SDK integration tests](../integration/bindings.md) as well.

Next review: generated-language negative cases (Dart) remain open.

Verified 2026-09-14: `cargo test -p ahead-compiler --locked` passed (5 CLI, 12 compiler, 2 history tests) after the diagnostics and reserved-name changes.

## Coverage review

Reviewed 2026-09-14 against [Parse](../../architecture/compiler/parse.md), [Validate](../../architecture/compiler/validate.md) and [Generate](../../architecture/compiler/generate.md); tests read, not executed.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| A syntax error reports its line | [compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_unknown_with_location` | covered | none |
| A semantic error reports the offending declaration ([#48](https://github.com/zanminwang/ahead/issues/48)) | `semantic_errors_report_the_offending_declaration` (twelve cases: relation field, `onTargetDelete`, singular inverse, field type, binding parent, sequence target, prerequisite, duplicate mutation, patch field, unique fields, duplicate model, missing identity) | covered | Rules refused only by the core descriptor backstop still report the end of input (Validate §11). |
| Multi-file input maps a line back to its file | [cli.rs](../../../../crates/compiler/tests/cli.rs) `cli_relocates_errors_into_the_file_that_declares_them` | covered | Asserts `b.model:3:` for a semantic error and `b.model:5:` for a syntax error in the second file. |
| Reserved model names are refused at compile time ([#64](https://github.com/zanminwang/ahead/issues/64)) | `rejects_reserved_model_names_at_the_declaration` | covered | Asserts `sqlite_`/`ahead_` in either case are refused at the model's line and that `Sqlite`, `sqlitex`, `my_sqlite_table`, `aheadEntry` stay valid. |
| Structural validation refuses bad identities, unknown prerequisites, duplicate versions, ambiguous inverses | `rejects_invalid_identity`, `rejects_dependency_typos`, `singular_inverse_requires_a_unique_foreign_key` | partial | Many refusal branches (unknown reference argument, sequence path mismatch, binding parent not single, invalid patch field) have no assertion. Prioritize the ones a schema author is likely to hit. |
| History and fence ([Mutations](../../architecture/schema/mutations.md)) | [history.rs](../../../../crates/compiler/tests/history.rs); `cli_retains_history_and_does_not_overwrite_on_break`; `cli_refuses_misuse_of_the_mutation_history` | covered | The refusal test asserts a missing explicit history, initialization above version 1, initialization over an existing history, and that a refused compile writes no output. |
| Same input produces identical output | `cli_output_is_deterministic` | covered | Compiles the relations fixture twice and compares every output file byte for byte. |
| Emitters produce the documented surfaces; older versions get suffixed handler keys | `emitters_include_typed_conversion`, `backend_emitter_declares_handlers_loaders_and_references`, `backend_emitter_suffixes_older_mutation_versions`, `generated_clients_expose_one_server_connection`, `cli_writes_backend_ts_with_the_requested_runtime_import` | covered | Content checks are substring assertions; the executable checks are in [SDK integration](../integration/bindings.md). |
| Generated code rejects misuse at compile time | [test.ts](../../../../integration/generated-api/test.ts) `@ts-expect-error` block; [verify.sh](../../../../integration/generated-api/verify.sh) fails if `backend-missing.ts` typechecks | covered (TypeScript) | No Dart negative fixture; `dart analyze` runs only on valid code. |
