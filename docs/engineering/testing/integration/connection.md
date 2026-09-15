# Connection tests

Verify protocol messages and lifecycle across HTTP/WebSocket: subscription acknowledgement, initial catch-up, streamed updates, cancellation, reconnect and authentication refresh.

[JavaScript live tests](../../../../integration/bindings/client-js/live.test.mjs) and [Dart live tests](../../../../packages/dart/test/live_test.dart) cover the client side. [Server runtime tests](../../../../integration/persistence/server/runtime.test.mjs) include live subscriptions and after-commit wakes. Some lifecycle tests use controlled transports; distinguish those from real socket tests.

After setup in [Running tests](../running.md):

```sh
node --test integration/bindings/client-js/live.test.mjs
bash integration/persistence/server/run.sh
```

Assert that obsolete responses cannot affect the current session and that overlapping catch-up/stream pages preserve local state. Test the existing connection model: HTTP catch-up with WebSocket updates.

Next review: map cancellation, overflow, auth and reconnect scenarios across both clients, including teardown and resource cleanup.

## Coverage review

Reviewed 2026-09-14; tests read, not executed. Client-side tests use a real WebSocket server and real HTTP listener in the test process but a scripted backend; server-side tests run the real backend over PostgreSQL. Both count as real transport boundaries; neither alone proves the full pair, which is the end-to-end suite's job.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Handshake and acknowledgement; cancellation ends stalled tokens, in-flight requests and opening handshakes ([Transport](../../architecture/client/connection/transport.md)) | [live.test.mjs](../../../../integration/bindings/client-js/live.test.mjs) first five tests; [live_test.dart](../../../../packages/dart/test/live_test.dart) first five tests | covered in both languages | none |
| Catch-up starts only after the acknowledgement; steady-state streaming does not poll HTTP ([Live session](../../architecture/client/connection/controller/live-session.md)) | `unified connection acknowledges listeners then catches up through HTTP before live delivery`; Dart `HTTP catch-up pages after ack, queues overlap, and rejects obsolete HTTP completion` | covered | none |
| Duplicates covered, overlaps applied without HTTP, gaps recovered | `one incoming page path covers duplicates, applies overlap directly and recovers genuine gaps`; Dart `native subscription changes discard old pages and HTTP recovers live gaps` | covered | none |
| Subscription changes invalidate the session and pending authentication; obsolete pages and late catch-ups are discarded | `client replaces subscriptions…`, `late HTTP catch-up after unsubscribe and resubscribe…`, `subscription invalidation cancels pending authentication…`; Dart `unsubscribe invalidates a pending token before a held transaction drains` | covered | none |
| Auth refresh on 401, retried after a failed refresh | `client retries upgrade authentication and survives failed refresh`; Dart equivalent | covered | Refresh deduplication when both lanes hit 401 together is not asserted. |
| Bounded buffer overflow recovers without restarting HTTP | `bounded receive overflow preserves in-flight HTTP progress and recovers the latest head`; Dart `bounded receive buffer (128 pages) overflows into recovery without restarting the in-flight HTTP catch-up` | covered in both SDKs | The Dart test sends 200 live pages while the first catch-up is held; the socket is not restarted and recovery coalesces into at most four pulls. The 8 MiB byte bound is not exercised separately. |
| Pause cancels held requests and a late token cannot start one; resume reconnects | `pause cancels held catch-up and a late HTTP token cannot start a request`; Dart `pause blocks a selected parent request before awaiting child pause`, `shared live factory isolates cancellation…` | covered | none |
| Push continues when the WebSocket cannot be established; no pages arrive and checkpoints do not settle; once the upgrade is allowed, HTTP catch-up settles the receipt ([Controller decision](../../architecture/client/connection/controller/README.md)) | [live.test.mjs](../../../../integration/bindings/client-js/live.test.mjs) `push succeeds while the WebSocket upgrade is refused; nothing settles until the upgrade is allowed and HTTP catch-up runs`; Dart [live_test.dart](../../../../packages/dart/test/live_test.dart) same name | covered in both SDKs | The server refuses upgrades with `503` and serves `/sync/mutations`: the push is accepted, no `/sync/pull` runs (no polling fallback), pending stays 1, the refusals reach `onError`, the lane keeps retrying; after upgrades are allowed the catch-up runs once and pending settles without re-requesting the receipt. Characterizes the decision. |
| Server: authenticate before upgrade, one subscribe frame, wake after commit, page split, reconnect, duplicate receipt is silent, shutdown closes sockets | [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `live transport negotiates, wakes only after commit, reconnects, and cleans up`, `listen answers pull over HTTP…` | covered | A drain error closing with `1011` and a failed negotiation closing with `1002` are asserted in `HTTP classifies native failures by code…` (fake native). Upgrade refusals (`401`, `503` while closing) are not asserted. |
| Server behind a reverse proxy: HTTP forwarded, WebSocket upgrade relayed at the TCP level, `Authorization` preserved; a stripped header is `401` and a refused upgrade ([Transport §7](../../architecture/server/connection/transport.md)) | `a reverse proxy forwarding HTTP and the WebSocket upgrade with headers serves push, pull and live; a stripped Authorization header is refused` | covered (in-process proxy) | TLS termination and real proxy products are not exercised; see [Deploy the backend](../../../../website/docs/backend/deployment.md). |
| Reconnect after the server closes the socket, with backoff | e2e pause/resume only | partial | No test closes the socket from the server side and observes the client's retry cadence; the driver's backoff is unit-tested in Rust, the composition is not. |
