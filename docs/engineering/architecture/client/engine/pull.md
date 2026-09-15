# Pull

## 1. Introduction and Goals

Pull applies what the server says about records. A page arrives for one channel; each change in it is the full state of one record with a *stamp*. Pull must keep two orders straight at once: pages within a channel apply in cursor order, and content for a record applies in stamp order no matter which channel delivered it. That second rule is what lets the same record be shared by several channels, delivered late or twice, and still converge.

## 3. Context and Scope

Pages come from two paths and go through one gate:

| Path | Entry | Result |
| --- | --- | --- |
| HTTP catch-up or WebSocket stream, via the SDKs | `receive_downlink(page, request?)` | a disposition: `covered`, `recover` or `applied`, plus `continues` |
| Direct callers (tests, simulation, `applyPull`) | `apply_page(page)` | an `ApplyReport` with applied, skipped, stale and conflict counts |

Pull owns the ledger: `ahead_subscription` (channel → cursor), `ahead_claim` (which channels currently deliver a record) and `ahead_record` (the stamp last applied per record). It writes records through [Local operations](local-operations/README.md) and calls [Settlement](settlement.md) after every applied change.

## 5. Building Block View

- **Cursor gate.** A page for a channel without a subscription row is dropped whole, so a pull still in flight when the user unsubscribed cannot re-subscribe. A page that ends at or before the current cursor is stale and ignored. A page that starts beyond the cursor is a gap: `receive_downlink` reports `recover` so the caller catches up from the durable cursor; `apply_page` returns an error.
- **Subscription epoch.** The client counts, in memory, how many times each channel's subscription has changed since open, and remembers the pulls it issued (`downlink_request`, and the push lane's `SyncCycle`) with the epoch of their channel. A page answering a pull from an earlier epoch was built against a cursor the resubscribe reset; both paths drop it as stale (`covered` / `stale`) before the gap test, and the next pull from the reset cursor delivers everything. A page the client never requested is judged by the cursor gate alone. Nothing is durable: no request survives a process restart.
- **Stamp comparison.** Per record, content applies only when its stamp is newer than the stored one. Equal stamps are idempotent when the content matches and a diagnostic when it does not. Older content is discarded but still updates the channel's claim, because the channel did deliver the record.
- **Claims.** A claim means "this channel still delivers this record". An upsert adds the channel's claim; a delete removes it. A newer delete removes the record for every channel at once; the remaining claims are the channels whose copy of the delete has not arrived, and a tombstone stamp is kept until the last one does.

Code: `apply_page` and `apply_change` in [client/downlink.rs](../../../../../crates/client/src/downlink.rs); ledger statements in [client/ledger.rs](../../../../../crates/client/src/ledger.rs); dispositions in [client/transport.rs](../../../../../crates/client/src/transport.rs) (`receive_downlink`).

## 6. Runtime View

Applying a page is change by change. Each change that lies beyond the current cursor runs in its own transaction: apply the change under a savepoint, advance the cursor to the change's position, run settlement. If the change cannot be applied (its state fails schema validation), the savepoint is rolled back, the change is counted as skipped, and the cursor still advances. After the last change the cursor moves to the page's end. Skipping rather than failing is inherited from the reference implementation; its consequence is recorded in section 11.

Streamed pages start at the server's current head, while the client's durable cursor may be behind. The connection therefore catches up over HTTP first, and a streamed page that overlaps the catch-up is either `covered` (already past) or applied directly when it starts at or before the cursor and ends beyond it ([Connection / Controller](../connection/controller/README.md)).

## 10. Quality Requirements

- **Pages apply only in cursor order; a stale page is a no-op and the cursor never decreases** (guarantee A2). Evidence: [crates/sim/tests/authority.rs](../../../../../crates/sim/tests/authority.rs) `a2_pages_apply_only_in_cursor_order`; [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs) `original_bad_change_skip_policy_is_retained`; [sqlite/tests/stamp_scenarios.rs](../../../../../crates/sqlite/tests/stamp_scenarios.rs) `redelivered_page_is_a_no_op`.
- **A page from an earlier subscription of the channel is dropped as stale on every incoming path, an unrequested page beyond the cursor is still a gap, and a change to another channel's subscription does not stale the page** (guarantee A2). Evidence: `a2_page_from_a_previous_subscription_is_stale_not_a_gap` (the nine-action reproduction from [#32](https://github.com/zanminwang/ahead/issues/32)); [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs) `page_from_a_previous_subscription_is_stale_not_a_gap` (`apply_page`, `receive_downlink` and `SyncCycle`).
- **Content changes only by record stamp: newer wins, equal is idempotent, older is discarded, delivering channel is irrelevant** (guarantee D2). Evidence: [crates/sim/tests/distribution.rs](../../../../../crates/sim/tests/distribution.rs) `d2_…`; `older_stamp_cannot_regress_newer_authority_but_keeps_claim_bookkeeping`, `equal_stamp_is_idempotent_or_a_diagnostic`.
- **Deletes and tombstones respect stamps and claims; records moving between channels end in the right state** (guarantees D4, D5). Evidence: `channel_claims_and_cross_channel_delete`, `delete_across_channels_keeps_a_tombstone_until_every_claim_confirms`, `move_between_channels_and_back`.
- **Unsubscribing drops the channel's claims and the records nobody else claims; a null load is a delete** (guarantee D6). Evidence: [sqlite/tests/client.rs](../../../../../crates/sqlite/tests/client.rs) `unsubscribe_drops_records_nobody_else_claims_and_restarts_from_zero`; `unsubscribing_settles_its_checkpoint_and_later_pages_are_dropped`.
- **HTTP and WebSocket pages share one cursor policy.** Evidence: [bindings/common/tests/session.rs](../../../../../bindings/common/tests/session.rs) `incoming_overlap_is_identical_with_or_without_http_request_metadata`.

Verified 2026-09-14: `cargo test -p ahead-sim --locked` and `cargo test -p ahead-sqlite --locked --test downlink` passed with the two A2 tests above; the earlier rows were read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation.** The subscription epoch and the issued-pull memory live in the process, bounded to the last 1,024 requests. A page for a pull that was not issued through the client (a direct `apply_page` caller building its own request) is judged by the cursor gate alone and can still see `pull cursor gap`.

**Potential risk: skipped changes are invisible on the SDK path.** *Condition:* a change's state fails validation, for example the server omits a field this client's newer schema requires. *Consequence:* the change is skipped, the cursor moves past it, the record is never retried, and neither SDK can see it happened, because `receive_downlink` returns only the disposition. *Evidence:* the skip branch of `apply_page`; `receive_downlink` discards the report. **To confirm:** whether skipped changes and equal-stamp conflicts should be surfaced or should fail the page.

**Accepted limitation.** Tombstone and stamp rows are retained until every claiming channel confirms; nothing bounds a channel that never does. One transaction per change is a known cost ([#12](https://github.com/zanminwang/ahead/issues/12)) and the reason an atomic page hook ([#17](https://github.com/zanminwang/ahead/issues/17)) needs a design change.
