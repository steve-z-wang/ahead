# Live session

## 1. Introduction and Goals

A live session is one attempt to follow the client's channels: open the WebSocket, subscribe, catch up over HTTP from where the durable cursor stands, then apply streamed pages until something invalidates the session. Every page, streamed or fetched, goes through the same cursor gate in [Pull](../../engine/pull.md), so the session logic never inspects cursors itself.

## 3. Context and Scope

The session is a Rust state machine, `LiveSession`, driven the way [scheduling](scheduling.md) and the [push lane](push-lane.md) are: the host feeds events and executes the actions Rust answers with. One binding command, `live`, carries both ([Bindings](../../../sdks/bindings.md)). The host owns the socket, the HTTP requests, the timers, its frame buffer and the credential refresh; it makes no sync decision.

Events (`live {event, now, entropy, …}`):

| Event | Meaning |
| --- | --- |
| `start`, `stop`, `pause`, `resume`, `wake`, `next` | Lane controls and the timer, as for the push lane's `connection` command. |
| `message {epoch, body}` | A frame arrived on the socket of this epoch: the acknowledgement or a page. |
| `catchUp {epoch, body}` | The response to a `request` action of this epoch. |
| `overflow {epoch}` | The host's frame buffer overflowed and frames were dropped. |
| `closed {epoch}` | The socket of this epoch closed, or a request of it failed. The host has already reported the error and refreshed credentials if it chose to. |

Actions, returned in order by every command:

| Action | Host does |
| --- | --- |
| `open {epoch, subscribe}` | Open the socket and send the subscribe frame once it is open. Frames are `message` events of this epoch; the socket's end is `closed`. |
| `request {epoch, channel, body}` | `POST /sync/pull`; the response is `catchUp`, a failure is `closed`. |
| `close {epoch, reason?}` | Close the socket of this epoch and abandon its request. A `reason` is a protocol violation to report as an error. |
| `wake {lane: "push"}` | A page applied and may have settled a batch: wake the push lane. |
| `wait {millis}` | Nothing to do until the timer fires; then report `next`. |

## 5. Building Block View

Rust owns the snapshot of the channels and the subscription generation, the epoch that invalidates every frame and response of an older session, the catch-up loop, the rule that an acknowledged session catches up before trusting the stream, gap and overflow recovery, and the wake after an applied page.

- **Epoch.** Every session has one. An I/O event names the epoch it belongs to, so whatever an abandoned socket or request still delivers is ignored. The host does not need to know why a session ended.
- **Subscription generation.** The engine counts committed subscribes and unsubscribes ([Frontend interface](../../frontend-interface.md), `subscription_generation`). A session records the value it started under; the next event after a change ends it without backoff and starts one with the new channel set. The SDKs abandon the current socket as soon as `subscribe` or `unsubscribe` is called, so no request is started for a set that is about to change, and wake the lane once the change commits.
- **Catch-up.** After the acknowledgement every channel is queued; one request is in flight at a time, from the durable cursor, repeated while the page is full ([Protocol / Pull](../../../protocol/pull.md)). A streamed page for a channel still catching up is held (at most `DEFERRED_PAGES`, 64, per session; beyond that the held pages are dropped and their channels recover) and passes the cursor gate once its channel's round ends. A streamed page for a channel that is not catching up applies at once.
- **Recovery.** `recover` for a channel that is not catching up queues a round for it; for the channel whose request is in flight it marks one more round after the current one. A host `overflow` recovers every channel, because which channels lost frames is unknown; the request in flight keeps its progress, so sustained traffic cannot starve the catch-up that advances the durable cursor.
- **Failures.** A socket close, a request failure, an unconfirmed acknowledgement, a page before the acknowledgement or a malformed frame ends the session; the lane retries with the [scheduling](scheduling.md) backoff. A subscription change, `pause` and `stop` end it without backoff.

Code: [client/live.rs](../../../../../../crates/client/src/live.rs); dispositions in [client/transport.rs](../../../../../../crates/client/src/transport.rs) (`receive_downlink`); the host loops in [client-js/connection.mts](../../../../../../packages/client-js/connection.mts) (`startLiveLane`) and [dart/connection.dart](../../../../../../packages/dart/lib/src/connection.dart) (`LiveLane`).

## 6. Runtime View

1. `start` or a `wake` on an idle lane snapshots the subscribed channels and the generation. With no channels the session ends successfully and the lane stays idle until a subscribe wakes it. Otherwise `open` carries the subscribe frame ([Protocol / Subscriptions](../../../protocol/subscriptions.md)), which declares the read contracts straight from the client's schema (`declared_models`: every model at the version its generated types read); the catch-up requests carry the same declaration, so both paths are served at the same versions and a reconnect or a subscription change declares them again.
2. The first frame must be an acknowledgement confirming the requested set; then a `request` starts the catch-up. Every `catchUp` answer goes through the cursor gate: `continues` or `recover` repeats the request, otherwise the next channel's round begins, and the channel's held pages are applied.
3. Streamed pages apply through the same gate: `covered` does nothing, `applied` wakes the push lane, `recover` queues a round from the durable cursor.
4. The session ends with `close`: on a failure the answer also carries `wait`, and `next` after it opens a new socket that subscribes again from the durable cursor; on a subscription change the new session opens in the same answer; on `pause` or `stop` nothing follows.

## 9. Architecture Decisions

### The live session is a Rust state machine; hosts execute its actions ([#58](https://github.com/zanminwang/ahead/issues/58))

