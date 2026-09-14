# Transport

Send and receive HTTP/WebSocket messages.

Current code: [server/index.mts](../../../../../packages/server/index.mts) (`createHttpHandler`, `attachLive`, `listen`).

## 1. Introduction and Goals

- Terminate HTTP and WebSocket traffic, authenticate each request once, enforce byte limits, and translate engine errors to statuses; no sync logic.

## 3. Context and Scope

- `listen({port, host = "127.0.0.1"})` → `{url, close}`: one `node:http` server with the HTTP handler and an attached `ws` `WebSocketServer` (`noServer`, `maxPayload` 1 MiB).
- HTTP routes: `POST /sync/mutations` and `POST /sync/pull` only; anything else is `404 not_found`; non-POST is `405 method_not_allowed` with `Allow: POST`.
- WebSocket: upgrade on `/sync/live`; other paths are ignored (left to other upgrade listeners).
- Upstream: `api.push`, `api.pull`, `api.negotiateLive`, `api.pullLive`, `api.onCommitted` ([Controller](controller.md), [Engine](../engine/README.md)).

## 5. Building Block View

- Request pipeline: `authenticate` (`401 unauthenticated` when null or blank) → body read with a 1 MiB cap (`413 request_too_large`) → strict UTF-8 JSON object parse (`400 request.invalid`) → engine call → `200` with the engine's JSON text; responses carry `content-type: application/json; charset=utf-8` and `cache-control: no-store`.
- Error mapping by message: `owner_mismatch` → `403 client.owner_mismatch`; `gap` / `overlap` → `409 {code}`; `mutation_version_unsupported:o:name:v` → `409 {code, ordinal, name, version}`; `request.invalid:*` → `400 request.invalid`; everything else → `onError(error)` and `500 server`.
- Upgrade pipeline: refuse with a raw `503` while closing, `500` if `authenticate` throws (reported to `onError`), `401` when unauthenticated; then `handleUpgrade` and hand the socket to the live controller.
- `close`: stop accepting upgrades, close every socket with `1001 closing`, close idle HTTP connections, then close the server.

## 10. Quality Requirements

- [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `HTTP adapter authenticates and serves the real native persistence path`, `listen answers pull over HTTP with authentication and closes cleanly`, `onError captures server-side failures and HTTP responds with {code:"server"}`, `live transport negotiates, wakes only after commit, reconnects, and cleans up`.
- End to end over a real backend: [round-trip.test.mjs](../../../../../integration/e2e/round-trip.test.mjs).

## 11. Risks and Technical Debt

- **Confirmed debt: status mapping keys on error message text.** The strings come from Rust and cross two boundaries unchanged; a message edit changes HTTP behavior silently. Owned by [SDKs / Bindings](../../sdks/bindings.md).
- **Unresolved question: deployment assumptions are not written down.** There is no TLS, CORS, compression or proxy-header handling; the server binds `127.0.0.1` by default. A reverse proxy is implied but not documented, and browser origins cannot call the HTTP routes cross-site. Evidence: `createHttpHandler`, `listen`.
- **Confirmed limitation: limits are fixed.** 1 MiB body, 1 MiB frame; `maxBodyBytes` and `maxPayloadBytes` exist on the internal functions but are not exposed through `listen`. Related: [#11](https://github.com/zanminwang/ahead/issues/11).
