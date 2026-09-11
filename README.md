# local-first-state

A local-first state framework with a schema-driven Rust runtime and typed language SDKs.

This branch starts a new implementation from scratch. It currently contains design documents only; there is no runnable runtime or package release yet.

The runtime loads a language-neutral schema as data. It does not compile application-specific types such as `Entry` or `Book`. Language generators provide those types and idiomatic APIs for Dart and TypeScript.

## Design

- [Code organization and language boundary](docs/architecture/code-organization.md)
- [Rust runtime architecture proposal](docs/superpowers/specs/2026-09-10-rust-core-design.md)
- [Implementation roadmap](docs/superpowers/plans/2026-09-10-rust-rebuild.md)
- [Reference behavior inventory](docs/superpowers/specs/2026-09-10-existing-logic-audit.md)

## Reference implementation

The original exported implementation remains in commit `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8` and on `main`. The planning baseline is commit `370e1f1` on `codex/backend-api`.

Old source, tests, examples and build configuration have been removed from this branch. Their behavior inventory guides the new implementation; this is not a claim of backward compatibility.

The repository remains private. No license grant or registry release has been added.
