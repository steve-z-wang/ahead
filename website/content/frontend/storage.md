# Local storage

Savoia stores cached records, queued mutations, channel progress and rejection details in a local SQLite file. This page explains how to manage that file and recover from storage or synchronization failures.

The Savoia rename preserves the existing SQLite layout, including internal `ahead_` tables. Reopen the same file to retain queued mutations, client identity and channel progress; renaming the framework does not require resetting local data.

## Choose a database path

Choose a writable directory owned by your application. Use one active client per file and a separate file per signed-in user. Closing the client releases its connection and native resources; reopening the same file preserves local records and pending work.

The database contains a persistent client identity used for request deduplication. Do not let independently writable copies of the same file send mutations to the same backend. Switch accounts by closing the current client and opening the appropriate user's file, rather than changing only its authentication token.

## Change the schema

The local runtime checks the database against the generated schema when opening it. Missing columns can be added; required fields need values supplied through migration defaults. Unsupported identity or storage-type changes fail to open.

The `migration` option supplies field defaults and can request a pull replay when the descriptor changes. The operation is atomic and preserves queued mutations and frozen request bytes. See [opening and schema changes](runtime.md#opening-and-schema-changes) for the option's usage. Update your backend tables separately through your database's migration process.

## Recover pending work

| Situation | What to do |
| --- | --- |
| A request times out | Let sync retry the persisted frozen request. The backend may already have committed it. |
| Accepted work remains pending | Check connectivity, the required channel, notifications and loader failures. |
| A mutation is rejected | Display its code, inspect `recordStatus`, then dismiss the handled rejection. |
| A prerequisite fails | Resolve its cause, reset its readiness to `pending`, then run its callback again. |
| Another client wrote to the same file | Close the stale instance and reopen it; keep one active client per file. |

Do not manually delete pending batches, channel cursors or backend receipts to clear an error. These records work together to prevent duplicate execution and settle local changes. Preserve the database for diagnosis when an error cannot be resolved through the public APIs.

[Sync and recovery](sync.md) shows the application calls for these cases.

## Manage cached data

Unsubscribing stops desired synchronization; it does not erase cached records. Permissions are enforced by your backend. When a record is no longer visible, notify the affected channels so their loaders can return null.

Pull changes carry a per-record stamp. A newer stamp replaces the record's authoritative state; a delayed lower stamp cannot overwrite it. Deletions apply across channels, with tombstones retained while channel claims still need to confirm them. See [how state moves](../concepts.md) for the relationship between records, channels and pending writes.

## Storage size

Cached records, queued mutations, rejection details and backend receipts persist. The runtime does not impose a cache-size limit or automatically expire these entries. Backend invalidations compact by channel/model/identity, but distinct identities still consume space.

Measure database size, pending work and synchronization lag with your application's working set. Local reads, including read-only SQL, use on-disk SQLite tables. They do not copy the full record set into a separate query projection.
