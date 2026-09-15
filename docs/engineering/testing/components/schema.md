# Schema contract tests

Verify what a schema describes: identities, field types, relationships, mutations and valid combinations. The [schema documents](../../architecture/schema/README.md) define these rules; compiler tests verify how source declarations become that contract.

Existing entry points: [core contracts](../../../../crates/core/tests/contracts.rs) and [compiler tests](../../../../crates/compiler/tests).

```sh
cargo test -p ahead-core --test contracts --locked
cargo test -p ahead-compiler --locked
```

Assert accepted and rejected descriptors, field presence and nullability, identity constraints and relationship rules. Keep received-state validation distinct from backend loader validation: their treatment of unknown fields differs. Database reconciliation belongs in [storage integration](../integration/persistence.md).

## Coverage review

Reviewed 2026-09-14 by reading test assertions against the schema documents; no tests were executed for this review. Coverage terms: *covered* means an assertion checks the clause; *partial* means only some clauses or only an indirect path; *missing* means no assertion was found.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Integers outside ±2^53−1 are refused; UUIDs normalize to lowercase and must be RFC 4122 ([Types](../../architecture/schema/types.md)) | [contracts.rs](../../../../crates/core/tests/contracts.rs) `state_is_complete_but_patch_preserves_absent_and_null`, `identities_are_exact_normalized_and_independent_of_channels` | covered | none |
| `dateTime` re-encodes to UTC milliseconds; `float` must be finite and `-0` becomes `0`; enum values must be declared | Dart [generated_test.dart](../../../../integration/generated-api/generated_test.dart) filters `at` with a `+01:00` offset through the native client | partial | No core assertion on `dateTime`, `float` or enum-value normalization; only a generated-API round trip touches dates. Add core cases per scalar, including rejected inputs. |
| A list element must be a scalar and a list cannot be nullable | none found | missing | Add core descriptor cases: list of enums, nested list, nullable list. |
| Identity must be one or more non-nullable scalar fields; `ahead_` prefix refused; names unique ([Models](../../architecture/schema/models.md)) | [compiler.rs](../../../../crates/compiler/tests/compiler.rs) `rejects_invalid_identity`, `schema_and_mutations`; `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected` | covered | Duplicate model or field names are refused by code but not asserted. |
| `@@unique` is enforced atomically on the client (L3) | [client.rs](../../../../crates/sqlite/tests/client.rs) `declared_unique_constraint_is_atomic` | covered | none |
| Reference `via` arity and field types must match the target identity; `onTargetDelete` is `delete` or `none` ([Relations](../../architecture/schema/relations.md)) | positive case in `relationships_bindings_and_dependency_metadata` | partial | No negative case for arity or type mismatch or an unknown `onTargetDelete` value. |
| Inverse resolution requires exactly one reference; singular inverse needs a unique key | `singular_inverse_requires_a_unique_foreign_key` | covered (singular) | Ambiguous inverse (two references without `@inverse`) not asserted. |
| Cascades apply on direct writes, queued mutations and authoritative deletes (L5) | client, downlink and sim tests listed under [Client tests](client.md) | covered | none |
| Slot decoding: order by `(model, op)`, list slots greedy, stable rejection codes ([Mutations](../../architecture/schema/mutations.md)) | [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs) | covered for single slots | Adjacent slots with the same model and operation (the `RemoveEntries` shape in the fixture) have no assertion; the greedy result is a *potential risk* awaiting a decision ([#54](https://github.com/zanminwang/ahead/issues/54)), not a test to write yet. `Model.update<>` compiles and always fails on the server: a *defect* in the compiler's acceptance ([#49](https://github.com/zanminwang/ahead/issues/49)), no test. |
| Version history: no decrease, no removal, compatible changes accepted | [history.rs](../../../../crates/compiler/tests/history.rs), [cli.rs](../../../../crates/compiler/tests/cli.rs) | covered | Enum-value growth and the "create slot gains a non-nullable field" rule are implemented but not asserted individually. |
| Prerequisite keys derive from operation values; failed tasks block until reset ([Prerequisites](../../architecture/schema/prerequisites.md)) | [push.rs](../../../../crates/sqlite/tests/push.rs) `schema_requirements_create_durable_tasks_and_gate_only_dependent_mutation`, `failed_prerequisite_stays_optimistic_independent_work_can_overtake`, `late_task_completion_does_not_resurrect_unused_readiness`; [prerequisite.test.mjs](../../../../integration/bindings/client-js/prerequisite.test.mjs) | covered (TypeScript runner) | The Dart `runPrerequisites` runner has no test. |
