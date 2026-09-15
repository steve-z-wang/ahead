# Subscriptions

Engine behavior: [Client / Connection / Controller](../client/connection/controller/README.md), [Server / Connection / Controller](../server/connection/controller.md).

## 3. Context and Scope

- Endpoint: WebSocket upgrade on `/sync/live` with `Authorization: Bearer <token>`; refused with a raw `401`, `500` or `503` before the upgrade.
- Client frame, exactly one: `{"type":"subscribe","scopes":[…],"models":{…}}`. `models` is the client's read-contract declaration, the same object as on a [pull](pull.md) and required. Any other key, including `cursors`, is refused.
- Server acknowledgement: `{"type":"subscribed","scopes":[…],"rejections":[]}` with scopes deduplicated and sorted by UTF-16 order.
- Server pages: [Pull](pull.md) pages without a `type` key, one channel each, starting at the channel head as of negotiation.
- Close codes: `1002` protocol violation (a second client frame, a malformed subscribe, or a declaration the server refuses, with reason `model_version_unsupported`), `1011` server failure, `1001` server shutting down.

## 5. Building Block View

- Scopes must be non-empty strings and at least one is required. `SubscribeRequest` normalizes them (deduplicated, UTF-16 order) and `SubscriptionAck` carries the same normalized list; `LiveMessage` tells an acknowledgement (it has a `type`) from a page (it has none).
- The declaration is checked at the handshake (every declared model known, every version retained) and kept for the session: every page it streams is pulled at those versions. The acknowledgement is produced inside the negotiating transaction, which also reads each channel's head; that head is where streaming starts.
- Clients validate the acknowledgement strictly: the same scope set and an empty `rejections` array, otherwise the session ends.
- Each streamed page is checked against the subscriber's expected scope and cursor before it is sent.

Code: [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`SubscribeRequest`, `SubscriptionAck`, `LiveMessage`); the server decodes and answers through them in [server/live.rs](../../../../crates/server/src/live.rs). The clients still check the acknowledgement themselves in [client-js/live.mts](../../../../packages/client-js/live.mts) and [dart/live.dart](../../../../packages/dart/lib/src/live.dart) until the live session moves to Rust ([#58](https://github.com/zanminwang/ahead/issues/58)).

## 6. Runtime View

Because streaming starts at the head, the client catches up over HTTP from its durable cursor as soon as the acknowledgement arrives; overlapping pages are reconciled by the cursor rules in [Client Pull](../client/engine/pull.md). Changing the channel set means closing the socket and negotiating again; there is no resubscribe frame.

## 10. Quality Requirements

- Subscribe and acknowledgement frames decode, normalize and refuse as the shared fixture says; a frame is either an acknowledgement or a page. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `live_frames_decode_as_acknowledgement_or_page_and_scopes_normalize` over [fixtures/protocol/live-messages.json](../../../../fixtures/protocol/live-messages.json).
- The frame carries the declaration and a frame without it, or with an unretained version, is refused at the handshake; a v1 and a v2 subscriber of the same channel receive their own record shapes. Evidence: [server/tests/stamp.rs](../../../../crates/server/tests/stamp.rs) `live_negotiation_establishes_current_heads_and_rejects_cursor_modes`; [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `the live stream serves the declared model version and refuses an unretained one at the handshake`; the client builds the frame from its schema: [bindings/common/tests/session.rs](../../../../bindings/common/tests/session.rs), [dart/test/live_test.dart](../../../../packages/dart/test/live_test.dart).
- Only one subscribe frame is accepted, scopes are normalized, and a subscribe carrying `cursors` is refused. Evidence: [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs) `live_subscribe_requires_one_subscribe_frame_and_normalizes_scopes`; [server/tests/stamp.rs](../../../../crates/server/tests/stamp.rs) `live_negotiation_establishes_current_heads_and_rejects_cursor_modes`.
- Both clients complete the handshake and receive pages; a second client frame closes the socket with `1002`. Evidence: [live.test.mjs](../../../../integration/bindings/client-js/live.test.mjs), [dart/test/live_test.dart](../../../../packages/dart/test/live_test.dart), [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `live transport negotiates, wakes only after commit, reconnects, and cleans up`.

## 11. Risks and Technical Debt

- **Decision needed ([#63](https://github.com/zanminwang/ahead/issues/63)): whether to retire the acknowledgement's `rejections`.** It is vestigial since channel authorization was removed in [#22](https://github.com/zanminwang/ahead/issues/22). Inventory (2026-09-14, code inspection): the only emitter is `negotiate` in [server/live.rs](../../../../crates/server/src/live.rs), always `[]`; the consumers are the two SDK handshakes, which end the session unless the field is an empty array ([client-js/live.mts](../../../../packages/client-js/live.mts), [dart/live.dart](../../../../packages/dart/lib/src/live.dart)); test fixtures echo it. Retiring it needs the SDKs to accept an absent field before the server stops sending it, or an old client would refuse a new server's acknowledgement. Waits for the decision.
