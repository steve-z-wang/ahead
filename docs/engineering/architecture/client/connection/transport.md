# Transport

Send and receive HTTP/WebSocket messages.

Current code: [client-js/transport.mts](../../../../../packages/client-js/transport.mts) (`httpTransport`), [client-js/live.mts](../../../../../packages/client-js/live.mts) (`createServerConnection`: `push`, `stream`), [dart/live.dart](../../../../../packages/dart/lib/src/live.dart) (`SyncServer`, `ServerSession`: `push`, `pull`, `stream`, `cancelPush`).

## 1. Introduction and Goals

- Move opaque request bodies and page frames between the host process and the server with authentication, cancellation and bounded buffering, and nothing else.

## 3. Context and Scope

- Configuration: `{url, token}` where `token` is a string or a function returning one (sync or async); the URL scheme is rewritten to `http(s)` for POSTs and `ws(s)` for the stream.
- HTTP: `POST <url>/sync/mutations` (push) and `POST <url>/sync/pull` (catch-up) with `Authorization: Bearer <token>` and `content-type: application/json`; non-2xx becomes an error carrying `status` (TypeScript) or `AuthenticationExpired` for 401 and `HttpException` otherwise (Dart).
- WebSocket: `<url>/sync/live` with the same bearer header; first frame `subscribe`, then pages ([Protocol / Subscriptions](../../protocol/subscriptions.md)).
- Callers: [Controller](controller.md) supplies bodies produced by Rust and hands every received page back to Rust.

## 5. Building Block View

- TypeScript `stream(subscription, apply, signal, catchUp)`: opens `ws` with `maxPayload` 8 MiB, validates the acknowledgement, then queues pages; `drain` pauses the socket while applying, calls `catchUp` once after the acknowledgement and whenever the queue overflowed (64 pages → queue cleared, recovery flagged); `AbortSignal` terminates the socket, including during the upgrade.
- Dart `stream(channels, apply, cancellation, catchUp)`: same handshake; pages are buffered up to 128 frames or 8 MiB total, overflow clears the buffer and schedules `catchUp`; cancellation closes the socket and the `HttpClient`.
- Dart `push`/`pull`: one `HttpClient` per request, force-closed afterwards; `cancelPush` bumps an epoch and closes in-flight clients so a token that resolves late cannot start a request; `pull` races the request against a cancellation future.
- TypeScript `httpTransport` checks `signal.aborted` after resolving the token and passes the signal to `fetch`.

## 10. Quality Requirements

- [live.test.mjs](../../../../../integration/bindings/client-js/live.test.mjs): stream handshake and serialization, cancellation with a stalled token, invalid credentials, bounded overflow preserving in-flight HTTP progress.
- [dart/test/live_test.dart](../../../../../packages/dart/test/live_test.dart): cancellation of stalled tokens and in-flight responses, `cancelPush` before token resolution, close during the opening handshake.

## 11. Risks and Technical Debt

- **Confirmed gap versus the target: two transports, two behaviors.** The overflow thresholds (64 pages versus 128 pages / 8 MiB), backpressure (socket pause versus none) and 401 signalling differ between languages; no shared test pins them. Evidence: the two files above. This is part of the controller duplication owned by [Controller](controller.md).
- **Confirmed limitation: not usable from a browser.** The WebSocket bearer header and the `ws` dependency are Node facilities; browsers cannot set upgrade headers. Evidence: [client-js/live.mts](../../../../../packages/client-js/live.mts). Whether a browser target exists needs deciding ([SDKs / Typed API](../../sdks/typed-api.md)).
- **Potential risk: per-request `HttpClient` in Dart.** Every push and pull opens and force-closes a client, so there is no connection reuse during catch-up of many pages. Evidence: [dart/live.dart](../../../../../packages/dart/lib/src/live.dart) `push`, `pull`. Not measured ([#12](https://github.com/zanminwang/ahead/issues/12)).
