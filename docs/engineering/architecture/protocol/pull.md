# Pull

Requests, record changes, cursors and pagination.

Current code: [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`PullRequest`, `PullPage`, `RecordChange`).

Engine behavior: [Client Pull](../client/engine/pull.md), [Server Pull](../server/engine/pull.md).

## 3. Context and Scope

- Request, `POST /sync/pull`: `{clientId, scope, fromCursor}`; `fromCursor` is the client's durable cursor for that channel (`0` on first contact).
- Response: a page `{scope, fromCursor, toCursor, changes:[{syncId, model, identity, stamp, state}]}`. The same page shape is streamed over the WebSocket without any envelope ([Subscriptions](subscriptions.md)).
- Errors: `400 request.invalid` when `fromCursor` is ahead of the channel head or the body is malformed; `500 server` for loader defects.

## 5. Building Block View

- `PullRequest`: `clientId` non-blank, `scope` a string, `fromCursor` a counter (zero allowed).
- `PullPage::decode` insists that every change carries both a `state` key (an object, or `null` for a delete) and a `stamp` key, then `validate`: `toCursor ≥ fromCursor`; change cursors strictly increase, lie in `(fromCursor, toCursor]`; `stamp` is a positive counter; `identity` is an object.
- A change is the full authoritative state of one record (no diffs); `state: null` is a delete or a loader `null` ([Server Pull](../server/engine/pull.md)).
- Page end: the server returns up to 50 changes; with fewer than 50, `toCursor` is the channel head; with exactly 50 it is the last change's cursor. Clients treat fewer than 50 as "channel drained".
- Two numbers, two jobs: `syncId` orders pages per channel; `stamp` orders content per record across channels (guarantees A2 and D2).

## 10. Quality Requirements

- [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `wire_names_remain_legacy_and_counters_are_safe`, `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected` (page without stamp refused), `shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries`.
- Server side of the 50-row rule: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `50-row pages retain original cursor progression and remainder reaches head`.

## 11. Risks and Technical Debt

- **Confirmed limitation: completion is count-based and the page carries no head.** A client cannot tell "page full" from "at head" except by the shared constant, and cannot ask for a smaller page. Evidence: [client/transport.rs](../../../../crates/client/src/transport.rs) `continues`, [server/lib.rs](../../../../crates/server/src/lib.rs) `to_cursor`. Open: [#11](https://github.com/zanminwang/ahead/issues/11).
- **Confirmed limitation: no snapshot request.** Bootstrap pulls the whole channel in cursor order; per-model load strategies are proposed in [#14](https://github.com/zanminwang/ahead/issues/14) and would add a second request type.
