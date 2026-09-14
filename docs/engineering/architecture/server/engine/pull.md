# Pull

Find changes by channel cursor and invoke loaders to return records.

Current code: [server/lib.rs](../../../../../crates/server/src/lib.rs) (`process_pull`, `head`); live variant in [server/live.rs](../../../../../crates/server/src/live.rs) (`pull`, `page_progress`).

## 1. Introduction and Goals

- Answer "what changed in this channel after cursor X" with full authoritative records, loaded by the application under its own visibility rules, in a page the client can apply in order.

## 3. Context and Scope

- Input: owner, [PullRequest](../../protocol/pull.md) bytes (HTTP) or `(scope, fromCursor)` (live, with `clientId` `"live"`), a `Host`.
- Output: page text, or an error (`request.invalid:cursor ahead of head`, `invalid scan size`, `invalid invalidation order`, `unregistered loader`, `noncanonical identity`, `invalid stamp`, `misaligned loader result`, state normalization errors).
- Callers: `api.pull` and `api.pullLive` in [server/index.mts](../../../../../packages/server/index.mts), each inside `database.transaction`.

## 5. Building Block View

- `head(channel)` first; `fromCursor > head` is refused so a client cannot skip ahead.
- `scan {channel, after, limit: 50}` returns invalidation rows `{channel, cursor, model, identity, identityKey, stamp}` ordered by cursor; each row is validated: same channel, strictly increasing cursor not beyond head, registered loader (model), canonical `identityKey`, positive stamp.
- Loading: rows are grouped by model and one `load {model, identities, owner, channel}` call is made per model; the result must be an array aligned with the identities; each non-null row passes `normalize_state` (identity may be present, nullable fields may be omitted); `null` becomes `state: null`.
- Page end: `toCursor` is the last row's cursor when the scan returned 50 rows, otherwise the head, so trailing compacted positions do not stall the client.
- Live pull: `page_progress` re-validates scope and `fromCursor` and reports `continues` for a full page ([Server / Connection / Controller](../connection/controller.md)).

## 6. Runtime View

- Compaction: the invalidation table keeps one row per `(channel, model, identityKey)` at the latest cursor, so a record notified twice appears once, at its newest position; earlier cursor positions become holes. A client that already applied the older position sees the record again later and dedupes by stamp.
- Coherence depends on the database transaction: `head`, `scan` and `load` must observe one snapshot ([Persistence](../persistence.md)).

## 10. Quality Requirements

- [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs) `pull_copies_the_row_stamp_into_the_change`, `pull_rejects_rows_without_a_positive_stamp`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `compaction materializes latest state; deletion is aligned null`, `50-row pages retain original cursor progression and remainder reaches head`, `loaders receive the channel whose pull requested the rows`, `loader defects abort pull instead of silently advancing its cursor`, `repeatable-read runner keeps head, scan, and loader coherent across concurrent publication`.

## 11. Risks and Technical Debt

- **Confirmed limitation: page size 50 is fixed and count-based.** Neither a client `limit` nor a `head` field exists; the client's completion rule depends on this constant. Open: [#11](https://github.com/zanminwang/ahead/issues/11).
- **Confirmed limitation: no snapshot path.** Bootstrap is a cursor walk from 0 over every model in the channel; [#14](https://github.com/zanminwang/ahead/issues/14) proposes a per-model snapshot request on the same tables.
- **Potential risk: the loader is the only visibility control.** Every pull for a channel calls the loader with `channel` and `userId`; a loader that ignores them exposes every record in the channel to any authenticated user. This is the documented design (guarantee N5); noted because nothing in the framework fails safe.
- Loader fan-out per page and per subscriber is a cost noted under [Server / Connection / Controller](../connection/controller.md).
