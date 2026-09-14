# Controller

Encode and decode protocol messages; coordinate connection, subscription, catch-up, cancellation, reconnect and authentication refresh.

Current code: scheduling in [client/connection.rs](../../../../../crates/client/src/connection.rs) (`ConnectionDriver`) and [client/transport.rs](../../../../../crates/client/src/transport.rs) (`SyncCycle`, `downlink_request`, `receive_downlink`); host loops in [client-js/connection.mts](../../../../../packages/client-js/connection.mts) (`startConnection`) and [dart/connection.dart](../../../../../packages/dart/lib/src/connection.dart) (`RuntimeConnection`); session orchestration in [client-js/index.mts](../../../../../packages/client-js/index.mts) (`connect`, `#runSync`) and [dart/client.dart](../../../../../packages/dart/lib/src/client.dart) (`connect`, `_runSync`).

## 1. Introduction and Goals

- Decide when to push, when to stream, when to catch up and when to retry, with Rust owning the decisions and the host owning clocks, timers and sockets.

## 3. Context and Scope

- Interface to Rust: `connection` commands per lane (`push`, `live`) with events `start`, `stop`, `pause`, `resume`, `wake`, `success`, `failure`, `next` → `{type: idle|sync|wait, millis?}`; `startSync {pushOnly}` / `next` / `complete` for the push cycle; `downlinkRequest {scope}` → request body; `downlinkPage {page, request?}` → `{disposition, continues}`; `status` for the channel list ([SDKs / Bindings](../../sdks/bindings.md)).
- Interface to the host: `Client.connect(server, {onError, refreshAuth})` → `{pause, resume, wake, close}`.
- Dependencies: [Transport](transport.md) for bytes; [Engine / Push](../engine/push/README.md), [Engine / Pull](../engine/pull.md) through the commands above.

## 5. Building Block View

- `ConnectionDriver` (Rust, one per lane): `start` marks dirty; `next` returns `Sync` when running, unpaused, not in flight and dirty, `Wait` while a retry is due, else `Idle`; `complete(success)` resets the backoff or schedules the next attempt at `250 ms · 2^attempt` capped at 30 s with ±20 % jitter from host entropy and marks dirty; `wake` marks dirty without interrupting an in-flight cycle.
- `SyncCycle` (Rust): `next` returns the in-flight action, else a `push` action from `freeze`, else (unless `push_only`) one `pull` action per subscribed channel not yet completed; `complete` acknowledges a receipt or applies a page and marks the channel complete when the page had fewer than 50 changes. `connect` always starts the cycle `pushOnly`, so HTTP pulls through `SyncCycle` are reached only by tests and the internal `syncProtocol` fixture.
- Host loop (`startConnection` / `RuntimeConnection`): poll `next`; on `sync`, run the lane's body with a cancellable `request` function, then report `success`, or `failure` after calling `onError` and, on a 401 (`status === 401` / `AuthenticationExpired`), `refreshAuth` (deduplicated across lanes); on `idle`/`wait`, sleep until the timer or a `wake`, with an epoch so a wake during the decision is not lost.
- Push lane body: `startSync pushOnly` then loop `next` → transport → `complete` until `null`.
- Live lane body (one "session" per attempt): snapshot `status.channels` and the live generation; return immediately when no channels; open the stream; after the acknowledgement run the HTTP catch-up per scope (`downlinkRequest` → POST pull → `downlinkPage` until `!continues` and not `recover`); deliver every streamed page through `downlinkPage`; a `recover` disposition triggers another catch-up. `subscribe`/`unsubscribe` bump the generation, abort the current session and wake the lane so a new session negotiates the new channel set; pages from an aborted session are ignored.
- Wakes: every commit, subscription change, readiness change, drop and applied page emits a work event that wakes the push lane, so a settlement observed on the stream lets the next dependent batch go without an application call.
- `pause` cancels in-flight requests on both lanes (Dart cancels the push request before awaiting the live lane), `resume` and `wake` fan out, `close` stops both and detaches; `Client.close` waits for an in-progress `connect` and closes the connection first.

## 8. Crosscutting Concepts

- Cursor policy is shared by HTTP and WebSocket pages through `receive_downlink` ([Engine / Pull](../engine/pull.md)); the host never inspects cursors.

## 10. Quality Requirements

- Driver: unit tests in [client/connection.rs](../../../../../crates/client/src/connection.rs); lanes are independent: [bindings/common/tests/session.rs](../../../../../bindings/common/tests/session.rs) `live_and_push_drivers_have_independent_lifecycle_and_retry_state`, `live_push_cycle_keeps_receipts_but_leaves_reads_to_the_stream`.
- Host loops: [connection.test.mjs](../../../../../integration/bindings/client-js/connection.test.mjs), [dart/test/connection_test.dart](../../../../../packages/dart/test/connection_test.dart).
- Sessions: [live.test.mjs](../../../../../integration/bindings/client-js/live.test.mjs) (ack-then-catch-up, resubscribe generations, refresh retry, overlap without HTTP, gap recovery, pause cancelling a held token, no-channel clients only push); [dart/test/live_test.dart](../../../../../packages/dart/test/live_test.dart) mirrors them.
- End to end: [round-trip.test.mjs](../../../../../integration/e2e/round-trip.test.mjs) `built-in live catch-up pages, dependent pushes, watches, offline reconnect, and Dart live client`.

## 11. Risks and Technical Debt

- **Confirmed gap versus the target: session orchestration lives in each SDK.** About 300 lines of generation, abort, catch-up and wake logic are implemented twice with small divergences ([Transport](transport.md)); Rust owns only the per-lane retry decision and the cursor policy. Evidence: `connect` in [client-js/index.mts](../../../../../packages/client-js/index.mts) and [dart/client.dart](../../../../../packages/dart/lib/src/client.dart). The overview already states this gap; no issue tracks moving the session into Rust.
- **Potential risk: without a WebSocket there is no pull at all.** The catch-up runs only after a stream acknowledgement (or on overflow); the push lane is `pushOnly`. If the upgrade is blocked (proxy, corporate network) the live lane retries with backoff forever, pushes still succeed, but receipts waiting on checkpoints never settle and no authoritative content arrives, even though `/sync/pull` would work. Evidence: `#runSync` with `pushOnly: true`; `catchUp` invoked only from `stream`. Not covered by a test; whether an HTTP polling fallback is wanted needs deciding (related: guarantee N6).
- **Confirmed debt: the full `SyncCycle` mode is dormant in production.** `restart()` without `push_only` is reachable only from tests and [protocol-fixture.mjs](../../../../../integration/e2e/protocol-fixture.mjs). Evidence: [client/transport.rs](../../../../../crates/client/src/transport.rs); [bindings/common/tests/session.rs](../../../../../bindings/common/tests/session.rs) `rust_selects_transport_actions_and_reuses_frozen_request_on_retry`.
- **Confirmed limitation: one connection per client, one server.** `connect` refuses a second active connection; there is no multi-server or failover story. Evidence: `connect` guards in both clients.
