# Client tests

Verify local transactions, dependency eligibility, stable frozen batches, page application and settlement. See [Client architecture](../../architecture/client/README.md).

Many engine tests currently live in [sqlite/tests](../../../../crates/sqlite/tests), where real SQLite provides the client harness. Retry scheduling also has inline tests in [connection.rs](../../../../crates/client/src/connection.rs).

```sh
cargo test -p ahead-client --locked
cargo test -p ahead-sqlite --locked
```

For a batching change, assert which mutations are eligible and whether retry bytes remain stable. For settlement, assert the resulting visible state and pending work, rather than only the pending count.

Use [Simulation](../simulation/README.md) for interactions across clients and server. Next review: identify missing assertions and distinguish engine coverage from SQLite-specific coverage.
