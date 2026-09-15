# Connection

The connection is how the client reaches a server: the network calls themselves, and the logic that decides when to make them.

- [Transport](transport.md) — Send and receive HTTP/WebSocket messages.
- [Controller](controller/README.md) — Decide when to push, when to stream, when to catch up and when to retry; coordinate subscriptions, cancellation, reconnect and authentication refresh.
