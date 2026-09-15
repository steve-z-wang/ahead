# Protocol contract tests

Verify the messages shared by client and server: field names, counters, canonical encoding, checkpoints, stamps and malformed input. The [protocol documents](../../architecture/protocol/README.md) define the contract.

Existing entry point: [core contracts](../../../../crates/core/tests/contracts.rs), including shared wire fixtures and numeric boundaries.

```sh
cargo test -p ahead-core --test contracts --locked
```

Use explicit expected wire values and invalid inputs. A round trip alone can miss matching encoder and decoder errors. Encoding a semantic hash does not establish server retry validation; that behavior belongs in [server tests](server.md). Actual HTTP and WebSocket behavior belongs in [connection integration](../integration/connection.md).
