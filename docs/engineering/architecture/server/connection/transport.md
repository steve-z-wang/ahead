# Transport

## 1. Introduction and Goals

The server transport terminates HTTP and WebSocket traffic, authenticates each request once, enforces size limits and turns engine errors into statuses. It contains no sync logic.

## 3. Context and Scope

`backend.listen({port, host = "127.0.0.1"})` starts one Node HTTP server with two routes, `POST /sync/mutations` and `POST /sync/pull`, and a WebSocket upgrade on `/sync/live`. Other paths are `404`; other methods `405`. Bodies and frames are limited to 1 MiB.

## 5. Building Block View

Request handling is a pipeline: `authenticate` (null or blank → `401 unauthenticated`), read the body under the size cap (`413`), parse strict UTF-8 JSON (`400 request.invalid`), call the engine inside a transaction, answer `200` with the engine's JSON. Engine errors map by message: `owner_mismatch` → `403 client.owner_mismatch`; `gap` and `overlap` → `409`; `mutation_version_unsupported` → `409` with ordinal, name and version; `request.invalid:*` → `400`; anything else → `onError` and `500 server`.

The upgrade path authenticates before accepting the socket and refuses with a raw `401`, `500` (authenticate threw) or `503` (server closing). `close` stops upgrades, closes sockets with `1001`, then closes the server.

Code: `createHttpHandler`, `attachLive`, `listen` in [server/index.mts](../../../../../packages/server/index.mts).

## 10. Quality Requirements

- **Unauthenticated requests are refused, valid ones reach the native engine, malformed bodies are `400`, and server failures are `500 {code: "server"}` reported to `onError`.** Evidence: [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `HTTP adapter authenticates and serves the real native persistence path`, `onError captures server-side failures and HTTP responds with {code:"server"}`, `listen answers pull over HTTP with authentication and closes cleanly`.

Tests read, not executed.

## 11. Risks and Technical Debt

**Technical debt.** Status mapping keys on error message text from Rust ([Bindings](../../sdks/bindings.md)).

**To confirm.** Deployment assumptions are not written down: no TLS, CORS, compression or proxy-header handling, and the default bind address is loopback. A reverse proxy seems implied.

**Accepted limitation.** The 1 MiB limits are fixed; the internal options exist but `listen` does not expose them ([#11](https://github.com/zanminwang/ahead/issues/11)).
