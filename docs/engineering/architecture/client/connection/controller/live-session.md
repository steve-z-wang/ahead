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

## 9. Architecture Decisions

### The live session becomes a Rust state machine; hosts execute its actions ([#58](https://github.com/zanminwang/ahead/issues/58))

**Decision.** The session logic that today exists twice (`connect` in the TypeScript and Dart clients) moves into the Rust client as `LiveSession`, driven the way `ConnectionDriver` and `SyncCycle` already are: the host feeds events, Rust answers with the next action, and the host performs sockets, HTTP and timers. The server's per-scope drain policy moves into `ahead_server::live` the same way. The connection model stays as chosen: HTTP writes, HTTP catch-up after the WebSocket acknowledgement, then live pages; no polling.

**Client contract (`crates/client/src/live.rs`, exposed through the binding as one `live` command family).**

Inputs (`LiveEvent`):

| Event | Meaning |
| --- | --- |
| `start` | The lane's cycle began; the session snapshots the subscribed channels and the subscription generation (the same per-channel epochs [Pull](../../engine/pull.md) keeps). |
| `opened` | The socket is open; the host may send the subscribe frame. |
| `acknowledged { scopes }` | The server's acknowledgement arrived. |
| `page { body }` | A streamed page arrived. |
| `catchUp { channel, body }` | An HTTP catch-up response arrived for a request the session issued. |
| `overflow` | The host's page buffer overflowed (treated as a gap). |
| `subscriptionsChanged` | A subscribe or unsubscribe committed. |
| `closed { failure: bool }` | The socket closed, or an HTTP request failed. |
| `pause`, `resume`, `stop` | Lane controls, as today. |

Outputs (`LiveAction`), returned one at a time from `next()` until `idle`:

| Action | Host does |
| --- | --- |
| `open { subscribe }` | Open the socket and send the subscribe frame. |
| `request { channel, body }` | POST the catch-up request; report the response as `catchUp`. |
| `apply { … }` | Nothing; Rust already applied the page and reports the disposition (`covered`, `applied`, `recover`) and whether a settlement happened, so the host can emit its change and work events. |
| `close { reason }` | Close the socket (the session is invalid or stopped). |
| `retry { millis }` | Wait, then start again (`ConnectionDriver` semantics). |
| `idle` | Nothing to do until the next event. |

Rust owns: the snapshot of channels and generation; the epoch that invalidates every page and response from an older session; the catch-up loop (one channel at a time from the durable cursor, until a page is not full and did not recover); the rule that an acknowledged session catches up before applying streamed pages; gap recovery (`recover` re-runs the catch-up for that channel from the durable cursor); overflow as a gap; and the wake event after an applied settlement. Hosts own: sockets, HTTP, the buffer of pages that arrive while a catch-up request is in flight, timers, and authentication refresh on `401` (which stays a host concern because it needs the platform's credential store).

**Server contract (`crates/server/src/live.rs`).** `Subscriptions::new(negotiation)` holds one `ScopeState { scope, fromCursor, pending, running, closed }` per accepted scope. `on_commit(scope)` marks pending; `next(scope) -> DrainAction` answers `pull { fromCursor }`, `send { page, toCursor, continues }` after `pulled(progress)`, or `idle`; the host's drain loop executes `pullLive` and `socket.send`. The 50-row split, the "continues" rule and the "commit observed during a pull" rule live in Rust; the transport keeps the socket, the `onCommitted` wake hub and the close codes.

**Consequences.** Both SDKs shrink to transport code with no sync decisions; the transition tests run once in Rust; the target architecture's code map becomes true for the live session. The binding surface grows by one command family. Dart's larger page buffer and TypeScript's smaller one become host parameters, not behavior differences.

**Migration steps.** Each step keeps both SDK suites and the end-to-end suite green.

1. Add `LiveSession` and `DrainState` in Rust with transition tests: cancellation on `subscriptionsChanged`, overlap and duplicate pages, gap recovery, overflow, reconnect after `closed`, after-commit delivery order. No SDK change; `bindings/common` exposes the commands.
2. Switch the TypeScript client's `connect` to drive `LiveSession`; keep `live.mts` as the transport. Run `integration/bindings/client-js` and the end-to-end suite.
3. Switch the Dart client the same way; run the Dart suites and the end-to-end Dart client.
4. Switch the server's `attachLive` drain to `Subscriptions`; run the PostgreSQL suite.
5. Update the component tree, code map and this document's §5/§6; remove the §11 duplication note.

**Validation plan.** Shared transition tests in `crates/client/tests` and `crates/server/tests` (step 1 and 4); the existing SDK integration tests for cancellation, overlap, reconnect and after-commit delivery must pass unchanged after steps 2–4, since they assert observable behavior rather than implementation; `bash integration/e2e/run.sh` after each SDK step.

## 10. Quality Requirements

- **Listeners are established before the HTTP catch-up, and ordinary streamed pages do not trigger HTTP requests.** Evidence: [live.test.mjs](../../../../../../integration/bindings/client-js/live.test.mjs) `unified connection acknowledges listeners then catches up through HTTP before live delivery`; [live_test.dart](../../../../../../packages/dart/test/live_test.dart) `HTTP catch-up pages after ack, queues overlap, and rejects obsolete HTTP completion`.
- **Duplicates are covered, overlaps apply without HTTP, gaps recover from the durable cursor.** Evidence: `one incoming page path covers duplicates, applies overlap directly and recovers genuine gaps`; the Dart `native subscription changes discard old pages and HTTP recovers live gaps`.
- **A subscription change discards pages and pending authentication from the old generation, even while a transaction holds the database.** Evidence: `client replaces subscriptions from saved cursors and guards queued obsolete pages`, `late HTTP catch-up after unsubscribe and resubscribe cannot resurrect the obsolete generation`, `subscription invalidation cancels pending authentication before the exclusive queue drains`.
- **A commit observed during catch-up is not missed, and reconnect resumes from the persisted cursor.** Evidence: [round-trip.test.mjs](../../../../../../integration/e2e/round-trip.test.mjs) `built-in live catch-up pages, dependent pushes, watches, offline reconnect, and Dart live client`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation (current structure).** The session logic exists twice, once per SDK, with small differences in buffering ([Transport](../transport.md)). Rust owns only scheduling and the cursor policy; the overview records this as a gap between current code and the target where the controller is Rust. Section 9 records the decided design and migration ([#58](https://github.com/zanminwang/ahead/issues/58)).
