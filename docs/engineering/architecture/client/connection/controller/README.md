# Controller

The controller decides when the client talks to the server. Rust owns the decisions, the session and the cursor rules; the host language owns clocks, timers, sockets, HTTP and credential storage, and executes what Rust asks.

- [Scheduling](scheduling.md) — Per-lane state machine: when to run a cycle, when to retry, how pause, resume, wake and close behave.
- [Push lane](push-lane.md) — Freeze a batch, send it, hand the receipt to the engine, repeat.
- [Live session](live-session.md) — Subscribe over WebSocket, catch up over HTTP from the durable cursor, stream pages, recover from gaps and subscription changes.

## How the parts work together

A connection runs two independent lanes, each with its own [scheduling](scheduling.md) state. The **push lane** sends queued mutations over HTTP. The **live lane** holds a WebSocket session that delivers server pages; each session begins with an HTTP catch-up from the durable cursor, because the stream starts at the server's current head. The push lane is a host loop around the `connection` command; the live lane is the Rust `LiveSession`, whose scheduling is built in.

The lanes meet in the engine, not in the controller. A receipt completes its batch at once ([Settlement](../../engine/settlement.md)), which may unblock a dependent mutation, so the push lane loops until `next` has nothing to send. Pages from the live lane never complete a batch; they carry the same authority the receipt already did, or newer. A commit, a subscription change, a readiness change or a dropped mutation wakes the push lane. Subscription changes additionally invalidate the live session so it renegotiates with the new channel set.

Pause, resume, wake and close fan out to both lanes; `Client.close` closes the connection first. Errors from either lane reach the application through `onError`, and a 401 on either lane triggers the application's `refreshAuth` once, even if both lanes hit it together. Credential refresh stays with the host because it needs the platform's credential store; Rust only learns that the session closed.

## Decision: no HTTP polling fallback

The live lane is the only path that pulls pages; the push lane never pulls. This was decided and is not open. The consequence when a WebSocket cannot be established (a proxy that blocks upgrades, for example): pushes still succeed and complete from their receipts, with the server's content for the records they changed; the live lane retries with backoff indefinitely, and other clients' changes arrive only once the socket connects.
