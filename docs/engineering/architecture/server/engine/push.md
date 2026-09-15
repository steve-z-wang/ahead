# Push

## 1. Introduction and Goals

Server push executes a client's batch exactly once, in order, inside the application's transaction, and answers with a receipt that tells the client which channel positions prove the effects are published.

## 3. Context and Scope

Input: the authenticated owner, the request bytes ([Protocol / Push](../../protocol/push.md)) and a host. Output: the receipt text, also stored for replay; or an error that aborts the transaction (`request.invalid:…`, `owner_mismatch`, `gap`, `overlap`, `mutation_version_unsupported:…`, or any handler or persistence error). The [connection](../connection/transport.md) maps these to HTTP statuses.

## 5. Building Block View

The decoder that turns wire operations into handler arguments is described with the schema rules in [Mutations](../../schema/mutations.md). Everything else is the sequence in section 6.

Code: `process_push` and `decode` in [server/lib.rs](../../../../../crates/server/src/lib.rs).

## 6. Runtime View

1. **Lock the client.** `claim` locks the client's row and returns its owner, last sequence and stored receipt. A different owner is the `client.owner_mismatch` error.
2. **Compare sequences.** The same sequence as last time returns the stored receipt without running anything and without comparing the request body to the one that produced it (guarantee P1; section 9). A smaller one is `overlap`; anything but `last + 1` is `gap` (guarantee P2).
3. **Check versions (current implementation; violates P7).** If any mutation names a known mutation at an unregistered version, the whole batch is refused before any handler runs. The agreed replacement is in section 9.
4. **Run each mutation.** Decode its arguments; a decode failure becomes a rejection with the decode code and no handler call. Otherwise open a savepoint, call the handler, and either roll the savepoint back on a rejection or record the settlement channel, then release it.
5. **Build the receipt.** Read the head of every settlement channel, sort by channel, fill the legacy pair from the first, list the rejections, store it with `saveReceipt` and return it.

All of this happens in the transaction the application opened, so business writes, publications, the client row and the receipt commit or roll back together (current transaction behavior; target P6 narrows operation-level failures to their savepoints). A batch that aborts leaves the client row untouched, and the client's retry is still `last + 1`.

## 9. Architecture Decisions

**Receipt replay is keyed by client identity and batch sequence, not by request body ([#47](https://github.com/zanminwang/ahead/issues/47)).** After the request-envelope and owner checks, `(clientId, batchSequence)` identifies a delivery. A sequence equal to the client's most recently committed one returns the stored receipt as is, even when the new request carries different mutation content; handlers do not run, nothing is published and no subscriber is woken. Only that one sequence replays: older sequences stay `overlap` and skipped ones `gap`. The SDKs retry frozen request bytes (guarantee P4), so a different body under a committed sequence is a client defect, and new intent takes a new sequence. The alternative, storing a hash of the canonical request and refusing a mismatching retry, was rejected: it would add a failure mode with no recovery path for the client and protect against nothing the frozen queue does not already prevent. Nothing hashes the request and the framework tables store no request hash.

**Operation rejection is isolated — agreed target ([#95](https://github.com/zanminwang/ahead/issues/95), [P7](../../../guarantees.md#p-push)).** Batching is internal delivery machinery, not an application-selected all-or-nothing transaction. An unsupported mutation version must become a rejection for that ordinal in the durable receipt, without invoking its handler or refusing unrelated valid mutations. The client retains the rejection through its existing [rejection handling](../../client/engine/settlement.md); lifecycle dependents still follow P5. No automatic fallback to another version is permitted.

Request-envelope, authentication and sequence validation still protect the delivery as a whole. Failures attributable to one handler, publication or checkpoint selection must also be scoped to the affected mutation (P6/A4). The current implementation instead aborts the batch on unexpected errors and checkpoint-selection failure. Classifying operation-level failures versus errors that make the enclosing transaction unusable still needs design; unusable transactions roll back for retry, without manufacturing business rejections for every mutation. Loader reads follow the same [isolation principle](pull.md#9-architecture-decisions), with a separate recovery mechanism.

## 10. Quality Requirements

- **A lost receipt is replayed without a second execution, including under concurrent retries** (guarantee P1). Evidence: [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p1_lost_receipt_retry_executes_once`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `concurrent same-client retry executes once under PostgreSQL lock`.
- **A retry of the latest committed sequence returns the stored receipt whatever its body carries: no handler call, no business write, no publication, no subscriber wake; a concurrent pair with different bodies commits exactly one of them; once the next sequence commits, the earlier one is `overlap` even with its original body** (section 9). Evidence: `push commits business + compacted publication + exact durable receipt together`, `concurrent same-client delivery with different bodies commits at most one under the PostgreSQL lock`, `fresh framework tables omit request_hash; a table that still carries the column keeps replaying receipts`.
- **Gaps and overlaps are refused with stable codes and nothing executes** (guarantee P2). Evidence: `p2_contiguous_sequence_and_server_refuses_gap_and_overlap`; `push commits business + compacted publication + exact durable receipt together`.
- **P7 requires an unsupported version to reject only that mutation. Current coverage instead asserts whole-batch abort and must change; invalid bodies already settle as rejections with no checkpoints.** Existing evidence (not proof of P7): `unsupported versions abort before handlers, invalid bodies settle with empty checkpoints`.
- **Current coverage asserts batch rollback and retry on a handler failure; it does not establish the revised operation-level isolation in P6.** Evidence: `p6_handler_failure_aborts_the_batch_and_the_client_retries`.

Verified 2026-09-15 by `bash integration/persistence/server/run.sh` (50 tests) and `cargo test --workspace --locked`.

## 11. Risks and Technical Debt

**Problem: unsupported mutation versions abort unrelated work.** The preflight loop in `process_push` returns before any handler runs, contradicting P7. Replace it with per-mutation rejection and add a mixed-version batch regression that proves valid unrelated work commits, the unsupported handler never runs, and retries replay the same receipt. Tracked in [#95](https://github.com/zanminwang/ahead/issues/95); not implemented or tested in this documentation change.

**Accepted limitation.** A client id is bound to the first owner that used it; a later push from another user with the same client id is `client.owner_mismatch` (HTTP 403) and there is no reassignment. Relevant to shared devices.

**Accepted limitation (planned change).** The only size bound is the protocol's 20-mutation cap and the HTTP body limit; a server-side byte cap is part of [#11](https://github.com/zanminwang/ahead/issues/11). The lack of a client-side escape from a batch the server keeps failing is recorded under [Batching](../../client/engine/push/batching.md).
