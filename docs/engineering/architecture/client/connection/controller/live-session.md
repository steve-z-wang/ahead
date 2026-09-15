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
| `opened` | The socket is open; the host may send the subscribe frame. Read below as "socket open, frame already sent" (item 1). |
| `acknowledged { scopes }` | The server's acknowledgement arrived. Refined to `acknowledged { scopes, rejections }` below (item 1). |
| `page { body }` | A streamed page arrived. |
| `catchUp { channel, body }` | An HTTP catch-up response arrived for a request the session issued. |
| `overflow` | The host's page buffer overflowed (treated as a gap). |
| `subscriptionsChanged` | A subscribe or unsubscribe committed. |
| `closed { failure: bool }` | The socket closed, or an HTTP request failed. `failure` refined from a bool to four values below (item 5). |
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

### Vocabulary for the move (proposal, pending confirmation) ([#58](https://github.com/zanminwang/ahead/issues/58))

Every item below is a **proposal, pending confirmation**. It fills in detail the decision above leaves open; the connection model, the ownership split and the migration steps stand as decided. Two decided payloads are *refined* rather than merely filled in — `acknowledged` gains `rejections` (item 1) and `closed`'s `failure` becomes four values instead of a bool (item 5) — and a third, `opened`, is given a precise meaning (item 1); each is marked where it occurs and back-referenced from the event table above. Everything else states the behavior it preserves and cites the code it was derived from. Where the two SDKs behave differently, both are recorded and the difference is marked; nothing is picked silently.

#### 1. Session states and transitions

`LiveSession` holds one of `Idle`, `Opening`, `Subscribing`, `CatchingUp { channel }`, `Streaming`, `Closing`. Actions come one at a time from `next()`, so a step that both applies a page and issues a request answers `apply` first and the follow-up on the next call.

| State | Event | Next state | Action |
| --- | --- | --- | --- |
| `Idle` | `start`, snapshot has no channels | `Idle` | `idle` — the cycle ends successfully and the lane waits for a subscribe |
| `Idle` | `start`, snapshot has channels | `Opening` | `open { subscribe }` |
| `Opening` | `opened` | `Subscribing` | `idle` — the frame from `open` is already sent |
| `Subscribing` | `acknowledged { scopes, rejections }` (refined; see below) equal to the snapshot | `CatchingUp { first }` | `request { channel, body }` |
| `Subscribing` | `acknowledged` differing from the snapshot | `Closing` | `close { reason: protocol }` |
| `CatchingUp { c }` | `catchUp { channel: c, body }`, page continues or recovers | `CatchingUp { c }` | `apply`, then `request` for `c` |
| `CatchingUp { c }` | `catchUp { channel: c, body }`, page ends | `CatchingUp { next }` or `Streaming` | `apply`, then `request` or `idle` |
| `CatchingUp { c }` | `catchUp` naming another channel | `Closing` | `close { reason: protocol }` |
| `Streaming` | `page { body }`, disposition `covered` or `applied` | `Streaming` | `apply` |
| `Streaming` | `page { body }`, disposition `recover` | `CatchingUp { channel }` | `apply`, then `request` |
| `CatchingUp`, `Streaming` | `overflow` | `CatchingUp { first }` | `request` for every channel in turn |
| any | `subscriptionsChanged` | `Closing` | `close { reason: subscriptions }` |
| any | `pause`, `stop` | `Closing` | `close { reason: paused }`, `close { reason: stopped }` |
| `Opening`…`Closing` | `closed { failure }` | `Idle` | `retry { millis }` for a failure, `idle` otherwise |
| `Idle` | `resume`, `opened`, `page`, `catchUp`, `overflow`, `acknowledged` | `Idle` | `idle` — a leftover from an older session is dropped by the epoch |

Two refinements of decided events appear in the table:

- **`acknowledged { scopes, rejections }`.** The decided event is `acknowledged { scopes }`. Both hosts today also require the acknowledgement's `rejections` array to be present and empty (`packages/client-js/live.mts:112-122`, `packages/dart/lib/src/live.dart:194-206`), so Rust needs the field to keep that check when it takes it over.
- **`opened` means the frame is already sent.** The decided text reads "the host may send the subscribe frame"; both hosts send it as soon as the socket is open — TypeScript from the `open` handler, Dart right after `WebSocket.connect` resolves — with the frame the `open` action supplied (`packages/client-js/live.mts:102-107`, `packages/dart/lib/src/live.dart:157`). The table therefore treats `opened` as "socket open, frame sent" and answers `idle`. A host that prefers to wait for `opened` before sending sees no difference, since `open` already carries the frame.

