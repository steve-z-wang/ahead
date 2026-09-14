# Push

Validate and deduplicate mutation batches, invoke handlers and produce receipts.

Current code: [server/lib.rs](../../../../../crates/server/src/lib.rs) (`process_push`, `decode`, `Config::descriptor`, `valid_code`, `machine_name`).

## 1. Introduction and Goals

- Execute each mutation of a batch at most once, in order, inside the application's transaction, and answer with a receipt that tells the client which channel positions prove the effects have been published.

## 3. Context and Scope

- Input: the owner (authenticated user id), the raw request bytes ([Protocol / Push](../../protocol/push.md)), a `Host`.
- Output: the receipt text, also stored through `saveReceipt`; or an error string that aborts the transaction (`request.invalid:…`, `owner_mismatch`, `gap`, `overlap`, `mutation_version_unsupported:<ordinal>:<name>:<version>`, `storage client mismatch`, handler or persistence errors).
- Callers: `api.push` in [server/index.mts](../../../../../packages/server/index.mts) via the Node binding, inside `database.transaction`.

## 5. Building Block View

- Order of work: `principal` → `PushRequest::decode` → `claim {owner, clientId}` (persistence locks the client row and returns `{clientId, owner, sequence, receipt}`) → owner check → sequence check (`== last` returns the stored receipt without running anything; `< last` is `overlap`; `≠ last+1` is `gap`) → version pre-check over every mutation (a known name with an unregistered version aborts before any handler) → per mutation: `decode` arguments (failure becomes a rejection with the decode code and no savepoint), `savepoint`, `handle`, on `{rejection}` validate the code and `rollback`, otherwise record the settlement channel, `release` → one `head` per distinct channel → receipt sorted by channel (UTF-16), legacy pair from the first checkpoint or `""`/`0` → `saveReceipt`.
- Rejection codes: `mutation.invalid` (unknown mutation, wrong shape, missing required create field, empty patch), `<snake_name>.not_allowed` (known field outside `allowedPatchFields`, including fields the current schema no longer has but `knownFields` remembers), `<snake_name>.invalid` (binding mismatch), handler codes validated by `valid_code`.
- Everything runs in the caller's transaction: business writes, publications, the client row and the receipt commit together or not at all (guarantee P6).

## 6. Runtime View

- A retry after a lost receipt carries the same `batchSequence`; the locked client row returns the stored receipt and no handler runs (guarantee P1).
- A batch that aborts leaves the client row untouched, so the next attempt is still `last+1`.

## 10. Quality Requirements

- P1, P2, P6, C4, A4: [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p1_…`, `p2_…`, `p6_…`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `push commits business + compacted publication + exact durable receipt together`, `concurrent same-client retry executes once under PostgreSQL lock`, `unsupported versions abort before handlers, invalid bodies settle with empty checkpoints`, `explicit rejection rolls back only mutation and its publication`, `an all-rejected batch settles with no checkpoints`; [server/tests/runtime.rs](../../../../../crates/server/tests/runtime.rs).

## 11. Risks and Technical Debt

- **Confirmed contradiction with guarantee C1: deduplication ignores the request body.** A retry with the same `batchSequence` and a different body returns the stored receipt; `PushRequest::semantic_hash` is never called outside core tests and the `request_hash` column in [migration.sql](../../../../../packages/persistence-prisma/migration.sql) is never written. The test suite asserts the current behavior (`push('dedup',1,[mutation(1,'changed')])` returns the cached receipt). Evidence: `process_push`; [persistence-prisma/index.mts](../../../../../packages/persistence-prisma/index.mts) `claim`, `saveReceipt`. The C1 wording is corrected in [guarantees](../../../guarantees.md); whether to enforce the hash needs deciding.
- **Confirmed limitation: no server-side byte cap; the count cap is a protocol constant.** `PushRequest::decode` enforces 20 mutations; the only size bound is the HTTP layer's 1 MiB body. Open: [#11](https://github.com/zanminwang/ahead/issues/11).
- **Confirmed limitation: a client id is bound to its first owner forever.** `claim` inserts `(client_id, owner_id)` once; a later push from another authenticated user with the same client id is `owner_mismatch` (HTTP 403 `client.owner_mismatch`) with no reassignment path. Evidence: [persistence-prisma/index.mts](../../../../../packages/persistence-prisma/index.mts) `claim`. Relevant to shared devices; no issue.
- Abort-and-retry with no client escape hatch is owned by [Client Push](../../client/engine/push/README.md).
