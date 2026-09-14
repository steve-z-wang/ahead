# Pull

Apply server changes and advance cursors.

Current code: [client/downlink.rs](../../../../../crates/client/src/downlink.rs) (`apply_page`, `apply_change`), [client/ledger.rs](../../../../../crates/client/src/ledger.rs) (record stamps, claims, subscriptions); incoming-page dispositions in [client/transport.rs](../../../../../crates/client/src/transport.rs) (`receive_downlink`, `downlink_request`).

## 1. Introduction and Goals

- Apply pages per channel in cursor order and record content per record in stamp order, so the same record delivered through several channels, in any order, converges.

## 3. Context and Scope

- Input: a validated [PullPage](../../protocol/pull.md); optionally the `PullRequest` it answers (HTTP path).
- Output: an `ApplyReport {applied, skipped, stale, conflicts, diagnostics}` from `apply_page`, or a `DownlinkProgress {disposition: covered|recover|applied, continues}` from `receive_downlink`.
- Ledger tables: `ahead_subscription (channel, cursor)`, `ahead_claim (channel, model, identity)`, `ahead_record (model, identity, stamp)`.
- Callers: `RuntimeHost` `downlinkPage` and `pull` commands ([SDKs / Bindings](../../sdks/bindings.md)); `SyncCycle::complete`.

## 5. Building Block View

- Subscription: `set_channel(channel, true)` inserts a cursor row at 0 if absent; `false` runs `unsubscribe` ([Settlement](settlement.md)). A page for a channel without a row is dropped whole (`stale`), so an in-flight pull cannot re-subscribe.
- Page gate (`apply_page`): `to_cursor ≤ cursor` → stale, nothing written; `from_cursor > cursor` → error `pull cursor gap`; otherwise each change with `cursor > current` is applied in its own write transaction under a savepoint: a failing change is rolled back and counted as `skipped`, the cursor still advances to that change's cursor, and `settle` runs; finally the cursor moves to `to_cursor`.
- `receive_downlink`: validates the page, checks it matches the request when one is given, refuses a full page that did not advance, then classifies: not subscribed or `to_cursor ≤ cursor` → `covered`; `from_cursor > cursor` → `recover` (caller must catch up from the durable cursor); otherwise `apply_page` → `applied`. `continues` is `changes.len() == 50`.
- `apply_change`: compare the incoming stamp with `ahead_record`; newer content replaces authority (`set_authority`), adds the channel's claim and stores the stamp; a newer delete removes the record regardless of remaining claims, releases this channel's claim and keeps a tombstone stamp while other claims remain; older content only maintains claims; an equal stamp with different content is counted as a `conflict` with a diagnostic and leaves local content alone.
- Claims answer "which channels still deliver this record"; a record with no claims, no row and no pending mutation has its stamp row dropped.

## 6. Runtime View

- Streamed pages start at the server head; the catch-up from the durable cursor and the stream can overlap, which the gate resolves (`covered`) or applies directly when `from_cursor ≤ cursor < to_cursor` ([Connection / Controller](../connection/controller.md)).
- Each applied change may satisfy a checkpoint, so `settle` runs after every change ([Settlement](settlement.md)).

## 10. Quality Requirements

- A2, D2–D6: [sqlite/tests/downlink.rs](../../../../../crates/sqlite/tests/downlink.rs), [sqlite/tests/stamp_scenarios.rs](../../../../../crates/sqlite/tests/stamp_scenarios.rs), [crates/sim/tests/authority.rs](../../../../../crates/sim/tests/authority.rs), [crates/sim/tests/distribution.rs](../../../../../crates/sim/tests/distribution.rs).
- Dispositions: [bindings/common/tests/session.rs](../../../../../bindings/common/tests/session.rs) `incoming_pages_share_cursor_policy_and_do_not_overwrite_push_cycle`, `incoming_overlap_is_identical_with_or_without_http_request_metadata`.

## 11. Risks and Technical Debt

- **Confirmed bug: a page from a previous subscription of the same channel is a hard error in `apply_page`.** After unsubscribe and resubscribe the cursor is 0, so a page built against the old cursor hits `pull cursor gap`. The SDK live path avoids it because `receive_downlink` maps the case to `recover` and the controller drops stale sessions; direct `apply_page` callers (`applyPull`, the simulation) reproduce it. Evidence: [client/downlink.rs](../../../../../crates/client/src/downlink.rs) `apply_page`. Open: [#32](https://github.com/zanminwang/ahead/issues/32).
- **Potential risk: skipped changes are invisible on the SDK path.** A change whose state fails `validate_state` (for example, the server omits a field this client's schema requires) is skipped and the cursor advances past it, so that record is never retried; `receive_downlink` discards the report and the binding returns only the disposition, so neither SDK can observe `skipped` or `conflicts`. Evidence: [client/downlink.rs](../../../../../crates/client/src/downlink.rs) lines around `Err(_) => rollback_to("change")`, [client/transport.rs](../../../../../crates/client/src/transport.rs) `receive_downlink`. The skip policy is inherited from the reference implementation; whether to surface or fail needs deciding.
- **Confirmed debt: one transaction per change.** A 50-change page runs up to 50 commits, each bumping the generation and re-running `settle`. Evidence: `apply_page`. Cost center in [#12](https://github.com/zanminwang/ahead/issues/12); the atomic page transaction is also what [#17](https://github.com/zanminwang/ahead/issues/17) needs.
- **Confirmed limitation: tombstones and stamps are never pruned** (guarantee N1). `ahead_record` rows for deleted records remain until every claiming channel confirms; nothing bounds a channel that never does.
