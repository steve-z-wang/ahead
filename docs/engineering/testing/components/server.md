# Server tests

Verify request validation, duplicate-batch handling, rejection, loader results and publication checkpoints. See [Server architecture](../../architecture/server/README.md).

[Existing Rust tests](../../../../crates/server/tests) provide a host implementation so each test can control responses and inspect calls.

```sh
cargo test -p ahead-server --locked
```

Assert both the response and the business calls that are permitted or prevented. A host fixture can establish sequencing, but real database locking and rollback need [Persistence tests](../integration/persistence.md).

Next review: map host-fixture assertions to server requirements and identify cases covered only by the PostgreSQL suite.
