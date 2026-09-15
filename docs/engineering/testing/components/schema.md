# Schema contract tests

Verify what a schema describes: identities, field types, relationships, mutations and valid combinations. The [schema documents](../../architecture/schema/README.md) define these rules; compiler tests verify how source declarations become that contract.

Existing entry points: [core contracts](../../../../crates/core/tests/contracts.rs) and [compiler tests](../../../../crates/compiler/tests).

```sh
cargo test -p ahead-core --test contracts --locked
cargo test -p ahead-compiler --locked
```

Assert accepted and rejected descriptors, field presence and nullability, identity constraints and relationship rules. Keep received-state validation distinct from backend loader validation: their treatment of unknown fields differs. Database reconciliation belongs in [storage integration](../integration/persistence.md).
