# local-first-state

A local-first state framework with a shared Rust runtime and typed Dart/TypeScript APIs.

The first implementation runs local SQLite clients against an embedded Node backend with Prisma/PostgreSQL. Rust owns schema validation, optimistic state, durable mutation batches, channel cursors and ACK/Pull settlement. Business code supplies Handlers, Loaders and explicit channel publication inside application-owned transactions. Generated business types stay in Dart/TypeScript.

## Try it

With Rust, Node 22.18+, Python 3 and PostgreSQL command-line tools installed:

```sh
bash examples/rust-round-trip/run.sh
```

In another terminal:

```sh
node examples/rust-round-trip/client.mts
```

Use `sync`, `edit TEXT`, `show`, and `status` to observe offline edits, server normalization and durable retry. [Example instructions](examples/rust-round-trip/README.md) describe the complete setup. Add Dart to run both clients through the real backend with `bash integration/e2e/run.sh`.

## Packages

| Area | Implementation |
| --- | --- |
| Shared values and protocol | `crates/lfs-core` |
| Client state and scheduling | `crates/lfs-client` |
| Server state machine | `crates/lfs-server` |
| Local persistence and read-only SQL | `crates/lfs-sqlite` |
| Schema compiler and language generators | `crates/lfs-compiler` |
| Native boundary | `bindings/common`, `bindings/node`, `bindings/dart` |
| Frontend APIs | [TypeScript](packages/client-js/README.md), [Dart](packages/dart/README.md) |
| Embedded backend | [Server](packages/server/README.md), [Prisma](packages/persistence-prisma/README.md), [Nest](packages/nest/README.md) |

## Test and design

`bash scripts/test.sh` builds and verifies the supported native host. [Testing](integration/README.md) explains the three layers and shared fixture folders. [Implementation evidence](docs/implementation-progress.md) records verified coverage and remaining platform limitations.

- [Concepts and accepted naming](docs/architecture/concepts-and-naming.md)
- [Code organization and language boundary](docs/architecture/code-organization.md)
- [Next things](docs/next-things.md)
- [Architecture decisions](docs/superpowers/specs/2026-09-10-rust-core-design.md)
- [Implementation roadmap](docs/superpowers/plans/2026-09-10-rust-rebuild.md)
- [Reference behavior inventory](docs/superpowers/specs/2026-09-10-existing-logic-audit.md)

This is a source alpha. Cross-channel record revisions and their new conflict rules remain deferred. The original per-change invalid Pull skip behavior and overlapping channel limitations are retained. Live wakeups are process-local; multi-process deployments need a host-provided committed notification mechanism. The first SQLite implementation keeps a snapshot in memory and writes changed documents; large-cache performance still needs dedicated work. It does not import the original database layout.

The reference implementation remains on `main` at commit `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8`. This branch is a fresh implementation, with shared wire behavior covered by tests; it is not a drop-in database migration. The repository remains private. No package release or license grant has been added.
