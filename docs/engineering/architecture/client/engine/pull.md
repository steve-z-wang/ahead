# Pull

## 1. Introduction and Goals

Pull applies what the server says about records. A page arrives for one channel; each change in it is the full state of one record with a *stamp*. Pull must keep two orders straight at once: pages within a channel apply in cursor order, and content for a record applies in stamp order no matter which path delivered it. That second rule is what lets the same record be shared by several channels, delivered by a receipt and a page, delivered late or twice, and still converge.

## 3. Context and Scope

Pages come from two paths and go through one gate:

| Path | Entry | Result |
| --- | --- | --- |
| HTTP catch-up or WebSocket stream, via the SDKs | `receive_downlink(page, request?)` | a disposition: `covered`, `recover` or `applied`, plus `continues` |
| Direct callers (tests, simulation, `applyPull`) | `apply_page(page)` | an `ApplyReport` with applied, skipped, stale and conflict counts |

Pull owns the ledger: `ahead_subscription` (channel → cursor) and `ahead_record` (the stamp last applied per record, retained across deletion and unsubscription). It writes records through the authority applier shared with [Settlement](settlement.md) and never touches the mutation queue.

## 5. Building Block View

- **Cursor gate.** A page for a channel without a subscription row is dropped whole, so a pull still in flight when the user unsubscribed cannot re-subscribe. A page that ends at or before the current cursor is stale and ignored. A page that starts beyond the cursor is a gap: `receive_downlink` reports `recover` so the caller catches up from the durable cursor; `apply_page` returns an error.
- **Subscription epoch.** The client counts, in memory, how many times each channel's subscription has changed since open, and remembers the pulls it issued (`downlink_request`, and the push lane's `SyncCycle`) with the epoch of their channel. A page answering a pull from an earlier epoch was built against a cursor the resubscribe reset; both paths drop it as stale (`covered` / `stale`) before the gap test, and the next pull from the reset cursor delivers everything. A page the client never requested is judged by the cursor gate alone. Nothing is durable: no request survives a process restart.
- **Stamp comparison.** Per record, content applies only when its stamp is newer than the stored one. Equal stamps are idempotent when the content matches and a diagnostic when it does not. Older content is discarded; the cursor still advances, because the channel did deliver the page. A newer deletion removes the row and stores its stamp, so older content delivered later cannot resurrect it; declared descendants are deleted locally without rewriting their own stamps.
- **No ownership.** A channel is a delivery path. Nothing records which channels delivered a record, and unsubscribing deletes the subscription row only: content, stamps, before images and pending operations stay, and any other path that delivers a newer version still updates them.

Code: `apply_page` and `apply_change` in [client/downlink.rs](../../../../../crates/client/src/downlink.rs); the applier in [client/authority.rs](../../../../../crates/client/src/authority.rs); ledger statements in [client/ledger.rs](../../../../../crates/client/src/ledger.rs); dispositions in [client/transport.rs](../../../../../crates/client/src/transport.rs) (`receive_downlink`).

## 6. Runtime View

Applying a page is change by change. Each change that lies beyond the current cursor runs in its own transaction: apply the change under a savepoint, advance the cursor to the change's position. If the change cannot be applied (its state fails schema validation), the savepoint is rolled back, the change is counted as skipped, and the cursor still advances. After the last change the cursor moves to the page's end. A page never completes a push; that is the receipt's job ([Settlement](settlement.md)). Skipping rather than failing is inherited from the reference implementation; its consequence is recorded in section 11.

Streamed pages start at the server's current head, while the client's durable cursor may be behind. The connection therefore catches up over HTTP first, and a streamed page that overlaps the catch-up is either `covered` (already past) or applied directly when it starts at or before the cursor and ends beyond it ([Connection / Controller](../connection/controller/README.md)).

## 9. Architecture Decisions

