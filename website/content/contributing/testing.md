# Tests

The three test layers share data, not implementations:

1. Crate tests live beside their Rust modules. `integration/rust` connects the real Rust client and server state machines and checks deterministic ACK/Pull/restart traces against expected visible state.
2. `bindings` tests language callbacks and native lifetimes; `persistence` tests caller-owned transactions with actual PostgreSQL/Prisma; `generated-api` compiles positive/negative TypeScript fixtures and executes generated Dart/TypeScript against native Rust.
3. `e2e` starts an actual HTTP backend, PostgreSQL and local SQLite, then exercises both languages, normalization, rejection, lost responses and nonblocking local edits.

`fixtures/schemas` and `fixtures/protocol` contain reusable input data. `fixtures/compiler` contains source `.model` definitions. Test code stays in each owning module or integration package; temporary SQLite and PostgreSQL state is created per test run and removed afterward. No application cache or checked-in binary database is a fixture.

Run the full supported-host gate from the root:

```sh
bash scripts/test.sh
```

Requires Rust, Node 22.18+ (tested with Node 26.4), Dart 3.12+, Python 3 and PostgreSQL command-line tools on PATH. The scripts install repository-local JS/Dart dependencies, build native artifacts, and create their own temporary PostgreSQL clusters. The test databases are created and removed by their runners. Platform-specific simulator tests are separate from the normal host gate.

`.github/workflows/verify.yml` runs the same host gate on macOS and Linux, followed by optimized native artifacts and a binding smoke. The action setup follows the official [checkout](https://github.com/actions/checkout), [Node](https://github.com/actions/setup-node), [Dart](https://github.com/dart-lang/setup-dart) and [Rust](https://github.com/dtolnay/rust-toolchain) action documentation.

For focused checks, run `bash integration/persistence/transaction-probe/run.sh` or `bash integration/generated-api/verify.sh`. The capacity diagnostic is available through `cargo run -p ahead-integration --example capacity`.

See [guarantees and proofs](guarantees.md) for the proof inventory and [testing strategy](testing-strategy.md) for the planned test organization.
