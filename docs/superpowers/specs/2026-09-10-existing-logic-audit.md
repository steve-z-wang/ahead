# local-first-state: existing logic audit and coverage matrix

> Historical design record (2026-09-10): status statements and proposed APIs below reflect the original planning stage. See [implementation evidence](../../implementation-progress.md) for the current delivered scope and verified limitations.

Date: 2026-09-10. Status: source review, without running the complete tests; this is design input, not a certification of the existing implementation's correctness.

Standalone repository reference commit: `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8`. Original Oasis export source: `78e64a9bc93d3dab4bf256eed0a3051702f58882`.

Repository paths below are relative to the local-first-state root; Oasis paths are identified separately. New code is implemented from scratch, with existing source retained as a behavioral reference.

> Scope update: this phase migrates existing behavior only. Previously proposed improvements, revisions, epochs and failure-policy changes in the matrix all belong in [Next things](../../next-things.md), not migration tasks; source findings and risks remain documented.

> Naming map: this audit retains the old source's terms and paths. The new implementation uses Scope → Channel, Materializer → Loader, and Uplink/Downlink → Push/Pull; Sync ID becomes Cursor or Checkpoint according to its purpose. See [Concepts and naming](../../architecture/concepts-and-naming.md). Old paths here refer to the reference commit, not code already present in the current worktree.

## 1. Actual data flow

1. The generated Dart API constructs named mutations containing create/update/delete operations in schema order.
2. An outer SQLite transaction may contain direct local writes and multiple named mutations; each mutation has its own savepoint/fate.
3. The first optimistic modification saves the authoritative before image; the main table immediately receives the visible result, while the mutation, operations, dependencies and scope changes are persisted. The UI queries the main table.
4. The scheduler selects work by readiness, lifecycle dependencies and business ordering dependencies; after a batch is frozen, an unknown outcome requires resending the same request.
5. The backend validates owner, client, batch sequence, hash and mutation version; claims/receipts execute in a database transaction.
6. Currently, the whole batch shares one transaction, with each mutation's resolver running in a savepoint. Business rejection rolls back only that mutation; unknown exceptions roll back the entire batch.
7. Resolvers explicitly invalidate scopes. Each scope has an independent head; lock the row, increment and update the compacted invalidation.
8. ACK persists rejections and required scope checkpoints. Accepted does not mean optimistic operations can be removed.
9. Downlink materializes the current complete content at read time. The client updates the authoritative base, then replays pending operations.
10. Settlement occurs only after all required checkpoints have actually been applied; if ACK arrives after downlink, the durable cursor establishes this without waiting for another page.

A before image is not an immutable initial snapshot: while dirty, it is the authoritative base continually updated by downlink. Acceptance of a purely local companion may also advance its local base.

## 2. Coverage by capability