Two rules the table depends on:

- **A streamed page is not delivered while a `request` is outstanding.** The host's buffer already guarantees this (`drain` runs one thing at a time in [client-js/live.mts](../../../../../../packages/client-js/live.mts) and [dart/live.dart](../../../../../../packages/dart/lib/src/live.dart)), which is why `page` appears only in `Streaming` above. *Open for confirmation:* whether a `page` during `CatchingUp` is a host contract violation (`close { reason: protocol }`) or is simply applied through the same path, where the cursor gate makes it harmless.
- **`recover` re-runs the catch-up for the channel that gapped**, as decided above; `overflow` re-runs it for every channel, because the host buffer it cleared is shared. *Difference from today:* both SDKs re-run the catch-up for **all** channels in both cases (`catchUp()` iterates the whole snapshot in [client-js/index.mts](../../../../../../packages/client-js/index.mts) and [dart/client.dart](../../../../../../packages/dart/lib/src/client.dart)). A channel that is already current answers one page that is neither full nor a gap, so the only observable difference is the number of requests, not the resulting state.

#### 2. The `apply` payload

`apply { disposition, continues }` — exactly today's `DownlinkProgress` from `receive_downlink` in [client/transport.rs](../../../../../../crates/client/src/transport.rs). `disposition` is `covered`, `applied` or `recover`; `continues` is true when the page carried the full 50 changes.

- **No settlement flag.** Whether a settlement happened is not observable in Rust today: `apply_current_page` calls `Engine::settle`, which returns `Result<()>`, and its own `ApplyReport { applied, skipped, stale, conflicts, diagnostics }` (`crates/client/src/downlink.rs:95`, `crates/client/src/lib.rs:86-92`) is discarded by `receive_downlink` (`crates/client/src/transport.rs:133`) rather than carried out. Both SDKs therefore emit the work event on `disposition === "applied"` alone. Reporting a real settlement would narrow the wake and therefore change behavior; it needs `settle` to report whether a push settled, which is a separate change. Until then `applied` is the wake condition, and the decision's phrase "whether a settlement happened" reads as "a page was applied, so a settlement may have happened".
- **`continues` stays** even though Rust now owns the catch-up loop, so the action and `DownlinkProgress` remain one type and the host can still log progress.
- **Record changes stay on the envelope.** Every binding reply already carries `changed`, `changedTables` and `generation` ([bindings/common/src/lib.rs](../../../../../../bindings/common/src/lib.rs)); that is what raises the change event, not the `apply` payload.

#### 3. Cancelling an in-flight request

`close { reason }` closes the socket **and** abandons any in-flight `request`. There is no separate `cancel` action.

This matches both SDKs, where one cancellation token covers the socket and the HTTP catch-up: TypeScript aborts a single `AbortController` that is passed to both `live.push("pull", …)` and `live.stream(…)`; Dart completes a single `Completer` that both `ServerSession.pull` and `ServerSession.stream` wait on. Reasons are `subscriptions`, `paused`, `stopped` and `protocol`; the response to a request abandoned this way never arrives, and if it does the epoch drops it.

#### 4. Binding surface

One `live` command family shaped like the existing `connection` op in [bindings/common/src/lib.rs](../../../../../../bindings/common/src/lib.rs): a single op with a nested `event`, not one op per event.

```json
{ "op": "live", "handle": 1, "event": "page", "body": { }, "now": 1739491200000, "entropy": 42 }
```

| `event` | Extra request fields | Reply `value` |
| --- | --- | --- |
| `start` | — | the next action |
| `opened` | — | the next action |
| `acknowledged` | `scopes`, `rejections` (a refinement; see item 1) | the next action |
| `page` | `body` (the page JSON) | the next action |
| `catchUp` | `channel`, `body` (the page JSON) | the next action |
| `overflow`, `subscriptionsChanged`, `pause`, `resume`, `stop` | — | the next action |
| `closed` | `failure` (see 5) | the next action |
| `next` | — | the next action |

