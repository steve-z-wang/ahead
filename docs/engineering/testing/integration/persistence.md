# Storage and persistence tests

Verify real transaction boundaries, committed-reader isolation, rollback, reopen and concurrent access. Simulation's in-memory server host cannot establish PostgreSQL semantics.

| Boundary | Existing evidence |
| --- | --- |
| SQLite | [store.rs](../../../../crates/sqlite/tests/store.rs), [ddl.rs](../../../../crates/sqlite/tests/ddl.rs), and reopen scenarios in [client.rs](../../../../crates/sqlite/tests/client.rs) |
| PostgreSQL / Prisma | [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) and the [transaction probe](../../../../integration/persistence/transaction-probe/README.md) |

After the prerequisites in [Running tests](../running.md):

```sh
cargo test -p ahead-sqlite --test store --locked
cargo test -p ahead-sqlite --test ddl --locked
bash integration/persistence/server/run.sh
bash integration/persistence/transaction-probe/run.sh
```

Use the real database and assert what survives a commit, rollback or reopen. The coverage review below records what the existing tests assert; missing tests are tracked in [#68](https://github.com/zanminwang/ahead/issues/68).

## Coverage review

Reviewed 2026-09-14; tests read, not executed.

### SQLite (client store and reconciliation)

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Reader sees only committed rows; writer sees its own; savepoints nest; read paths refuse writes; second writer fails after the busy timeout ([Store](../../architecture/client/storage/store.md)) | [store.rs](../../../../crates/sqlite/tests/store.rs) | covered | none |
| Fresh database: model, before and framework tables, unique indexes | [ddl.rs](../../../../crates/sqlite/tests/ddl.rs) `creates_model_before_and_framework_tables` | covered | none |
| Additive changes: nullable column, non-nullable with default; unknown columns kept ([Reconciliation](../../architecture/client/storage/reconciliation.md)) | `adds_missing_columns_to_both_tables_and_keeps_unknown_ones` | covered | none |
| Refused: non-nullable without default, type change, identity change; file untouched | `rejects_non_nullable_column_without_default_identity_change_and_type_change` | covered | none |
| Kept but undeclared: a unique index whose columns changed keeps constraining; a removed model's tables stay; enum value changes are undetected | none | missing | These are the current behavior, not a decided contract ([#20](https://github.com/zanminwang/ahead/issues/20)). Document them as characterization tests only after the contract is chosen, or the tests will pin an accident. |
| Reconciliation with a populated queue: frozen bytes unchanged, unsent creates still valid | none | missing | P4 and the reconciliation contract require this; the ddl tests run with an empty queue. Add a case that enqueues, freezes, reopens with an added nullable column, and compares bytes. |
| Reopen preserves queue, receipts, cursors, claims, stamps, tombstones and rejections (L2, R3) | [client.rs](../../../../crates/sqlite/tests/client.rs), [push.rs](../../../../crates/sqlite/tests/push.rs), [stamp_scenarios.rs](../../../../crates/sqlite/tests/stamp_scenarios.rs) `reopen_preserves_stamps_claims_and_tombstones` | covered | A reopen is a close and open, not an interrupted process; see [Failure and recovery](../simulation/recovery.md). |

### PostgreSQL (server persistence)

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Client row lock serializes concurrent retries; receipt stored atomically with business writes (P1, P6) | [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `concurrent same-client retry executes once under PostgreSQL lock`, `push commits business + compacted publication + exact durable receipt together`, `unknown error rolls back entire batch…` | covered | none |
| Per-mutation savepoints against a real database | `explicit rejection rolls back only mutation and its publication`; [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs) `business rejection rolls back its savepoint while preceding mutation commits` | covered | The bridge test drives `SAVEPOINT` statements by hand around the spike probe, not through `createBackend`; the first test is the production path. |
| Stamp and cursor allocation, concurrent notifies, scan returns stamps (D3) | `publish allocates one stamp per notify…`, `concurrent notifies of one record receive distinct stamps`, `scan returns the stamp of each row` | covered | none |
| Head, scan and load coherent under concurrent publication | `repeatable-read runner keeps head, scan, and loader coherent…` | covered at RepeatableRead | Serialization-failure retry in `prismaTransactions` (`P2034`, `40001`, `40P01`) is never triggered by a test. |
| BigInt narrowing to safe integers | `loader safely converts PostgreSQL BigInt scalar and list values…` | covered | none |
| Unawaited or failed callbacks prevent commit | `pending unawaited publication prevents outer transaction commit`, `external transaction binding retains swallowed publication failure…` | covered | none |
| `request_hash` column | none | not applicable | Dead schema ([Persistence §11](../../architecture/server/persistence.md)); nothing to test until the hash decision in [#47](https://github.com/zanminwang/ahead/issues/47) is made. |
