# Controller

## 1. Introduction and Goals

The server controller holds one WebSocket per client, learns its channels once, and sends a new page for a channel as soon as a transaction that touched it commits. It reuses the pull engine for every page, so streamed and fetched pages are identical.

## 3. Context and Scope

Input: an authenticated socket from the [transport](transport.md), commit wakes from [Notify](../engine/notify.md). Output: the acknowledgement and pages defined in [Protocol / Subscriptions](../../protocol/subscriptions.md). Negotiation and every page run inside a database transaction through the [backend interface](../backend-interface.md).

## 5. Building Block View

Per socket, one state per subscribed channel: the cursor streamed so far (starting at the head read during negotiation), a *pending* flag set by wakes, a *running* flag so only one drain runs at a time, and a closed flag. The Rust side decodes the subscribe frame, normalizes scopes, reads heads, and validates each page's scope and cursor before it is sent.

Code: `serveLive` in [server/index.mts](../../../../../packages/server/index.mts); `decode_subscribe`, `negotiate`, `pull`, `page_progress` in [server/live.rs](../../../../../crates/server/src/live.rs).

## 6. Runtime View

1. Wait for the first frame. A second client frame at any time closes the socket with `1002`.
2. Negotiate: decode, read heads, build the acknowledgement. Register a wake callback per channel *before* sending it, then mark every channel pending and drain. A commit that lands between the negotiation transaction and the registration is therefore caught by that first drain.
3. Drain a channel: pull from the streamed cursor, send the page if it advanced, repeat while pages are full; if a wake arrived meanwhile, drain again.
4. On a drain error, report it and close with `1011`; the client reconnects with backoff. On close, remove every registration and listener.

## 9. Architecture Decisions

### Drain vocabulary for the move into Rust (proposal, pending confirmation) ([#58](https://github.com/zanminwang/ahead/issues/58))

The client-side decision to move the connection-controller policy into Rust ([Live session](../../client/connection/controller/live-session.md), section 9) gives the server side `Subscriptions::new(negotiation)`, `ScopeState { scope, fromCursor, pending, running, closed }`, `on_commit(scope)`, `next(scope) -> pull | send | idle` and `pulled(progress)`. Everything below is a **proposal, pending confirmation** that completes that list from the drain loop running today in `serveLive` ([server/index.mts](../../../../../packages/server/index.mts)). It changes nothing that was decided.

**Lifecycle inputs.** The drain loop reacts to three things the decided list does not name:

| Input | Replaces today | Effect |
| --- | --- | --- |
| `acknowledged()` | marking every scope pending after the acknowledgement is sent | Until it is called, `next(scope)` answers `idle` for every scope. It then marks every scope pending, so the first drain runs. |
| `stop()` | the `stop` closure on the socket's `close` and `error` events, and the `finally` block | Marks every scope closed and clears pending; `next` answers `idle` forever after. |
| `failed(scope)` | the `catch` around the drain | Same terminal state as `stop()`. The host keeps the reporting and the `1011` close; Rust only stops handing out work. |

`closed` therefore stays a field of `ScopeState`, set by `stop()` and `failed(scope)`; there is no per-scope close, because a socket carries all of a client's scopes and today's `stop` closes them together.

**Register the wakes before acknowledging.** The rule stays what it is today: register a wake callback per scope, then send the acknowledgement, then start draining, so a commit landing between the negotiation transaction and the registration is caught by the first drain. The wake hub stays in the transport, so Rust cannot enforce the rule — but `acknowledged()` makes it mechanical: `Subscriptions` hands out no work until the host says the acknowledgement is out, and a host that registers afterwards still cannot lose a commit, because the wake it missed is covered by the pending flag `acknowledged()` sets.

**"Send only when the cursor advanced" is enforced in Rust.** Today the host compares `progress.toCursor` with the streamed cursor before sending. In the new split `next(scope)` answers `send { page, toCursor, continues }` only when the pull advanced the cursor and `idle` otherwise, and the host sends whatever `send` gives it. Rust already has both cursors, so this preserves behavior and removes the last cursor comparison from the transport.

**The stateful-`Subscriptions` conflict, and the smallest resolution.** `Subscriptions` is state that lives for the life of a socket, but every native entry point in [bindings/node/src/server.rs](../../../../../bindings/node/src/server.rs) is a stateless function that takes a fresh host callback per call. The decided design says the client binding grows by one command family and does not consider the server binding at all.

*Proposal:* add a session handle family, mirroring the client's `Entry` registry — the smallest change that keeps the existing entry points untouched.

| Command | Argument | Returns |
| --- | --- | --- |
| `liveOpen` | the negotiation JSON | a handle |
| `liveEvent` | handle, `{ type: "commit" \| "acknowledged" \| "failed" \| "stop", scope? }` | nothing |
| `liveNext` | handle, scope | `pull { fromCursor }`, `send { page, toCursor, continues }` or `idle` |
| `livePulled` | handle, scope, the progress from `pullLive` | nothing |
| `liveClose` | handle | nothing |

The pull itself stays `pullLive`, unchanged: it needs a host callback for its database transaction, and keeping it out of the handle family leaves the callback lifetime exactly as it is. The alternative — passing the whole scope state in and out of a stateless `drainStep` call — keeps the state in TypeScript, which is what the move is for.

## 10. Quality Requirements

- **Nothing is sent before commit; a rolled-back publication sends nothing; a duplicate receipt wakes nobody; pages split at 50 and the next page starts where the previous ended; reconnecting works.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `live transport negotiates, wakes only after commit, reconnects, and cleans up`.
- **Only one subscribe frame is accepted and scopes are normalized; a page's cursor progression is checked before sending.** Evidence: [server/tests/runtime.rs](../../../../../crates/server/tests/runtime.rs), [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs).

Tests read, not executed.

## 11. Risks and Technical Debt

**Potential risk.** Every commit that touches a channel triggers one pull transaction per subscribed socket; there is no shared page cache. Not measured ([#12](https://github.com/zanminwang/ahead/issues/12)).

**Accepted limitations.** Wakes are process-local ([Notify](../engine/notify.md)). Changing channels requires a new socket, and a subscribe may name any number of channels. The connection state machine is TypeScript; a second server runtime would re-implement it.
