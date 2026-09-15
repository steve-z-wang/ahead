# Live session

## 1. Introduction and Goals

A live session is one attempt to follow the client's channels: open the WebSocket, subscribe, catch up over HTTP from where the durable cursor stands, then apply streamed pages until something invalidates the session. Every page, streamed or fetched, goes through the same cursor gate in [Pull](../../engine/pull.md), so the session logic never inspects cursors itself.

## 3. Context and Scope

Rust commands: `status` (the subscribed channels), `downlinkRequest {scope}` → a pull request body, `downlinkPage {page, request?}` → `{disposition, continues}`. Network: the [transport](../transport.md) stream and `POST /sync/pull`. The session is the body of the live lane and runs whenever [scheduling](scheduling.md) says `sync`.

## 5. Building Block View

Two counters protect the session from stale work. The client keeps a *subscription generation*, bumped by every subscribe or unsubscribe; the session keeps an *epoch*, bumped whenever a session is started or invalidated. A page or a catch-up request is processed only while both still match the values captured when the session began. This is what makes it safe for a subscribe to abort a session mid-stream: whatever the old socket still delivers is ignored.

The catch-up is a loop per subscribed channel: ask Rust for the request from the durable cursor, POST it, deliver the page, stop when the page is not full and did not report a gap.

Code: `connect` in [client-js/index.mts](../../../../../../packages/client-js/index.mts) and [dart/client.dart](../../../../../../packages/dart/lib/src/client.dart); dispositions in [client/transport.rs](../../../../../../crates/client/src/transport.rs) (`receive_downlink`).

## 6. Runtime View

1. Snapshot the subscribed channels and the generation. With no channels the session ends successfully and the lane stays idle until a subscribe wakes it.
2. Open the stream and send the subscribe frame ([Protocol / Subscriptions](../../../protocol/subscriptions.md)).
3. On the acknowledgement, run the catch-up for every channel. Pages the stream delivers meanwhile are buffered by the transport.
4. Deliver each streamed page. `covered` means the catch-up already passed it; `applied` means it followed the cursor directly; `recover` means a gap, and the catch-up runs again from the durable cursor. A transport buffer overflow is treated as a gap too.
5. The session ends when the socket closes (a failure, so the lane retries with backoff), when a subscription change invalidates it (the lane is woken and starts a new session with the new channel set), or on pause or close.

An applied page emits a work event so that a settlement it caused wakes the [push lane](push-lane.md).

## 10. Quality Requirements

- **Listeners are established before the HTTP catch-up, and ordinary streamed pages do not trigger HTTP requests.** Evidence: [live.test.mjs](../../../../../../integration/bindings/client-js/live.test.mjs) `unified connection acknowledges listeners then catches up through HTTP before live delivery`; [live_test.dart](../../../../../../packages/dart/test/live_test.dart) `HTTP catch-up pages after ack, queues overlap, and rejects obsolete HTTP completion`.
- **Duplicates are covered, overlaps apply without HTTP, gaps recover from the durable cursor.** Evidence: `one incoming page path covers duplicates, applies overlap directly and recovers genuine gaps`; the Dart `native subscription changes discard old pages and HTTP recovers live gaps`.
- **A subscription change discards pages and pending authentication from the old generation, even while a transaction holds the database.** Evidence: `client replaces subscriptions from saved cursors and guards queued obsolete pages`, `late HTTP catch-up after unsubscribe and resubscribe cannot resurrect the obsolete generation`, `subscription invalidation cancels pending authentication before the exclusive queue drains`.
- **A commit observed during catch-up is not missed, and reconnect resumes from the persisted cursor.** Evidence: [round-trip.test.mjs](../../../../../../integration/e2e/round-trip.test.mjs) `built-in live catch-up pages, dependent pushes, watches, offline reconnect, and Dart live client`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation (current structure).** The session logic exists twice, once per SDK, with small differences in buffering ([Transport](../transport.md)). Rust owns only scheduling and the cursor policy; the overview records this as a gap between current code and the target where the controller is Rust.
