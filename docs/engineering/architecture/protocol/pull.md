# Pull

Engine behavior: [Client Pull](../client/engine/pull.md), [Server Pull](../server/engine/pull.md).

## 3. Context and Scope

- Request, `POST /sync/pull`: `{clientId, scope, fromCursor}`, where `fromCursor` is the client's durable cursor for the channel (`0` on first contact).
- Response: `{scope, fromCursor, toCursor, changes:[{syncId, model, identity, stamp, state}]}`. The same page shape is streamed over the WebSocket without an envelope ([Subscriptions](subscriptions.md)).
- Errors: `400 request.invalid` when `fromCursor` is ahead of the channel head or the body is malformed; `500 server` for loader defects.

## 5. Building Block View

- **Page rules.** `toCursor ≥ fromCursor`; change cursors strictly increase within `(fromCursor, toCursor]`; every change carries a `state` key (an object, or `null` for a delete) and a positive `stamp`.
- **A change is a whole record.** `state` is the full authoritative state, never a diff.
- **Two counters, two jobs.** `syncId` orders pages within a channel (guarantee A2); `stamp` orders content per record across channels (guarantee D2).
- **Page end.** The server returns at most `limits::PULL_CHANGES` (50) changes. With fewer, `toCursor` is the channel head; with exactly that many, it is the last change's cursor and `PullPage::continues` is true. Clients treat a page that does not continue as "channel drained". More than the limit is refused on decode.

Code: [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`PullRequest`, `PullPage`, `RecordChange`, `limits`).

## 10. Quality Requirements

- A page continues only when it holds exactly the limit, and one change more is refused. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `shared_limits_are_defined_once_and_a_page_continues_only_when_full`.
- A page without a stamp, with a backwards cursor or with an out-of-range counter is refused. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`, `wire_names_remain_legacy_and_counters_are_safe`, `shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries`.
- A full page ends at its last change and the remainder reaches the head. Evidence: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `50-row pages retain original cursor progression and remainder reaches head`.

## 11. Risks and Technical Debt

- **Accepted limitation (planned change):** completion is inferred from the 50-change constant and the page carries no head or client limit. [#11](https://github.com/zanminwang/ahead/issues/11) proposes `limit` and `head` fields; [#14](https://github.com/zanminwang/ahead/issues/14) proposes a separate snapshot request for bootstrap.
