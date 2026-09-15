# Controller

The controller decides when the client talks to the server. Rust owns the decisions and the cursor rules; the host language owns clocks, timers, sockets and the session orchestration built on them.

- [Scheduling](scheduling.md) — Per-lane state machine: when to run a cycle, when to retry, how pause, resume, wake and close behave.
- [Push lane](push-lane.md) — Freeze a batch, send it, hand the receipt to the engine, repeat.
- [Live session](live-session.md) — Subscribe over WebSocket, catch up over HTTP from the durable cursor, stream pages, recover from gaps and subscription changes.

## How the parts work together

A connection runs two independent lanes, each driven by its own [scheduling](scheduling.md) state machine. The **push lane** sends queued mutations over HTTP. The **live lane** holds a WebSocket session that delivers server pages; each session begins with an HTTP catch-up from the durable cursor, because the stream starts at the server's current head.

The lanes meet in the engine, not in the controller. A page applied by the live lane may satisfy a checkpoint, which settles a batch, which may unblock a dependent mutation; that settlement emits a work event that wakes the push lane. A commit, a subscription change, a readiness change or a dropped mutation wakes the push lane the same way. Subscription changes additionally invalidate the live session so it renegotiates with the new channel set.

Pause, resume, wake and close fan out to both lanes; `Client.close` closes the connection first. Errors from either lane reach the application through `onError`, and a 401 on either lane triggers the application's `refreshAuth` once, even if both lanes hit it together.

## Decision: no HTTP polling fallback

The live lane is the only path that pulls pages; the push lane never pulls. This was decided and is not open. The consequence when a WebSocket cannot be established (a proxy that blocks upgrades, for example): pushes still succeed, the live lane retries with backoff indefinitely, but no pages arrive and receipts that wait on a checkpoint do not settle until the socket connects.
