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
