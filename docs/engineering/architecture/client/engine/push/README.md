# Push

Prepare durable mutations for delivery. Network scheduling belongs to [Connection](../../connection/README.md); receipts and rollback belong to [Settlement](../settlement.md).

- [Queue](queue.md) — Persist mutations, operations and their ordering.
- [Dependencies](dependencies.md) — Decide which mutations are eligible to send.
- [Batching](batching.md) — Freeze eligible mutations and preserve their bytes for retries.
