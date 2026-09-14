# Subscriptions

WebSocket subscription requests and acknowledgments.

Current code: [server/live.rs](../../../../crates/server/src/live.rs) (`decode_subscribe`, `negotiate`, `page_progress`), [client-js/live.mts](../../../../packages/client-js/live.mts), [dart/live.dart](../../../../packages/dart/lib/src/live.dart).

Engine behavior: [Client / Connection / Controller](../client/connection/controller.md), [Server / Connection / Controller](../server/connection/controller.md).

## 3. Context and Scope

- Endpoint: WebSocket upgrade on `/sync/live` with `Authorization: Bearer <token>`; refused with a raw `401`, `500` or `503` before the upgrade.
- Client frame (exactly one): `{"type":"subscribe","scopes":[…]}`; any other key, including `cursors`, is refused (`serde(deny_unknown_fields)`).
- Server acknowledgement: `{"type":"subscribed","scopes":[…],"rejections":[]}` with scopes deduplicated and sorted by UTF-16 order.
- Server pages: [Pull](pull.md) pages without a `type` key, one channel each, starting from the channel head at negotiation time.
- Close codes: `1002` protocol violation (second client frame, malformed subscribe), `1011` server failure, `1001` server shutting down.

## 5. Building Block View

- `decode_subscribe`: `type` must be `subscribe`, scopes non-empty and each non-empty.
- `negotiate`: reads the current head per scope inside the request's database transaction and returns `{scope, fromCursor: head}` pairs; the acknowledgement is built there.
- `page_progress`: guards each streamed page against the subscriber's expected scope and cursor and reports `continues` when it holds 50 changes.
- Clients validate the acknowledgement strictly: same scope set (order-insensitive) and an empty `rejections` array, otherwise the session ends with `invalid live subscription acknowledgement`.

## 6. Runtime View

- Because streaming starts at the head, the client performs an HTTP catch-up from its durable cursor as soon as the acknowledgement arrives; streamed pages that overlap the catch-up are reconciled by the cursor rules in [Client Pull](../client/engine/pull.md).
- Changing the channel set means closing the socket and negotiating again; there is no resubscribe frame.

## 10. Quality Requirements

- [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs) `live_subscribe_requires_one_subscribe_frame_and_normalizes_scopes`, `live_page_progression_uses_wire_cursor_and_fifty_row_boundary`; [server/tests/stamp.rs](../../../../crates/server/tests/stamp.rs) `live_negotiation_establishes_current_heads_and_rejects_cursor_modes`.
- Client side: [live.test.mjs](../../../../integration/bindings/client-js/live.test.mjs) `internal stream establishes listeners and serializes pages…`; [dart/test/live_test.dart](../../../../packages/dart/test/live_test.dart) `WebSocket establishes listeners without cursor catch-up mode`.
- Server transport: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `live transport negotiates, wakes only after commit, reconnects, and cleans up` (second frame closes with `1002`).

## 11. Risks and Technical Debt

- **Confirmed debt: `rejections` is a vestigial field.** Channel authorization was removed in [#22](https://github.com/zanminwang/ahead/issues/22); the server always sends `[]` and both clients fail the handshake if it is non-empty, so the field can never carry information. Evidence: [server/live.rs](../../../../crates/server/src/live.rs) `negotiate`; [client-js/live.mts](../../../../packages/client-js/live.mts).
- **Confirmed limitation: no frame identifies the protocol version or the subscription generation.** A page from a superseded socket is indistinguishable on the wire; clients rely on local epochs to drop it ([Client / Connection / Controller](../client/connection/controller.md)). Related: [#32](https://github.com/zanminwang/ahead/issues/32).