Unlike `connection`, which answers with a value only for `event: "next"` and `null` otherwise, every `live` event answers with the next action. The asymmetry is deliberate: `connection` events mutate a driver the host then polls, while a live event usually *is* the thing that produces the next action, and a mandatory second round trip per event would double the calls through the exclusive queue. `next` stays in the family for a host that has no event to report. `now` and `entropy` accompany every event, as they do for `connection`, because `retry { millis }` is produced by the live lane's existing `ConnectionDriver`: the session reports the cycle outcome to it and returns the delay it computes, so backoff keeps one implementation. The op belongs in the arm that refuses to run while a client transaction is open, next to `connection`, `startSync` and `next`.

**`LiveSession` lives in `Entry`**, beside `cycle`, `connection` and `live_connection`. It has to: the epoch, the channel snapshot and the subscription generation exist to invalidate work from an *earlier* session, which is only meaningful if the state outlives the session that created it. A session recreated per cycle would have to be handed its predecessor's epoch by the host, putting back the duplicated state this change removes.

#### 5. Failure taxonomy

`closed { failure }` carries `none`, `auth`, `protocol` or `transport` instead of a bool. `none` ends the cycle successfully (no backoff); the other three end it as a failure, so the lane retries with backoff, and only `auth` asks the host for an authentication refresh.

| Kind | Meaning | TypeScript today | Dart today |
| --- | --- | --- | --- |
| `none` | The host closed the session on the session's own `close` action | `finish()` with no error resolves `stream` | `finish()` with no error completes `done` |
| `auth` | 401 on the upgrade, the catch-up or a push | `error.status === 401`, from `httpTransport` or the `unexpected-response` handler | `AuthenticationExpired`, from the status check or `WebSocketException.httpStatusCode` |
| `protocol` | An acknowledgement that does not match, a frame that is not a page, or a page Rust refuses | `Error("invalid live subscription acknowledgement")`, `Error("invalid live page")`, errors thrown by `downlinkPage` | `FormatException` with the same two messages, plus errors thrown by `downlinkPage` |
| `transport` | Socket close or error, non-401 HTTP failure, an abandoned request | `Error("live disconnected: …")`, `Error("live failed: <status>")`, `Error("pull failed: <status> …")`, `Error("connection_closed")` | `StateError('live disconnected: …')`, `HttpException`, a rethrown `WebSocketException` for a non-401 upgrade failure, `StateError('connection_paused_or_closed')` for an abandoned pull |

Two differences between the SDKs, neither resolved here:

- **An oversized frame.** TypeScript sets `maxPayload: 8 * 1024 * 1024` on the socket, so the library closes the connection and the host sees `transport`; Dart checks the decoded text length itself and throws `FormatException('live page too large')`, which reads as `protocol`. *Needs a choice:* classify an oversized frame as `transport` (the TypeScript path, and arguably right, since the peer may simply be too far ahead) or as `protocol` (the Dart path).
- **Which signal carries 401.** TypeScript reads a numeric `status` off the error; Dart uses a dedicated `AuthenticationExpired` type. Both already reach `refreshAuth` through [scheduling](scheduling.md); the taxonomy only asks each host to map its own signal onto `auth`.

Today every kind except `none` behaves identically (report through `onError`, retry with backoff, refresh once on 401), so adopting the taxonomy preserves behavior; it exists so that transition tests can assert *why* a session ended.

#### 6. Page-buffer parameter

`pageBuffer { pages, bytes }` — a host parameter, not part of the Rust state. `pages` counts buffered pages, `bytes` bounds their total encoded size; `0` means unbounded.

| | TypeScript today | Dart today |
| --- | --- | --- |
| `pages` | 64 | 128 |
| `bytes` | unbounded in aggregate; 8 MiB per frame through the socket's `maxPayload` | 8 MiB in aggregate, counted with the encoded page length, and 8 MiB per frame |
| On overflow | clear the buffer, keep the arriving page, request recovery | clear the buffer, drop the arriving page, request recovery |

The two "8 MiB" figures are not the same unit: `ws` applies `maxPayload` to the frame in bytes, while Dart accumulates `jsonEncode(page).length` and compares against the raw frame's `text.length`, both of which count UTF-16 code units, so non-ASCII content reaches Dart's bound later than it reaches the socket's. A shared parameter has to state which one `bytes` means.

**Rust does not need the bound.** Overflow reaches the session as an event and is treated as a gap, so the session never reasons about buffer capacity. Keeping the bound in the host is also what lets a platform with different memory pick a different number without a Rust change.

