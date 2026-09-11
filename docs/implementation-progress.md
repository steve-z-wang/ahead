# First-version implementation evidence

The user approved end-to-end implementation on 2026-09-10. The Rust rewrite now runs through both language SDKs against the embedded backend and a real database. This is a private source alpha; it is not a public package release or a claim that the entire future platform roadmap is complete.

## Implemented

| Area | Delivered |
| --- | --- |
| Shared Rust runtime | Schema-as-data, normalization, identities, legacy wire codecs and request hashes. No generated business types in Rust. |
| Persistent client | SQLite transactions/savepoints, direct and optimistic writes, sparse before images, durable queue/frozen batches, ACK checkpoint barriers and accepted-prefix settlement. |
| Existing client behavior | Channel claims, companion/cascade effects, lifecycle/sequence dependencies, prerequisites, rejection inbox/status, queries/relations/watch, read-only SQL and background scheduling. |
| Backend | Generic Rust Push/Pull/publication state machines, application-owned transaction callbacks, per-mutation savepoints, durable batch receipts and coherent Loader snapshots. |
| Integration | Node/N-API and Dart FFI worker, Prisma/PostgreSQL persistence with reusable `bind`, HTTP/WebSocket attachment to the application's server, ordinary registration and Nest decorators. |
| Compiler | Rust `.model` parser/validation/history; generated Dart and TypeScript identities, model/patch types, operation builders, typed queries, relations and backend inputs. |
| Developer workflow | Independent runnable example, build/test scripts, host CI definition, shared fixtures, compatibility/recovery documentation and a repeatable small capacity diagnostic. |

## Verification

`bash scripts/test.sh` passed locally on macOS arm64. The final [GitHub verification run](https://github.com/steve-z-wang/local-first-state/actions/runs/34555679980) passed on fresh `macos-14` and `ubuntu-24.04` runners for code commit `92bf410`, including the complete gate, optimized Rust/Node builds and the optimized binding smoke. A clean-install Nest dependency omission found in the first CI run was corrected before this successful run. The complete gate includes:

| Check | Observed result |
| --- | --- |
| Rust format, workspace tests, Clippy with warnings denied | Passed |
| Core contracts | 11 tests, including shared wire fixtures |
| SQLite client behavior | 28 tests, including migration refusal preserving the original database/frozen bytes |
| Rust connection driver | 2 tests |
| Common native command boundary | 2 tests |
| Rust client ↔ Rust server | 64 deterministic interleaving/restart scenarios |
| Rust server contracts | 8 tests |
| Compiler | 10 tests; the reference `.model` corpus also compiled during implementation |
| Node client boundary | 13 tests after the close/start regression, including ordered transactions, nested savepoints, prerequisites and connection lifecycle |
| Real Node/Prisma transaction bridge | 12 tests |
| Native backend + PostgreSQL + HTTP/WS | 23 tests, including safe BigInt scalars/lists and overflow rejection |
| Nest | 5 runtime tests plus expected rejection of an invalid typed handler input |
| Dart native client | 6 tests after the close/start regression; analysis passed in the full gate |
| Generated APIs | TypeScript positive/negative compilation and native calls; Dart analysis and 2 native tests |
| Actual HTTP end-to-end | Node and Dart against Rust/Prisma/PostgreSQL/SQLite; lost ACK retry, normalization, business rejection, offline reopen, local writes during delayed responses, background pause/resume |
| Optimized native build | Rust workspace and Node addon built successfully |
| Small capacity diagnostic | Queues of 10 and 1,000 real SQLite commits; [method and measurements](../integration/rust/README.md) |

The tests use temporary databases and disposable PostgreSQL clusters. They do not access an application database or change Oasis.

## Review

A broad read-only review checked `97faef6..26e3f99` plus focused subsequent fixes. It found unsupported identity migration, stale connection ownership/controls, safe BigInt Loader serialization, and a close/start lifecycle race. Each has a regression test and a corresponding fix; focused re-review approved all four fixes. Earlier targeted reviews also corrected savepoint lifetimes, companion cascade settlement, late prerequisite completion, live wake races and asynchronous Nest provider initialization.

## Platform and release boundaries

| Platform | Observed support |
| --- | --- |
| macOS, Node + Dart | Local arm64 and fresh hosted runner: native build, persistence, full HTTP E2E and optimized artifacts verified. |
| iOS arm64 simulator | Rust static library and Flutter app link/build verified. Runtime smoke did not reach the first Dart main marker on a disposable iOS 18.5 simulator; no passing FFI/SQLite app-restart claim. See [platform evidence](../integration/platform/README.md). |
| iOS device / Android | Not verified. No Android SDK/emulator is available on this host. |
| Linux, Node + Dart | Fresh Ubuntu 24.04 runner: complete host gate, real PostgreSQL/HTTP E2E, optimized builds and native binding smoke passed. |
| Browser/WASM / Windows | Not supported/verified by this first source implementation. |

The source alpha uses a new local database. Original database/history importing, arbitrary identity/type conversion, production-scale indexing, distributed committed wake delivery and broader platform packaging are not implemented. The existing overlapping-channel limitations and per-change malformed Pull skip behavior are preserved. Record revisions, protocol reset/GC and other semantics changes remain in [Next things](next-things.md).

Dependency audit: root development tools and the updated Nest 11.2.3 package/test dependency sets reported zero npm findings. The pinned Prisma 6.19 CLI used by example/test tooling reported four high transitive findings involving `effect` and `deepmerge-ts`; no forced major-version downgrade or override was applied. The framework runtime adapter does not depend on Prisma CLI. Resolve and revalidate that tooling dependency set before public distribution.

The original implementation is retained in Git history at `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8`. The rebuild was developed on `codex/rust-rebuild` and merged into `main`. The upstream repository remains private; no registry publishing or license grant has been performed.
