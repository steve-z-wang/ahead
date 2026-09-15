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
2. Scan up to `limits::PULL_CHANGES` (50) invalidation rows after the client's cursor, in cursor order, and check each: same channel, strictly increasing, within the head, a registered model, a canonical identity key, a positive stamp.
3. Group the rows by model, choose the model version to serve, and call that version's loader once with all identities for the model (`load` names the version). Normalize each returned row against the retained contract of that version, not the current schema (identity may be included, nullable fields may be omitted); `null` becomes a delete. Until clients declare the versions they expect ([#91](https://github.com/zanminwang/ahead/issues/91)), the served version is the schema's own version of the model, which is what every generated client of that schema reads; the declaration and the refusal of an undeclared or unretained version are the next step, and no other fallback is implemented.
4. Set the page end: the last row's cursor if the scan was full, otherwise the head, so a client does not stall behind positions that compaction emptied.

**Compaction.** Because a record has one row per channel, notifying it again moves that row to a new cursor and leaves a hole at the old one. A client that already applied the old position sees the record again later with a newer stamp; the stamp makes that harmless.

**Coherence.** Head, scan and load must observe one snapshot. That is a requirement on the application's transaction runner ([Persistence](../persistence.md)); the shipped Prisma runner uses repeatable read.

## 9. Architecture Decisions

**Loader failure isolation — agreed target ([D7](../../../guarantees.md#d-distribution), [#95](https://github.com/zanminwang/ahead/issues/95)).** A failure attributable to a read, including an unsupported model version, is a read error: the loader may throw, and the runtime reports the error to the application. Keep mutation rejection records, but do not introduce a durable loader-failure queue. Unrelated reads continue, including those sharing the same page or channel. An entire channel must not be paused solely because one of its reads failed. Preserve existing local data; a failed load is not a `null` deletion or successful synchronization.

The current implementation groups identities by model and propagates loader errors as request errors. A failed read can be requested again; it does not reject a previously accepted mutation. Background errors must reach the application through an error event or status rather than an unhandled exception. Error reporting and isolation within a multi-record loader call remain to be designed. Failed reads must not advance synchronization evidence or satisfy checkpoints; infrastructure failures may require retrying the request.

## 10. Quality Requirements

- **Every change carries the invalidation row's stamp; rows without a positive stamp are refused** (guarantee D2, server side). Evidence: [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs) `pull_copies_the_row_stamp_into_the_change`, `pull_rejects_rows_without_a_positive_stamp`.
- **Compaction delivers the latest state once; a deletion is an aligned `null`; a full page ends at its last row and the remainder reaches the head.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `compaction materializes latest state; deletion is aligned null`, `50-row pages retain original cursor progression and remainder reaches head`.
- **Loaders receive the requesting channel; head, scan and loader stay coherent under concurrent publication.** Evidence: `loaders receive the channel whose pull requested the rows`, `repeatable-read runner keeps head, scan, and loader coherent across concurrent publication`.
- **A pull names the served model version in `load`, reaches only that version's loader, and normalizes rows with that version's retained contract.** Evidence: [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs) `pull_copies_the_row_stamp_into_the_change`, `pull_normalizes_loader_rows_with_the_retained_contract_of_the_served_version`; [server/tests/runtime.rs](../../../../../crates/server/tests/runtime.rs) `startup_validates_the_retained_model_contracts`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `a pull reaches the loader of the served model version and normalizes rows with that contract`. Executed 2026-09-15: `cargo test --workspace --locked`, `bash integration/persistence/server/run.sh` (50 passed).

Tests read, not executed.

## 11. Risks and Technical Debt

**Problem: a loader failure aborts unrelated reads in the page.** `process_pull` propagates loader errors as request errors without isolating and reporting the affected read, contrary to target D7. No tests establishing D7 have been run for this documentation change. Track the protocol, recovery and cursor design in [#95](https://github.com/zanminwang/ahead/issues/95), alongside malformed-record handling in [#51](https://github.com/zanminwang/ahead/issues/51).

**Accepted limitation (planned changes).** Page size is the protocol's fixed 50 with count-based completion ([#11](https://github.com/zanminwang/ahead/issues/11)); bootstrap is a cursor walk from zero over every model ([#14](https://github.com/zanminwang/ahead/issues/14) proposes snapshots).

**Accepted limitation, worth stating.** The loader is the only visibility control: a loader that ignores `userId` and `channel` exposes every record in the channel to any authenticated user.