**Channels deliver; they do not own ([#55](https://github.com/zanminwang/ahead/issues/55), [#116](https://github.com/zanminwang/ahead/issues/116)).** The earlier design kept a claim per `(channel, record)` and deleted a record when its last claim was released by an unsubscribe or a confirmed deletion. That made a subscription the owner of local data and forced a delete to wait for every channel's confirmation. Now unsubscribing stops delivery and resets the cursor, and nothing else; retained data is readable but not promised fresh without an update source, and cache eviction is a separate concern ([#61](https://github.com/zanminwang/ahead/issues/61)). Stamp rows are retained for deleted records as the evidence that keeps stale content from resurrecting them; reclaiming them is [#61](https://github.com/zanminwang/ahead/issues/61) too.

**One applier for every path.** A page change and a receipt record are the same authority, and the same function stages them ([Settlement §9](settlement.md#9-architecture-decisions)). Page application stages and replays in one step because its queue state does not change; the channel enters only the conflict diagnostic.

## 10. Quality Requirements

- **Pages apply only in cursor order; a stale page is a no-op and the cursor never decreases; cursors and stamps are independent counters** (guarantee A2, D3). Evidence: [crates/sim/tests/authority.rs](../../../../../crates/sim/tests/authority.rs) `a2_pages_apply_only_in_cursor_order`; [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs) `original_bad_change_skip_policy_is_retained`, `cursor_and_stamp_are_independent`; [sqlite/tests/stamp_scenarios.rs](../../../../../crates/sqlite/tests/stamp_scenarios.rs) `redelivered_page_is_a_no_op`.
- **A page from an earlier subscription of the channel is dropped as stale on every incoming path, an unrequested page beyond the cursor is still a gap, and a change to another channel's subscription does not stale the page** (guarantee A2). Evidence: `a2_page_from_a_previous_subscription_is_stale_not_a_gap` (the nine-action reproduction from [#32](https://github.com/zanminwang/ahead/issues/32)); [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs) `page_from_a_previous_subscription_is_stale_not_a_gap` (`apply_page`, `receive_downlink` and `SyncCycle`), `older_subscription_response_cannot_discard_a_fresh_response`.
- **Content changes only by record stamp: newer wins, equal is idempotent, older is discarded, delivering channel is irrelevant** (guarantee D2). Evidence: [crates/sim/tests/distribution.rs](../../../../../crates/sim/tests/distribution.rs) `d2_…`; `older_stamp_cannot_regress_newer_authority_but_advances_the_cursor`, `equal_stamp_is_idempotent_or_a_diagnostic`, `newer_authority_lands_beneath_pending_edits_and_replays_them`; `delayed_page_from_another_channel_cannot_regress_newer_content`, `move_between_channels_and_back`.
- **Deletes respect stamps, keep their stamp evidence, cascade locally without rewriting descendants' stamps, and survive reopen** (guarantee D5). Evidence: `cross_channel_delete_applies_by_stamp_and_retains_the_stamp`, `delete_cascades_to_descendants_and_keeps_their_stamps`; `delete_keeps_its_stamp_so_stale_content_cannot_resurrect_the_record`, `reopen_preserves_stamps_and_tombstones`.
- **Unsubscribing retains rows, stamps, before images and pending edits, drops later pages for the channel, restarts the cursor, and another channel still updates retained content; the last subscription going away removes nothing; restart keeps it** (guarantee D6). Evidence: `unsubscribing_retains_records_and_later_pages_are_dropped`, `another_channel_updates_retained_content_and_restart_keeps_it`; [sqlite/tests/client.rs](../../../../../crates/sqlite/tests/client.rs) `unsubscribe_retains_records_and_restarts_from_zero`.
- **HTTP and WebSocket pages share one cursor policy.** Evidence: [bindings/common/tests/session.rs](../../../../../bindings/common/tests/session.rs) `incoming_overlap_is_identical_with_or_without_http_request_metadata`.

Verified 2026-09-15: `cargo test -p ahead-sqlite --locked` passed with the suites above.

## 11. Risks and Technical Debt

**Accepted limitation.** The subscription epoch and the issued-pull memory live in the process, bounded to the last 1,024 requests. A page for a pull that was not issued through the client (a direct `apply_page` caller building its own request) is judged by the cursor gate alone and can still see `pull cursor gap`. When old and current subscriptions have outstanding requests with the same channel and cursor, their answers cannot be distinguished on the wire. All matching answers use the cursor gate, so an old answer arriving first cannot cause the fresh answer to be discarded.

**Potential risk: skipped changes are invisible on the SDK path.** *Condition:* a change's state fails validation, for example the server omits a field this client's newer schema requires. *Consequence:* the change is skipped, the cursor moves past it, the record is never retried, and neither SDK can see it happened, because `receive_downlink` returns only the disposition. *Evidence:* the skip branch of `apply_page`; `receive_downlink` discards the report. **To confirm:** whether skipped changes and equal-stamp conflicts should be surfaced or should fail the page ([#51](https://github.com/zanminwang/ahead/issues/51)).

**Accepted limitation.** Stamp rows are never reclaimed, deleted records included, and retained content is never evicted; both are [#61](https://github.com/zanminwang/ahead/issues/61). One transaction per change is a known cost ([#12](https://github.com/zanminwang/ahead/issues/12)) and the reason an atomic page hook ([#17](https://github.com/zanminwang/ahead/issues/17)) needs a design change.