*Needs a choice:* one default for both SDKs, or each keeps its current numbers. The retained-versus-dropped page on overflow is a third difference; it is not observable in the end state, because the catch-up that follows makes the retained page `covered`.

#### 7. Server inputs and the server binding

The `closed`, `stop` and error inputs to `Subscriptions`, the register-before-acknowledge ordering rule, who enforces "send only when the cursor advanced", and the conflict between a stateful `Subscriptions` and today's stateless native entry points are written in [Server / Connection / Controller](../../../server/connection/controller.md), section 9.

#### 8. Ordering between `apply` and host events

Both SDKs serialize every Rust call for one client through an exclusive queue (`#exclusive` in [client-js/index.mts](../../../../../../packages/client-js/index.mts), `_exclusive` in [dart/client.dart](../../../../../../packages/dart/lib/src/client.dart)). The contract that keeps after-commit delivery and the work wake deterministic:

1. **One command at a time.** A host runs no other command for the same client between an event and the action it answers with. The session's actions are therefore ordered with respect to every read, write and push command.
2. **Events come after the command returns, before the next one.** Rust has already applied and committed the page when `apply` is returned, so an observer woken by the change event reads the applied state. The host emits the change event (from the envelope's `changed`) and then the work event (when `disposition` is `applied`), both still inside the queued slot that produced them.
3. **A work event may not re-enter.** Waking the push lane has to queue behind the current slot rather than call into Rust from inside it. TypeScript satisfies this because the listener calls `wake()`, which appends to the queue; Dart because `_work` is a broadcast stream delivered on a later microtask. *Difference, harmless:* TypeScript delivers the change and work events synchronously inside the emitting slot, Dart delivers `_changes` and `_work` asynchronously and `_channels` synchronously.
4. **Invalidation is not queued.** `subscribe` and `unsubscribe` abandon the socket and the in-flight request *before* their channel write enters the queue, which is what the test `subscription invalidation cancels pending authentication before the exclusive queue drains` asserts. The `subscriptionsChanged` event that follows reaches Rust only when the queue frees; the epoch is what makes the interval safe, since every page and response from the older session is dropped on arrival.

## 10. Quality Requirements

- **Listeners are established before the HTTP catch-up, and ordinary streamed pages do not trigger HTTP requests.** Evidence: [live.test.mjs](../../../../../../integration/bindings/client-js/live.test.mjs) `unified connection acknowledges listeners then catches up through HTTP before live delivery`; [live_test.dart](../../../../../../packages/dart/test/live_test.dart) `HTTP catch-up pages after ack, queues overlap, and rejects obsolete HTTP completion`.
- **Duplicates are covered, overlaps apply without HTTP, gaps recover from the durable cursor.** Evidence: `one incoming page path covers duplicates, applies overlap directly and recovers genuine gaps`; the Dart `native subscription changes discard old pages and HTTP recovers live gaps`.
- **A subscription change discards pages and pending authentication from the old generation, even while a transaction holds the database.** Evidence: `client replaces subscriptions from saved cursors and guards queued obsolete pages`, `late HTTP catch-up after unsubscribe and resubscribe cannot resurrect the obsolete generation`, `subscription invalidation cancels pending authentication before the exclusive queue drains`.
- **A commit observed during catch-up is not missed, and reconnect resumes from the persisted cursor.** Evidence: [round-trip.test.mjs](../../../../../../integration/e2e/round-trip.test.mjs) `built-in live catch-up pages, dependent pushes, watches, offline reconnect, and Dart live client`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation (current structure).** The session logic exists twice, once per SDK, with small differences in buffering ([Transport](../transport.md)). Rust owns only scheduling and the cursor policy; the overview records this as a gap between current code and the target where the controller is Rust. Section 9 records the decided design and migration ([#58](https://github.com/zanminwang/ahead/issues/58)).

**Issue overlap.** [#93](https://github.com/zanminwang/ahead/issues/93) restates this same work — lifecycle state machine, push scheduling, reconnect and retry, catch-up and gap recovery, subscription lifecycle — at a higher altitude, and has no design of its own; #58 owns this document, the merged design in section 9 and the acceptance criteria. The one item #93 adds is authentication-refresh coordination, and section 9 decides it: refresh stays a host concern because it needs the platform's credential store. What could still be shared later is the single-flight coordination that already exists in both SDKs (one refresh for two concurrent 401s), never the credential access itself. Track the work under #58.
