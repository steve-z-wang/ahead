# Engine

The server engine is pure protocol logic in Rust: it never opens a connection or a transaction itself, but drives the host through a fixed set of operations.

- [Push](push.md) — Validate and deduplicate mutation batches, invoke handlers and produce receipts.
- [Pull](pull.md) — Find changes by channel cursor and invoke loaders to return records.
- [Notify](notify.md) — Record changed records and channels, and update cursors and stamps.

## How the parts work together

A handler run by [Push](push.md) calls `notify` for the records it changed. [Notify](notify.md) turns each call into a new position in the channel (the *cursor*) and a new version number on the record (the *stamp*), stored in the invalidation table. Push then reads each notified channel's head and puts it in the receipt as the checkpoint the client must reach. When a client pulls that channel, [Pull](pull.md) scans the invalidation table past the client's cursor, asks the loader for the current rows, and returns them with their stamps. The client settles the mutation once its cursor reaches the checkpoint, and applies content in stamp order, so the same record can be published to several channels without conflict.
