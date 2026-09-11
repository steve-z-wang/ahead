# Compatibility and recovery

This source alpha uses a new local SQLite layout. Open a new database path; do not point it at an Oasis database. The historical implementation remains available on `main`. Moving an existing application requires draining its pending writes or a separately designed importer; this version does not delete or convert the old database.

## Boundaries

| Boundary | First-version contract |
| --- | --- |
| Wire names | Legacy `scope`, `syncId`, `requiredScope`, `requiredSyncId` and `requiredCheckpoints`; public APIs use Channel, Cursor and Checkpoint. |
| Numbers | JSON integers within the JavaScript safe range. Counter encoding is unchanged. |
| Mutation versions | The compiler retains historical input snapshots; the backend registers every supported name/version. Unsupported versions fail before handlers execute. |
| Additive schema evolution | New nullable fields can be received by old schemas. Unknown received fields are ignored; Loader output is validated against its declared schema. |
| Existing local cache | A changed descriptor requires an explicit additive migration. Defaults fill missing fields atomically. Frozen requests remain byte-for-byte unchanged. Identity/type conversion and removal are rejected. |
| Channel overlap | Channel cursors are independent. There is no cross-channel record revision or total order. Original claim and arrival-order limitations apply. |
| Browser | The JavaScript SDK uses native Node bindings. WASM/browser persistence is not supported yet. |

## Application recovery

- A lost Push response is retried with the stored bytes and batch sequence. Keep the same local database and client identity; the backend receipt prevents a second business execution.
- A received ACK keeps optimistic changes until the required Pull checkpoints arrive. Diagnose channel access/publication and connectivity before attempting to clear local state.
- Business rejections appear in the durable inbox. Display the code, inspect `recordStatus`, and dismiss the rejection after the user has seen it. A new edit is a new mutation.
- Failed prerequisite work remains visible locally. The host retries by returning its readiness key to `pending` and running its prerequisite callback again. Callbacks must tolerate retries after restart.
- SQLite commits use a generation check. A stale writer fails instead of overwriting a newer commit. Use one active Client per local database; close and reopen a stale instance before retrying application work.
- External business transactions use a bound publisher, check `assertCommittable()` inside the transaction, capture `notify = session.afterCommit()` before closing the session, then invoke `notify()` after the application transaction resolves. This wakes subscribers in the current process. Multi-process deployments must forward committed channel notifications through their own infrastructure.
- Permission changes require publication of the resulting visibility changes. Unsubscribing is not a substitute for server-side authorization or withdrawal.

Do not manually delete pending batches, before images, cursors or framework receipt rows to resolve an error. Their relationship is part of the settlement/retry protocol. Keep a database backup for diagnosis. There is no automatic protocol reset or garbage collector in this version.

## Capacity

Server invalidations compact by channel/model/identity, but distinct identities and client receipts still accumulate. Local queued mutations, rejection details and cached records persist. No TTL bounds those tables. Unsubscribing stops desired synchronization. Cached records and claims persist until authoritative withdrawal or other existing cleanup; it does not impose a global cache size limit.

The current SQLite adapter materializes the state in memory and commits changed documents. Read-only SQL creates an isolated projection per query. These choices are suitable for validating behavior; they are not evidence of production-scale throughput. Measure your working set before rollout and track database size, pending age/count, rejected items and Pull lag.