| Capability | Current entry point | Rust rewrite destination / decision |
|---|---|---|
| `.model` parser / diagnostics | `compiler/lib/src/syntax/`, `semantic/` | Reuse build-time compiler descriptions first, migrate to Rust compiler later; do not invent a new DSL first |
| Scalar, enum, list, nullable, UUID, DateTime | `semantic/model_graph.dart`, `server/src/model-contract/value-codec.ts` | Rust schema/protocol; SDKs only convert language values |
| Single/composite identity, canonical key | `schema/model_id.dart`, `backend/identity-normalizer.ts` | Unify in Rust; do not concatenate composite keys with separators |
| Relation, inverse, unique, cascade graph | `semantic/model_graph_builder.dart`, `schema/relation_index.dart` | Rust metadata/validation; generate typed relationship APIs |
| Slot order, optional/list slots, patch allowlist | `mutation/model_operation.dart`, `backend/slot-binding-precheck.ts` | Preserve the structured contract first, then improve the business input API |
| Slot relation binding | `mutation/slot_binding_verifier.dart` | Rust; validation depending on stored rows occurs inside the transaction |
| Mutation historical versions | `compiler/lib/src/mutation_history.dart` | Retain historical input shapes; do not reinterpret persisted requests using the new schema |
| Schema compatibility fence | `compiler/lib/src/contract_fence.dart` | Retain the old fence's checks for disappearing fields/models; broader type, identity and nullability checks are deferred |
| Generated code carries no algorithms | `compiler/lib/src/emit/`, `tool/gate.sh` | Retain; the generated layer emits only types, descriptions and forwarding |
| Main + sparse before image | `storage/before_image_store.dart`, `row_rebuilder.dart` | Rust client; clean rows have no before image |
| Optimistic reducer | `projection/mutation_reducer.dart` | Rust; preserve absent/null distinction and make conflict degradation explicit |
| Outer local transaction / mutation savepoint | `mutation/transaction_executor.dart`, `mutation_scope_executor.dart` | Rust transaction session; multiple reads/writes can interact sequentially |
| Direct local writes | `storage/direct_model_writer.dart` | Retain, separate from server fate |
| Local companions | `mutation/companion_model_writer.dart` | Retain: same mutation fate, not uploaded; wire optimism must not be treated as authority |
| Cascade scans main + before | `storage/cascade_expansion.dart`, `api/cascade_deleter.dart` | Migrate existing cascade behavior; further distinction between scope removal and true deletion is deferred |
| Ordering / lifecycle dependencies | `mutation/mutation_dependency_writer.dart` | Rust; do not conflate their different rejection propagation and same-batch behavior |
| Readiness ledger | `uplink/readiness_ledger.dart` | Durable Rust state; missing row means pending; clean up when references reach zero |
| Media upload prerequisites | `uplink/prerequisite_runner.dart` | Rust decides, host uploads; distinguish ready/failed/retry |
| Scheduling and independent tasks overtaking | `uplink/mutation_scheduler.dart` | Rust; do not silently degrade to global FIFO |
| Frozen batch / unknown-outcome retry | `uplink/mutation_queue.dart`, `batch_executor.dart` | Retain frozen batches and batch receipts |
| Refusal, dependency propagation, drop | `uplink/mutation_queue.dart` | Rust; sent requests with unknown outcomes cannot count as successfully cancelled |
| Durable rejection inbox | `storage/mutation_rejection_store.dart`, `api/local_sync_mutations.dart` | Retain codes, operation snapshots and explicit acknowledgement |
| Identity upload status | `uplink/uplink_status.dart` | Derived by Rust, without separately stored state that can drift |
| Dynamic scope subscriptions | `downlink/scope_store.dart`, `scope_reconciler.dart` | Durable desired state in Rust, restored on startup/reconnection |
| Optimistic scope changes | `downlink/transaction_scopes.dart` | Share the owning mutation's fate |
| Unified HTTP pull / WS live application | `downlink/downlink_worker.dart`, `downlink_page_queue.dart` | Rust protocol state machine; platforms only transport bytes/events |
| Cursor/stale page | `downlink/downlink_page_processor.dart` | Retain existing behavior; failure-policy and epoch improvements are deferred |
| Multi-scope settlement | `uplink_batch_checkpoints`, `_readBatchesReadyAfterAdvance` | Retain barriers; numbers from different scopes cannot be compared |
| Accepted prefix | `downlink/downlink_page_processor.dart` | Retain accepted-prefix rules; independent settlement is deferred |
| Scope row claims | `downlink/scope_row_ledger.dart` | Retain membership information; it does not replace freshness |
| Cross-scope record freshness | No independent record-revision arbitration currently | Next things; not added in this phase |
| Tombstone / remove-from-scope | Currently combined in `state:null` | Retain null semantics in this phase; distinct deletion types are deferred |
| Server idempotency/owner fencing | `backend/uplink-executor.ts`, `uplink-receipt.ts` | Rust server + atomic persistence |
| Explicit publish scopes | `backend/scope-ledger.ts` | Retain; do not switch to ambient/model-based automatic routing |
| Decoupled frontend/backend data models | `backend/model-binding.ts` | Retain; one business table may project to multiple client models |
| Materializer alignment | `backend/downlink-materializer.ts` | Retain existing identity alignment and visibility; the new Loader interface must adapt to old semantics |
| Preparation writes | `prepareForViewer` | Preserve transaction requirements before migration; do not assume all existing loaders are pure reads |
| Scope authorizer | `backend/backend-options.ts` | Retain existing authorizer behavior; whether to make it optional is deferred |
| Transaction adapter | `backend/transactions.ts`, `storage.ts` | Users own transactions; official adapters supply atomic capabilities |
| Commit wakeup | `backend/committed-changes.ts`, `downlink-subscription.ts` | Retain existing notification/catch-up; new recovery strategies such as polling are deferred |
| Host/server | `backend/local-sync-host.ts` | Embed into the user's server; a separate listener is only an example convenience |
| Token/auth/lifecycle/cancel | `transport/` | Host credentials and I/O; Rust decisions; old-session callbacks must not contaminate new sessions |
| Query/get/watch/relations | `api/model_query.dart`, `projection/query_evaluator.dart` | Rust query IR/execution; SDK typed facade; post-commit notifications |
| Read-only SQL | `api/read_only_sql.dart` | Retain the escape hatch, with actual read-only validation rather than a string-prefix check |
| Database/savepoint/errors/watch | `client/local_sync_database*` | Native defaults to Rust SQLite; extension adapters run the same contracts |
| Five conformance groups | `conformance/*/README.md` | Rust algorithm tests + ABI + DB contracts + E2E; reduce duplicated implementations, retain protocol verification |
| Build/CI/release | `tool/gate.sh`, `.github/workflows/test.yml` | Separate new/old gates; do not apply the old Nest/Prisma prohibition fence to new adapters |

