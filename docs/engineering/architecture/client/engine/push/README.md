# Push

Prepare durable mutations for delivery. Network scheduling belongs to [Connection](../../connection/README.md); receipts and rollback belong to [Settlement](../settlement.md).

- [Queue](queue.md) — Persist mutations, operations and their ordering.
- [Dependencies](dependencies.md) — Decide which mutations are eligible to send.
- [Batching](batching.md) — Freeze eligible mutations and preserve their bytes for retries.

## How the parts work together

One push starts when the connection asks the engine to *freeze*. [Batching](batching.md) first checks the [queue](queue.md) for a batch that was sent but has no receipt yet; if there is one, it re-encodes that batch from its stored rows and returns the same bytes, which is how a lost response is retried without a second execution. Otherwise it walks the unsent mutations in ordinal order and asks [Dependencies](dependencies.md) about each one: a mutation waits while a prerequisite is unready, while a lifecycle parent has not been acknowledged, or while a sequence predecessor is neither sent nor chosen for this batch; an independent later mutation may be taken instead. Up to twenty eligible mutations that fit the byte budget receive the next push number in the queue, and their wire operations (never companions or cascade effects) are encoded into one request. From then on the batch is immutable until its receipt arrives and [Settlement](../settlement.md) removes it.
