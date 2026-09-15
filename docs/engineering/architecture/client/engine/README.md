# Engine

The engine is the client's sync logic. It has no memory between calls: every operation runs in a store transaction and leaves its state in tables.

- [Local operations](local-operations/README.md) — Local reads, writes and transactions.
- [Push](push/README.md) — Queue mutations, track dependencies and freeze batches.
- [Pull](pull.md) — Apply server changes and advance cursors.
- [Settlement](settlement.md) — Complete a batch from its receipt: stage the returned authority by stamp, roll back rejections and replay pending changes.

## How the parts work together

One local edit passes through all four:

1. **Write.** [Local operations](local-operations/README.md) applies the edit to the visible table, keeps the server's last row in a before image, and stores the mutation in the queue.
2. **Push.** [Push](push/README.md) decides when the mutation may be sent, freezes it with others into a numbered batch, and hands the bytes to the connection.
3. **Settlement.** The server answers with a receipt that carries the final content and stamp of every record the batch changed. [Settlement](settlement.md) completes the batch from that receipt alone, in one transaction: the authority is staged beneath the pending operations by stamp, the completed mutation is removed, and the row is rebuilt so the visible row is the server's row with only the newer pending edits, if any, on top. A rejection instead removes the mutation and rebuilds the row from the before image without it. No channel is awaited.
4. **Pull.** If the handler also published the record, a page arrives on that channel, later or earlier; [Pull](pull.md) applies it through the same authority applier and advances the channel's cursor. The page carries the same stamp as the receipt, so whichever arrives second rewrites nothing. While the record is still dirty, a page's newer row becomes the new before image and the visible row is rebuilt at once: before image plus the pending edits replayed on top.

Two counters keep this honest and never mix: the channel cursor orders pages within a subscription; the record stamp orders content across every path that delivers it, receipt or page. Both are explained in [Pull](pull.md).