## 3. Behaviors that must not be copied uncritically

### Cursor advances after downlink failure

`downlink_page_processor.dart` calls `_commitSkip` after a decode error or `_CanonicalChangeFailure`; that in turn runs `_settleAndAdvance`. Reaching a cursor therefore does not always prove the authoritative change was successfully applied. Atomic whole-page application / no cursor advancement on failure is a deferred fix proposal requiring separate review; first characterize and retain original behavior in the rewrite, without treating retention as a correctness certification.

### Snapshot isolation requirements are implicit

`downlink-materializer.ts` wraps head/scan/prepare/read in `transactions.write`; the generic write interface itself does not specify repeatable-read guarantees. Migration must characterize the actual read guarantees for heads, invalidations and materialized state; stronger snapshots and record revisions belong in Next things. Reads across external APIs/databases are not claimed to be automatically atomic.

### External user transactions may not trigger live wake

Oasis `backend/src/local-sync/prisma-persistence.ts` records touched scopes in a wrapper-owned WeakMap. Its comment is explicit: independently opened external transactions can store invalidations but may not produce live wake. User post-commit signals, polling to compensate for missed notifications and cross-instance notification extensions belong in Next things; first verify and document original behavior in this phase.

### Integer limits differ

Scope counters are internally signed int64, while wire JSON and clients are limited by JavaScript safe integers. The proposed new protocol would unify the nonnegative signed-64 range and use decimal strings on the wire, without converting to JS numbers in SDKs. This requires a new wire version, not a silent compatibility change.

### Membership and authority are mixed

Upserts in `downlink_change_applier.dart` have no cross-scope record-revision arbitration; null releases only the current scope and retains the row if another claim exists. This can express leaving one scope, but cannot fully express global deletion or late stale content from another scope.

## 4. Actual product requirements

| Oasis scenario | Conclusion |
|---|---|
| Multiple people sharing a Book | A shared scope is reasonable and reduces repeated per-person invalidations; every client still needs network delivery |
| Move Moment retains identity and publishes to old/new Book | Test interleaved arrivals, late old pages and child-record reassignment; a single-scope design does not automatically solve Move |
| Reply retains recipients from send time | Moving to a Book scope requires separate audience storage; changing only the scope string is insufficient |
| Space contains viewer-private fields | Recommend splitting public Book from personal BookState; the same model/id/revision on one client must not have conflicting content |
| MomentMedia sourceId is owner-only | Projection identity/version rules need definition; do not assume identical content for all viewers |
| Activity / FeedPlacement preparation performs writes | Do not simply convert every materializer to read-only |
| Media upload prerequisites | Retain readiness; do not put uploads inside long DB transactions |
| Local composition/URL/companion | Model definition does not imply downlink registration; preserve this freedom |

Application references: Move in `backend/src/moments/moments.service.ts`; `backend/src/replies/reply-rooms.ts`; `backend/src/local-sync/bindings/loaders/{space,activity,feed-order,content}.loader.ts`. Application code is not copied into public examples.

## 5. Verification boundaries

The review covered standalone repository directories, major state machines, persistence schemas, compiler data models and test directories, backend transaction/downlink implementations, and the Oasis paths above. Test files identify intended contracts; they do not mean tests passed during this review. The complete gate was not run, no runtime was modified, and no production database was accessed.

Before fully replacing the old version, every row must correspond to passing Rust/SDK/adapter tests or an explicit breaking change with migration notes. Completing only the first example does not establish a complete rewrite.
