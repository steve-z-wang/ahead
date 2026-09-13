# Compatibility and recovery

This source alpha uses a new local SQLite layout. Open a new database path; do not point it at an Oasis database. The historical implementation remains available in Git history at commit `989c4c769b1d41b4b3276f8c97f6bd8ef9eb4fb8`. Moving an existing application requires draining its pending writes or a separately designed importer; this version does not delete or convert the old database.

## Boundaries

| Boundary | First-version contract |
| --- | --- |
| Wire names | Legacy `scope`, `syncId`, `requiredScope`, `requiredSyncId` and `requiredCheckpoints`; public APIs use Channel, Cursor and Checkpoint. |
| Numbers | JSON integers within the JavaScript safe range. Counter encoding is unchanged. |
| Mutation versions | The compiler retains historical input snapshots; the backend registers every supported name/version. Unsupported versions fail before handlers execute. |
| Additive schema evolution | New nullable fields can be received by old schemas. Unknown received fields are ignored; Loader output is validated against its declared schema. |
| Existing local cache | On open the client reconciles PRAGMA table_info against the schema: missing columns are added (non-nullable ones need a schema default), identity or storage-type changes refuse to open. Queued operation rows are never rewritten. |
| Channel overlap | Records carry an optional content stamp; a stamped change is applied only when newer than the local stamp. A delete applies across channels; the remaining claims are the channels whose copy of the delete has not arrived. Issue #8 makes the stamp mandatory. |
| Browser | The JavaScript SDK uses native Node bindings. WASM/browser persistence is not supported yet. |

## Application recovery

- A lost Push response is retried by re-encoding the same push sequence from the queued operations. The backend replays the stored receipt for a repeated `(clientId, sequence)` without inspecting the body, so one client identity must never push from two databases; the second database's push would receive the first one's receipt.
- A received ACK keeps optimistic changes until the required Pull checkpoints arrive. Diagnose channel access/publication and connectivity before attempting to clear local state.
- A subscription is a row in the client's subscription table; only subscribed channels are pulled. A push checkpoint on a channel the client is not subscribed to cannot be awaited and settles immediately; subscribe to that channel before pushing if the client must observe server truth for it.
- Business rejections appear in the durable inbox. Display the code, inspect `recordStatus`, and dismiss the rejection after the user has seen it. A new edit is a new mutation.
- Failed prerequisite work remains visible locally. The host retries by returning its readiness key to `pending` and running its prerequisite callback again. Callbacks must tolerate retries after restart.
- SQLite commits use a generation check. A stale writer fails instead of overwriting a newer commit. Use one active Client per local database; close and reopen a stale instance before retrying application work.
- External business transactions use a bound publisher, check `assertCommittable()` inside the transaction, capture `notify = session.afterCommit()` before closing the session, then invoke `notify()` after the application transaction resolves. This wakes subscribers in the current process. Multi-process deployments must forward committed channel notifications through their own infrastructure.
- Permission changes require publication of the resulting visibility changes. Unsubscribing is not a substitute for server-side authorization or withdrawal.
- One database file per signed-in user. The client stores no owner; opening another user's file shows that user's cache and pushes with their client id.

Do not manually delete pending batches, before images, cursors or framework receipt rows to resolve an error. Their relationship is part of the settlement/retry protocol. Keep a database backup for diagnosis. There is no automatic protocol reset or garbage collector in this version.

## Capacity

Server invalidations compact by channel/model/identity, but distinct identities and client receipts still accumulate. Local queued mutations, rejection details and cached records persist. No TTL bounds those tables. Unsubscribing stops desired synchronization. Cached records and claims persist until authoritative withdrawal or other existing cleanup; it does not impose a global cache size limit.

Reads, including raw SQL, run against the on-disk tables through a read-only connection; no query copies the record set. These choices are suitable for validating behavior; they are not evidence of production-scale throughput. Measure your working set before rollout and track database size, pending age/count, rejected items and Pull lag.
