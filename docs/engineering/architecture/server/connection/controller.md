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

## 10. Quality Requirements

- **Nothing is sent before commit; a rolled-back publication sends nothing; a duplicate receipt wakes nobody; pages split at 50 and the next page starts where the previous ended; reconnecting works.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `live transport negotiates, wakes only after commit, reconnects, and cleans up`.
- **Only one subscribe frame is accepted and scopes are normalized; a page's cursor progression is checked before sending.** Evidence: [server/tests/runtime.rs](../../../../../crates/server/tests/runtime.rs), [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs).

Tests read, not executed.

## 11. Risks and Technical Debt

**Potential risk.** Every commit that touches a channel triggers one pull transaction per subscribed socket; there is no shared page cache. Not measured ([#12](https://github.com/zanminwang/ahead/issues/12)).

**Accepted limitations.** Wakes are process-local ([Notify](../engine/notify.md)). Changing channels requires a new socket, and a subscribe may name any number of channels. The connection state machine is TypeScript; a second server runtime would re-implement it.
