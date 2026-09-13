# How state moves

A local-first client reads its local database. A user edit can become visible immediately, while a durable Mutation records the intent that still needs backend processing. The authoritative result arrives through Pull and is reconciled with remaining local work.

## Model, Record and Identity

A **Model** describes client data. A **Record** is one instance, identified by an **Identity** that can contain one field or several fields.

These are client-facing shapes. A Loader may assemble one Record from several backend tables, or expose several Models from the same business data. The Rust runtime receives schema descriptors; generated TypeScript and Dart types provide the language-facing API.

See the [compiler guide](crates/compiler/README.md) for supported declarations and generated types.

## Mutation and local state

A **Mutation** describes a named business operation. Its optimistic operations update the locally visible result, while the queue retains the work needed for backend processing. A dirty record's sparse before image holds the authoritative base used when replaying pending changes.

For example, editing a title while offline makes that title visible locally. If a remote update then arrives, the client updates the authoritative base and replays pending local operations. Pending local fields may therefore continue to be visible until their mutations settle or are rejected.

Direct local writes and local companions have their own roles. A direct write is separate from a server mutation's fate; a companion participates in a mutation's fate without being uploaded. The framework does not rerun arbitrary application callbacks to reconstruct optimistic state.

## Handler, Loader and Publish

The TypeScript backend SDK connects three operations to your application:

| Primitive | Application responsibility |
| --- | --- |
| **Handler** | Execute a named Mutation against your business data, including business authorization. |
| **Loader** | Return current, complete, visible state for the requested identities, in their supplied order. Return null for missing or unauthorized rows. |
| **Publish** | Explicitly identify changed Records and the Channels that should receive invalidations. |

The application provides the transaction runner. Batch processing uses one outer transaction with per-mutation savepoints; business writes, publication and receipts participate in that transaction. A business rejection can roll back one mutation's savepoint. Unexpected failures abort the batch.

Background jobs can also publish inside an existing application transaction. A publication inside that transaction is not proof of commit: use the SDK's completion check and invoke the returned notification hook only after the transaction resolves.

The [backend SDK guide](packages/server/README.md) shows both registration and transaction-bound publication. The first adapter targets [Prisma/PostgreSQL](packages/persistence-prisma/README.md).

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

A server may normalize the title or reject the edit. Rejections are retained in the local inbox so the application can explain the result to the user. See [recovery](docs/architecture/compatibility-and-recovery.md) for retry and rejection handling.

## Current limits

- A Record may be claimed through multiple Channels, but the first version has no cross-channel Record Revision or total ordering. Late responses can still expose the existing overlapping-channel limitations.
- The reference client's per-change malformed Pull skip behavior is retained. A cursor is not an unconditional proof that every malformed change was applied successfully.
- Live wakeups are process-local. Multi-process deployments need an application-provided committed notification mechanism.
- The SQLite implementation keeps a full in-memory state snapshot and creates an isolated projection for read-only SQL. Production-scale cache performance requires measurement.

The [implementation record](docs/implementation-progress.md) distinguishes verified behavior from planned work. [Next things](docs/next-things.md) preserves future proposals, including Record Revisions, without making them current guarantees.
