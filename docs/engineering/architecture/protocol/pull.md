# Pull

Engine behavior: [Client Pull](../client/engine/pull.md), [Server Pull](../server/engine/pull.md).

## 3. Context and Scope

- Request, `POST /sync/pull`: `{clientId, scope, fromCursor, models}`, where `fromCursor` is the client's durable cursor for the channel (`0` on first contact) and `models` declares the read contracts the client expects, `{"Task": 2, "Note": 1}`: every model of its schema with the version its generated types read ([#91](https://github.com/zanminwang/ahead/issues/91)). The same declaration goes on the subscribe frame ([Subscriptions](subscriptions.md)), so catch-up and live pages are served alike.
- Response: `{scope, fromCursor, toCursor, changes:[{syncId, model, identity, stamp, state}]}`. The same page shape is streamed over the WebSocket without an envelope ([Subscriptions](subscriptions.md)).
- Errors: `400 request.invalid` when `fromCursor` is ahead of the channel head, `models` is missing or malformed, or the body is malformed; `409 model_version_unsupported` with `{model, version}` when a declared model is unknown or its version is not retained, and with `{model}` when a page holds a model the client did not declare (refused whole until per-read isolation, [#95](https://github.com/zanminwang/ahead/issues/95)); `500 server` for loader defects.

## 5. Building Block View

- **Page rules.** `toCursor ≥ fromCursor`; change cursors strictly increase within `(fromCursor, toCursor]`; every change carries a `state` key (an object, or `null` for a delete) and a positive `stamp`.
- **A change is a whole record.** `state` is the full authoritative state, never a diff, shaped by the declared version of its model; the same record and the same `stamp` reach a v1 client in the v1 shape and a v2 client in the v2 shape.
- **Two counters, two jobs.** `syncId` orders pages within a channel (guarantee A2); `stamp` orders content per record across channels (guarantee D2).
- **Page end.** The server returns at most `limits::PULL_CHANGES` (50) changes. With fewer, `toCursor` is the channel head; with exactly that many, it is the last change's cursor and `PullPage::continues` is true. Clients treat a page that does not continue as "channel drained". More than the limit is refused on decode.

Code: [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`PullRequest`, `PullPage`, `RecordChange`, `limits`).

## 10. Quality Requirements

- A page continues only when it holds exactly the limit, and one change more is refused. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `shared_limits_are_defined_once_and_a_page_continues_only_when_full`.
- A page without a stamp, with a backwards cursor or with an out-of-range counter is refused. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`, `wire_names_remain_legacy_and_counters_are_safe`, `shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries`.
- A pull declares the read contracts on both paths and a missing or bad declaration is refused; a declared version selects the loader and the contract. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `pull_and_subscribe_declare_the_read_contracts_and_refuse_a_missing_or_bad_declaration`, [live-messages.json](../../../../fixtures/protocol/live-messages.json); [server/tests/stamp.rs](../../../../crates/server/tests/stamp.rs) `pull_normalizes_loader_rows_with_the_retained_contract_of_the_served_version`, `a_page_holding_a_model_the_client_did_not_declare_is_refused_whole`; [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `a pull reaches the loader of the declared model version and normalizes rows with that contract`, `HTTP maps engine codes to statuses`.
- A full page ends at its last change and the remainder reaches the head. Evidence: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `50-row pages retain original cursor progression and remainder reaches head`.

## 11. Risks and Technical Debt

- **Accepted limitation (planned change):** completion is inferred from the 50-change constant and the page carries no head or client limit. [#11](https://github.com/zanminwang/ahead/issues/11) proposes `limit` and `head` fields; [#14](https://github.com/zanminwang/ahead/issues/14) proposes a separate snapshot request for bootstrap.
