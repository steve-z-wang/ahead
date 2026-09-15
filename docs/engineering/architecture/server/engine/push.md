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
2. **Compare sequences.** The same sequence as last time returns the stored receipt without running anything (guarantee P1). A smaller one is `overlap`; anything but `last + 1` is `gap` (guarantee P2).
3. **Check versions.** If any mutation names a known mutation at an unregistered version, the whole batch is refused before any handler runs.
4. **Run each mutation.** Decode its arguments; a decode failure becomes a rejection with the decode code and no handler call. Otherwise open a savepoint, call the handler, and either roll the savepoint back on a rejection or record the settlement channel, then release it.
5. **Build the receipt.** Read the head of every settlement channel, sort by channel, fill the legacy pair from the first, list the rejections, store it with `saveReceipt` and return it.

All of this happens in the transaction the application opened, so business writes, publications, the client row and the receipt commit or roll back together (guarantee P6). A batch that aborts leaves the client row untouched, and the client's retry is still `last + 1`.

## 10. Quality Requirements

- **A lost receipt is replayed without a second execution, including under concurrent retries** (guarantee P1). Evidence: [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p1_lost_receipt_retry_executes_once`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `concurrent same-client retry executes once under PostgreSQL lock`.
- **Gaps and overlaps are refused with stable codes and nothing executes** (guarantee P2). Evidence: `p2_contiguous_sequence_and_server_refuses_gap_and_overlap`; `push commits business + compacted publication + exact durable receipt together`.
- **An unsupported version aborts before handlers; an invalid body settles as a rejection with no checkpoints**. Evidence: `unsupported versions abort before handlers, invalid bodies settle with empty checkpoints`.
- **A handler failure aborts the batch and the client retries the same bytes** (guarantee P6). Evidence: `p6_handler_failure_aborts_the_batch_and_the_client_retries`.

Tests read, not executed.

## 11. Risks and Technical Debt

**To confirm: whether retries must validate request bodies.** *Condition:* a client retries a batch sequence with a different body. *Consequence:* the stored receipt is returned; `PushRequest::semantic_hash` is never called outside core tests and the `request_hash` column in [migration.sql](../../../../../packages/persistence-prisma/migration.sql) is never written. The persistence test asserts the current behavior. *Status:* codec hash tests do not establish server enforcement. Whether retries should require matching request hashes remains a contract decision owned here.

**Accepted limitation.** A client id is bound to the first owner that used it; a later push from another user with the same client id is `client.owner_mismatch` (HTTP 403) and there is no reassignment. Relevant to shared devices.

**Accepted limitation (planned change).** The only size bound is the protocol's 20-mutation cap and the HTTP body limit; a server-side byte cap is part of [#11](https://github.com/zanminwang/ahead/issues/11). The lack of a client-side escape from a batch the server keeps failing is recorded under [Batching](../../client/engine/push/batching.md).