**Decision.** The session logic that existed twice (`connect` in the TypeScript and Dart clients) is the Rust `LiveSession`, driven like `ConnectionDriver` and `SyncCycle`: the host feeds events, Rust answers with actions, and the host performs sockets, HTTP and timers. The server's per-scope drain policy is `Subscriptions` in `ahead_server::live` ([Server / Connection / Controller](../../../server/connection/controller.md)). The connection model stays as chosen: HTTP writes, HTTP catch-up after the WebSocket acknowledgement, then live pages; no polling.

**Implemented contract.** Sections 3 and 5 describe it. It refines the contract this decision first sketched in four places, each chosen to keep the host without decisions:

- No `opened` or `subscriptionsChanged` event. `open` carries the frame, and Rust observes subscription changes itself through the engine's generation, so a host cannot forget to report one.
- No `acknowledged` event and no `apply` action. Every frame is a `message`; Rust tells an acknowledgement from a page ([Protocol / Subscriptions](../../../protocol/subscriptions.md)), applies pages itself, and answers `wake` when the push lane should run. The push lane's own `connection` command is unchanged.
- The live lane's scheduling lives inside `LiveSession` (`start`, `pause`, `resume`, `wake`, `next`, `wait`), so a host drives one state machine per lane.
- Streamed pages of a channel still catching up are held by Rust, bounded, rather than by the host; the host's buffer only bounds delivery.

**Consequences.** Both SDKs shrink to transport code with no sync decisions; the transition tests run once in Rust; the target architecture's code map is true for the live session. Dart's larger frame buffer and TypeScript's smaller one are host parameters ([Transport](../transport.md)); the session's own bound is the same in both.

**Validation.** Transition tests in [sqlite/tests/live.rs](../../../../../../crates/sqlite/tests/live.rs) and the binding tests in [bindings/common/tests/session.rs](../../../../../../bindings/common/tests/session.rs); the SDK integration tests for cancellation, overlap, reconnect and after-commit delivery pass unchanged, since they assert observable behavior; `bash integration/e2e/run.sh` with both clients.

## 10. Quality Requirements

- **The session subscribes, catches up only after the acknowledgement, holds streamed pages until their channel's round ends, wakes the push lane on an applied page, and recovers a gap from the durable cursor.** Evidence: [sqlite/tests/live.rs](../../../../../../crates/sqlite/tests/live.rs) `a_session_subscribes_catches_up_after_the_acknowledgement_and_then_streams`, `catch_up_runs_one_channel_at_a_time_and_a_full_page_continues`; [session.rs](../../../../../../bindings/common/tests/session.rs) `incoming_pages_share_cursor_policy_and_do_not_overwrite_push_cycle`, `incoming_overlap_is_identical_with_or_without_http_request_metadata`.
- **Overflow recovers every channel without abandoning the request in flight; a subscription change ends the session without backoff and ignores the old epoch's frames and answers; a dropped socket reconnects with backoff and resubscribes; protocol violations close with a reason; pause, resume and stop.** Evidence: `overflow_recovers_every_channel_without_abandoning_the_request_in_flight`, `a_subscription_change_ends_the_session_and_the_next_one_uses_the_new_set`, `a_dropped_socket_reconnects_with_backoff_and_resubscribes`, `protocol_violations_close_with_a_reason_and_retry`, `pause_ends_the_session_without_backoff_resume_reopens_and_stop_is_final`, `a_page_from_a_previous_subscription_is_stale_not_a_gap_through_the_session` in the same file. Verified 2026-09-15: `cargo test -p ahead-sqlite --test live --locked` (8 tests), `cargo test -p ahead-binding --locked` (7 tests).
- **Listeners are established before the HTTP catch-up, and ordinary streamed pages do not trigger HTTP requests.** Evidence: [live.test.mjs](../../../../../../integration/bindings/client-js/live.test.mjs) `unified connection acknowledges listeners then catches up through HTTP before live delivery`; [live_test.dart](../../../../../../packages/dart/test/live_test.dart) `HTTP catch-up pages after ack, queues overlap, and rejects obsolete HTTP completion`.
- **Duplicates are covered, overlaps apply without HTTP, gaps recover from the durable cursor.** Evidence: `one incoming page path covers duplicates, applies overlap directly and recovers genuine gaps`; the Dart `native subscription changes discard old pages and HTTP recovers live gaps`.
- **A subscription change discards pages and pending authentication from the old session, even while a transaction holds the database.** Evidence: `client replaces subscriptions from saved cursors and guards queued obsolete pages`, `late HTTP catch-up after unsubscribe and resubscribe cannot resurrect the obsolete generation`, `subscription invalidation cancels pending authentication before the exclusive queue drains`.
- **A commit observed during catch-up is not missed, and reconnect resumes from the persisted cursor.** Evidence: [round-trip.test.mjs](../../../../../../integration/e2e/round-trip.test.mjs) `built-in live catch-up pages, dependent pushes, watches, offline reconnect, and Dart live client`.

Verified 2026-09-15 after the move to Rust: `node --test integration/bindings/client-js/*.test.mjs` (32 pass), `dart test` in `packages/dart` (28 pass), `bash integration/e2e/run.sh` (round-trip 3, parity 1).

## 11. Risks and Technical Debt

**Accepted limitation.** A streamed page held for a channel still catching up is re-evaluated only when that channel's round ends; a round that keeps continuing (a very long backlog) holds the session's pages until then, and beyond 64 held pages the channels recover instead. Correctness does not depend on the bound; only the number of catch-up requests does.
