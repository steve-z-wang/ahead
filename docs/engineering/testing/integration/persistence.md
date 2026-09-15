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

Use the real database and assert what survives a commit, rollback or reopen. Next review: isolation assumptions, simultaneous clients and schema changes with a non-empty pending queue.
