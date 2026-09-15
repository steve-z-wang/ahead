# Pull

## 1. Introduction and Goals

Server pull answers "what changed in this channel after position X" with whole records, loaded by the application under its own visibility rules, in a page the client can apply in order.

## 3. Context and Scope

Input: the owner, a [pull request](../../protocol/pull.md) (or, for the live stream, a channel and cursor with client id `live`) and a host. Output: one page, or an error that aborts the request (cursor ahead of head, malformed invalidation rows, unregistered model, non-canonical identity, missing stamp, misaligned or malformed loader result). Both the HTTP route and the live drain call it ([Server / Connection / Controller](../connection/controller.md)).

## 5. Building Block View

Pull reads two things: the **invalidation table**, which holds one row per `(channel, model, record)` at the record's latest position in that channel with its stamp, and the **loaders**, which supply current content. It writes nothing.

Code: `process_pull` in [server/lib.rs](../../../../../crates/server/src/lib.rs); the live wrapper in [server/live.rs](../../../../../crates/server/src/live.rs).

## 6. Runtime View

1. Read the channel head; a request beyond it is refused, so a client cannot skip ahead.
2. Scan up to 50 invalidation rows after the client's cursor, in cursor order, and check each: same channel, strictly increasing, within the head, a registered model, a canonical identity key, a positive stamp.
3. Group the rows by model and call each loader once with all identities for that model. Normalize each returned row (identity may be included, nullable fields may be omitted); `null` becomes a delete.
4. Set the page end: the last row's cursor if the scan was full, otherwise the head, so a client does not stall behind positions that compaction emptied.

**Compaction.** Because a record has one row per channel, notifying it again moves that row to a new cursor and leaves a hole at the old one. A client that already applied the old position sees the record again later with a newer stamp; the stamp makes that harmless.

**Coherence.** Head, scan and load must observe one snapshot. That is a requirement on the application's transaction runner ([Persistence](../persistence.md)); the shipped Prisma runner uses repeatable read.

## 10. Quality Requirements

- **Every change carries the invalidation row's stamp; rows without a positive stamp are refused** (guarantee D2, server side). Evidence: [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs) `pull_copies_the_row_stamp_into_the_change`, `pull_rejects_rows_without_a_positive_stamp`.
- **Compaction delivers the latest state once; a deletion is an aligned `null`; a full page ends at its last row and the remainder reaches the head.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `compaction materializes latest state; deletion is aligned null`, `50-row pages retain original cursor progression and remainder reaches head`.
- **Loaders receive the requesting channel; head, scan and loader stay coherent under concurrent publication.** Evidence: `loaders receive the channel whose pull requested the rows`, `repeatable-read runner keeps head, scan, and loader coherent across concurrent publication`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation (planned changes).** Page size is a fixed 50 with count-based completion ([#11](https://github.com/zanminwang/ahead/issues/11)); bootstrap is a cursor walk from zero over every model ([#14](https://github.com/zanminwang/ahead/issues/14) proposes snapshots).

**Accepted limitation, worth stating.** The loader is the only visibility control: a loader that ignores `userId` and `channel` exposes every record in the channel to any authenticated user (guarantee N5).
