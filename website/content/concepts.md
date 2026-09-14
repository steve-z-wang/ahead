# How state moves

A local-first client reads its local database. A user edit can become visible immediately, while a durable Mutation records the intent that still needs backend processing. The authoritative result arrives through Pull and is reconciled with remaining local work.

## Model, Record and Identity

A **Model** describes client data. A **Record** is one instance, identified by an **Identity** that can contain one field or several fields.

These are client-facing shapes. A Loader may assemble one Record from several backend tables, or expose several Models from the same business data. The Rust runtime receives schema descriptors; generated TypeScript and Dart types provide the language-facing API.

See the [compiler guide](schema/reference.md) for supported declarations and generated types.

## Mutation and local state

A **Mutation** describes a named business operation. Its optimistic operations update the locally visible result, while the queue retains the work needed for backend processing. A dirty record's sparse before image holds the authoritative base used when replaying pending changes.

For example, editing a title while offline makes that title visible locally. If a remote update then arrives, the client updates the authoritative base and replays pending local operations. Pending local fields may therefore continue to be visible until their mutations settle or are rejected.

Direct local writes and local companions have their own roles. A direct write is separate from a server mutation's fate; a companion participates in a mutation's fate without being uploaded. The framework does not rerun arbitrary application callbacks to reconstruct optimistic state.

## Handler, Loader and Notify

The TypeScript backend SDK connects three operations to your application:

| Primitive | Application responsibility |
| --- | --- |
| **Handler** | Execute a named Mutation against your business data, including business authorization. |
| **Loader** | Return current, complete, visible state for the requested identities, in their supplied order. Return null for missing or unauthorized rows. |
| **Notify** | Explicitly identify changed Records and the Channels that should receive invalidations. |

The application provides the transaction runner. Batch processing uses one outer transaction with per-mutation savepoints; business writes, notification and receipts participate in that transaction. A business rejection can roll back one mutation's savepoint. Unexpected failures abort the batch.

Background jobs can also notify inside an existing application transaction. A notification inside that transaction is not proof of commit: use the SDK's completion check and invoke the returned notification hook only after the transaction resolves.

The [backend SDK guide](backend/setup.md) shows both registration and transaction-bound notification. The first adapter targets [Prisma/PostgreSQL](backend/prisma.md).

## Channel, Cursor and Checkpoint

A **Channel** is an explicitly named distribution scope, such as a shared book. Clients subscribe to Channels; the backend publishes invalidations to them. A Channel may contain several Models.

A **Cursor** is the client's receive position within a Channel. A **Checkpoint** is a position that must be reached before accepted work can settle. Numbers from different Channels are not comparable.

Channels distribute access to current state. They are not event logs that promise delivery of every historical intermediate value. Pull uses Loaders to obtain the current authoritative content for invalidated identities.

## Why ACK does not immediately remove optimism

Consider one pending title edit:

1. The client writes the optimistic title and persists the Mutation.
2. Push sends a frozen request. If the result is unknown, a retry uses the same persisted request bytes and batch sequence.
3. The server commits the business change and its receipt. ACK reports acceptance and the required checkpoints.
4. Pull applies authoritative state. When the required checkpoints are satisfied, the ready accepted prefix settles and remaining pending work is replayed.

ACK and Pull can arrive in either order. If Pull arrives first, the stored cursor can satisfy the checkpoint when ACK later arrives. If ACK arrives first, optimism remains until the required Pull progress is applied under the existing settlement rules.

A server may normalize the title or reject the edit. Rejections are retained in the local inbox so the application can explain the result to the user. See [recovery](frontend/storage.md) for retry and rejection handling.

## Stamps across channels

A **Stamp** orders content for one record across channels. When a record is notified, the backend allocates a newer stamp. The client applies a newer value and ignores delayed older content, regardless of which channel delivers it. Equal stamps are idempotent; inconsistent content for the same stamp is a diagnostic condition.

A newer deletion withdraws the record across channels. Its tombstone is retained while other channel claims still need to confirm the deletion. Stamps are required on pull changes; they are separate from each channel's cursor. See the [stamp acceptance tests](https://github.com/steve-z-wang/ahead/blob/main/crates/sqlite/tests/stamp_scenarios.rs) for the ordering cases.

## Local reads and sync reads

`get`, `query`, relation accessors, raw SQL and `watch` read local SQLite through the Rust engine. They do not call a loader. Read-only SQL uses the on-disk tables rather than copying the full record set into a separate projection.

The backend's loader is the sync read path: after notification identifies changed records, it supplies their current authorized contents. This separation lets your local record schema differ from your backend database layout.

## Current limits

- A malformed pull change can be skipped while the cursor advances. A cursor is not an unconditional proof that every malformed change was applied successfully.
- Live wakeups are process-local. Multi-process deployments need an application-provided committed notification mechanism.
- Generated clients currently use HTTP sync; the backend has WebSocket support, with built-in client integration tracked in [issue #35](https://github.com/steve-z-wang/ahead/issues/35).
- Production-scale cache performance requires measurement with your working set.

See [sync and recovery](frontend/sync.md) for application behavior and [local storage](frontend/storage.md) for storage constraints.
