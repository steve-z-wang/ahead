# Concepts and Naming

> Historical design record (2026-09-10): status statements and proposed APIs below reflect the original planning stage. See [implementation evidence](../implementation-progress.md) for the current delivered scope and verified limitations.

2026-09-10: The user has confirmed the following names. They apply to the new Rust implementation, language SDKs, proposed interfaces, and current design documents. Naming changes do not alter the reference implementation's behavior; this branch currently contains documentation only.

## Unified terminology

| Old name | Confirmed name | Meaning |
|---|---|---|
| Model | Model | A client data model; it does not have to correspond to one backend table. |
| Record | Record | One item of data for a Model. |
| Identity | Identity | A single-field or composite identity that identifies a Record within one Model. |
| Mutation | Mutation | A business operation submitted by the client that may be shown optimistically first. |
| Handler | Handler | The backend implementation of a Mutation supplied by the application author. |
| Materializer | Loader | Given context and identities, reads, aggregates, or transforms current backend data and returns authoritative client state. |
| Scope | Channel | An explicitly named, dynamically subscribable distribution scope with independent receive progress. |
| Publish | Publish | Explicitly declares to Channels which Records changed and persists the invalidation within the user's transaction. |
| Client | Client | The entry point for querying, observing, and modifying local state on the frontend. |
| Persistence | Persistence | The persistence contract; names such as PrismaPersistence and SqlitePersistence identify concrete implementations. |
| Uplink / Downlink | Push / Pull | The paths and internal modules for sending pending operations / fetching authoritative changes. |
| Sync ID | Cursor / Checkpoint | Cursor represents the current position; Checkpoint represents a position required for operation settlement. |

## API and module naming

- Use singular `channel` and plural `channels`; an application constructor might be `bookChannel(bookId)`.
- Call the callback a `Loader`; the proposed registration entry point is `Entry.loader(...)`, and the dispatch interface is `LoaderDispatcher`. If the optional Nest decorator is implemented, use `@Loads`, corresponding to the operation decorator `@Handles`.
- Paths use `push` / `pull`, and types use `Push…` / `Pull…`; for example, `PullPage`.
- `ChannelCursor` represents the current position in a Channel; `ChannelCheckpoint` represents a position that must be reached. The Channel must be carried explicitly or determined from context; bare numbers detached from their Channels cannot be compared.
- `requiredCheckpoints` are settlement conditions; the conceptual name does not determine the exact wire-property spelling.
- `ServerPersistence` / `TransactionPersistence` and `ClientStore` / `ClientTransaction` retain their distinct responsibilities. The default client SQLite adapter crate remains `lfs-sqlite`; storage interfaces do not all need to be forcibly renamed merely to match the glossary.

The following only illustrates the names. Complete callback signatures and registration mechanisms will be determined during implementation:

```ts
Entry.loader(async (ctx, identities) => {
  return entries.readVisible(ctx, identities);
});

// store is bound to the application transaction; see the architecture for Handler batch deduplication and receipts.
await publisher.publish(store, {
  channels: [bookChannel(bookId)],
  model: Entry,
  identity: { id: entryId },
});
```

## Semantic boundaries

Channel is used for distribution and is not part of Record Identity. One Channel may contain multiple Models. The existing behavior for one Record in multiple Channels is preserved from the reference implementation; renaming does not promise to solve cross-Channel reordering.

Publish declares changes, while Pull uses a Loader to read the current complete authoritative state. A Channel is not an event log that guarantees delivery of every historical change. The Loader name also adds no new read-only restriction: existing prepareForViewer behavior, identity alignment, visibility, and transaction contracts are preserved.

Push/Pull describes the direction of data flow; it does not restrict scheduling to HTTP/WS or notification-driven approaches. Calling it Pull does not change it to polling only. A Mutation ACK must still be combined with required checkpoints and the original accepted-prefix rule before optimism can be removed.

Cursor and Checkpoint may use the same position value, but serve different purposes. Publishing increments the persistent counter/head for each Channel; it is neither a new global counter nor a Record Revision. Cursors from different Channels cannot be compared for recency.

## Old names and compatibility boundaries

This round updates designs, proposed APIs, and future module names. Real paths, symbols, and references in reviews of the old source retain their original names so they remain locatable in the reference commit. Old wire fields, database columns, persisted data, and historical fixtures are not renamed automatically; new API/internal symbols map to the existing representations at the boundary. Any future wire/storage change must separately document compatibility and migration.

New record revision, cross-Channel arbitration, and other semantic changes appear in [Next things / TODO](../next-things.md); they are not part of this renaming.
