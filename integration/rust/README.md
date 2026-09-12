# Rust integration

`cargo test -p otter-integration` runs 64 deterministic combinations of lost ACK, local edits, Pull/ACK ordering, rejection and restart. Expected visible values are asserted independently of the client reducer; the backend Host fixture supplies controlled persistence. Actual PostgreSQL transaction behavior is tested under `integration/persistence`.

For a small capacity diagnostic:

```sh
cargo run -p otter-integration --example capacity --release
```

It enqueues 10 and 1,000 updates to one record, with one real SQLite commit per mutation, then applies an authoritative page and checks that pending replay preserves the latest local value. It reports enqueue p50/p95 and a single page/replay duration. The temporary database is removed at exit.

On the development macOS arm64 host (2026-09-10, optimized build), results were:

| Pending | Enqueue p50 | Enqueue p95 | One page + replay |
| --- | --- | --- | --- |
| 10 | 0.42 ms | 0.67 ms | 0.59 ms |
| 1,000 | 2.17 ms | 3.51 ms | 5.38 ms |

These are local diagnostic samples from a single run with a tiny working set. They do not measure a large multi-record cache, mobile devices, network latency, bridge overhead or production throughput. Replay is Rust-only; there are no per-field language callbacks in this measurement.
