# Client

The client runtime keeps local state in SQLite and synchronizes it with a server.

- [Frontend interface](frontend-interface.md) — Expose reads, writes, subscriptions and status to SDKs.
- [Engine](engine/README.md) — Local reads and writes, mutations, cursors, rollback and settlement.
- [Storage](storage/README.md) — Execute Engine-requested SQL and transactions; no sync policy.
- [Connection](connection/README.md) — HTTP/WebSocket, catch-up and reconnect.

## How the parts work together

An SDK talks only to the [frontend interface](frontend-interface.md), one command at a time. Each command runs in a [storage](storage/README.md) transaction and is carried out by the [engine](engine/README.md), which owns every rule about optimism, queueing, cursors and settlement. The [connection](connection/README.md) is the engine's link to the network: it asks the engine what to send and hands back what arrives, but never decides anything about the data. Because all state lives in tables, a client can be closed at any commit and reopened without losing queued work, receipts or cursors.
