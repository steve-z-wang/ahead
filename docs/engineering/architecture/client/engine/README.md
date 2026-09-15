# Engine

The engine is the client's sync logic. It has no memory between calls: every operation runs in a store transaction and leaves its state in tables.

- [Local operations](local-operations/README.md) — Local reads, writes and transactions.
- [Push](push/README.md) — Queue mutations, track dependencies and freeze batches.
- [Pull](pull.md) — Apply server changes and advance cursors.
- [Settlement](settlement.md) — Process decoded receipts and cursors to confirm mutations, roll back rejections and replay pending changes.

## How the parts work together

One local edit passes through all four:

1. **Write.** [Local operations](local-operations/README.md) applies the edit to the visible table, keeps the server's last row in a before image, and stores the mutation in the queue.
2. **Push.** [Push](push/README.md) decides when the mutation may be sent, freezes it with others into a numbered batch, and hands the bytes to the connection.
3. **Pull.** The server answers with a receipt naming a checkpoint per channel, and separately publishes the record; [Pull](pull.md) applies the published page and advances the channel's cursor. While the record is dirty, the server's row becomes the new before image and the visible row is rebuilt at once: before image plus the pending edits replayed on top.
4. **Settlement.** Once every checkpoint is reached, [Settlement](settlement.md) removes the mutation and rebuilds the row again, so the visible row is now the before image with only the newer pending edits, if any, on top. A rejection instead removes the mutation and rebuilds the row from the before image without it.

Two counters keep this honest and never mix: the channel cursor orders pages and witnesses settlement; the record stamp orders content. Both are explained in [Pull](pull.md).
