# Node native transaction probe (M0)

This is a feasibility probe, not the server SDK or the general persistence adapter.
Rust runs in-process through NAPI-RS; it owns no database connection. `run_probe`
invokes the Node host using a thread-safe function, awaits the returned JavaScript
Promise, invokes the read callback, awaits it, and returns the observed count.
The JavaScript closure captures only the transaction supplied by the application.

`committedResult(userTransactionRunner, body)` registers the transaction scope,
rejects caught persistence failures or unfinished native operations before the body
returns, and closes every handle in `finally`. The caller's runner owns begin,
commit and rollback. An accepted result can escape only after that runner resolves,
including successful commit. Direct `TransactionProbe` construction outside that
scope is rejected. Explicit business rejection uses the application's savepoint;
it is a domain result rather than a poisoned persistence exception.

Run from the repository root:

```sh
bash integration/persistence/transaction-probe/run.sh
```

Requirements: Rust/Cargo, Node/npm, PostgreSQL `initdb`/`pg_ctl`, Python 3. The script
uses repository-local `.tools` Rust if available. It builds the native library,
installs locked Prisma dependencies, generates the fixture client, creates its own
temporary PostgreSQL cluster on a free local port, runs 12 tests, and stops/removes
the cluster on exit. It does not use an external `DATABASE_URL`.

For an already isolated test database, after installation and generation:

```sh
node bindings/node/build.mjs
DATABASE_URL=postgresql://USER@127.0.0.1:PORT/postgres node --test integration/bindings/node/transaction-bridge.test.mjs
```

The direct test command creates/deletes probe table data; use only a disposable
probe database. The native crate is an independent Cargo workspace, with its own
lockfile, until integrated into the release workspace. Build artifacts and the
generated Prisma client are ignored. The `.d.mts` file describes the M0 interface.

Verified 2026-09-10 on macOS arm64: Rust 1.98.1, Node 26.4.0, PostgreSQL 14,
Prisma 6.19.0, napi 3.12.2, napi-derive 3.6.4, napi-build 2.4.2. The initial
contract run had eight missing-bridge failures and a passing global-client negative
control; final isolated harness: 12 passed, 0 failed. A separate new metric
assertion failed before its implementation and passed after rebuilding.

The successful roundtrip reports two callbacks, native elapsed microseconds, and
18 logical payload bytes (UTF-8 operation names plus two u32 callback results).
This excludes NAPI object/Promise overhead and the final result object; there is no
JSON serializer here. This probe makes no latency or language-speed claim.

Limits: no production receipt/publication API, HTTP ACK encoder, or general runtime
cancellation implementation is included. The accepted-result gate is tested at
the runner boundary with a real deferred constraint commit failure. Transaction
timeout is tested with a delayed callback; arbitrary host code that never settles
cannot be forcibly interrupted by this probe. Closing prevents subsequent host DB
operations, but cannot undo a host operation already executing; the enclosing
transaction supplies rollback. Concurrent isolation tests use Repeatable Read.

`npm audit` currently reports four high findings in the pinned Prisma 6 tooling
chain (`@prisma/config`, `deepmerge-ts`, `effect`, `prisma`). No forced downgrade or
incompatible override was applied to conceal those results. This dependency set is
for the local integration harness and needs release dependency review before
production packaging.

API basis: NAPI-RS's official `ThreadsafeFunction` Promise example and
`call_async_catch` catchable synchronous-throw API:
https://github.com/napi-rs/napi-rs/blob/main/examples/napi/src/threadsafe_function.rs
