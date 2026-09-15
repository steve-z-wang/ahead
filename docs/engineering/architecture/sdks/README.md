# SDKs

The SDKs are what application code imports. Their job is translation only: typed calls become JSON commands to Rust, results and errors come back typed. Every rule about data lives in the Rust runtimes.

- [Typed API](typed-api/README.md) — Expose strongly typed APIs to applications.
- [Bindings](bindings.md) — Bridge calls, arguments, results, errors and events between the language and Rust.
