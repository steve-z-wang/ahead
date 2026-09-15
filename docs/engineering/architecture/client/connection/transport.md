# Transport

## 1. Introduction and Goals

The transport moves bytes. It knows the two HTTP routes and the WebSocket route, adds the bearer token, honors cancellation, and buffers streamed pages within a bound. It never looks inside a request body or a page; those come from and go to Rust.

## 3. Context and Scope

Configuration is `{url, token}`, where `token` is a string or a function returning one. Push and catch-up are `POST <url>/sync/mutations` and `POST <url>/sync/pull`; the stream is a WebSocket on `<url>/sync/live`; all three carry `Authorization: Bearer <token>`. A non-2xx response becomes an error carrying `status` (TypeScript) or `AuthenticationExpired` for 401 and `HttpException` otherwise (Dart), which is what [scheduling](controller/scheduling.md) uses to trigger an auth refresh.

## 5. Building Block View

Both transports do the same things with language-native tools:

| Concern | TypeScript | Dart |
| --- | --- | --- |
| HTTP | `fetch` with an `AbortSignal` | one `HttpClient` per request, force-closed on cancel |
| WebSocket | `ws` with an 8 MiB frame limit | `dart:io` with an 8 MiB text check |
| Page buffer | 64 pages; the socket is paused while a page is applied | 128 pages or 8 MiB in total |
| Overflow | buffer cleared, recovery requested | same |
| Cancellation | abort signal terminates the socket, even mid-upgrade | a future completes and closes the socket |

Recovery means the [live session](controller/live-session.md) runs its HTTP catch-up again; overflowing never restarts an in-flight HTTP request, so a burst of pages cannot starve the catch-up that advances the durable cursor.

Code: [client-js/transport.mts](../../../../../packages/client-js/transport.mts), [client-js/live.mts](../../../../../packages/client-js/live.mts), [dart/live.dart](../../../../../packages/dart/lib/src/live.dart).

## 10. Quality Requirements

- **Cancellation ends a stalled token, an in-flight request and an opening handshake, and a token that resolves late cannot start a request.** Evidence: [live.test.mjs](../../../../../integration/bindings/client-js/live.test.mjs) `live transport cancellation does not wait for a stalled token`, `close cancels opening handshake…`, `client close abandons a stalled live token…`; [live_test.dart](../../../../../packages/dart/test/live_test.dart) `cancel push before token resolution prevents any later HTTP request`, `HTTP catch-up cancellation ends stalled token and in-flight response`.
- **Overflow preserves in-flight HTTP progress and converges on the latest head.** Evidence: `bounded receive overflow preserves in-flight HTTP progress and recovers the latest head`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Accepted limitation.** The TypeScript transport is Node-only: it depends on the `ws` package and sets an upgrade header browsers cannot set. Nothing in the repository records a browser target either way.
