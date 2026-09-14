# Notify

Record changed records and channels, and update cursors and stamps.

Current code: [server/lib.rs](../../../../../crates/server/src/lib.rs) (`publish`); buffering, `Session.touched` and the `WakeHub` in [server/index.mts](../../../../../packages/server/index.mts) (`notify` inside `handle`, `publish`, `bindTransaction`, `run`).

## 1. Introduction and Goals

- Make every change the application reports visible to pull as a channel position with a per-record stamp, in the transaction that made it, and wake live subscribers only once that transaction has committed.

## 3. Context and Scope

- Application input: `notify({channel, records})` inside a handler (buffered, published after the handler returns), or `backend.notify(tx, …)` / `bindTransaction(tx).notify(…)` outside a push (awaited).
- Rust input: `publish(config, changes, channels, host)`: `changes` are `{model, identity}` refs, `channels` a list.
- Host operation: `publish {channel, model, identity, identityKey}` → `{cursor, stamp}` ([Persistence](../persistence.md)).
- Output: `[{scope, syncId: head}]` per channel to the SDK; `touched` channels per transaction; a wake per channel after commit ([Server / Connection / Controller](../connection/controller.md)).

## 5. Building Block View

- `publish`: validates every model has a registered loader, dedupes records by encoded key, then for each channel and each record calls the host `publish` and checks the returned cursor and stamp are positive counters; finally reads the head per channel.
- Ordering: the SDK publishes buffered `notify` calls in call order, one call per `{channel, records}` item, so stamps reflect the handler's notify order (guarantee D3).
- Per-record stamp and per-channel head are independent counters allocated by persistence; the invalidation row is upserted at the new cursor with the new stamp ([Server Pull](pull.md) compaction).
- `Session.touched`: channels published in this transaction; snapshotted at each mutation `savepoint` and restored on `rollback`, so a rejected mutation's channels do not wake anyone; after `database.transaction` resolves, `run` calls `wakes.notify(touched)`.
- `WakeHub`: in-process map from channel to wake callbacks registered by live sockets; `notify` schedules each callback as a microtask.

## 6. Runtime View

- Inside a push: handler → buffered notifies → `publish` per item → checkpoint = head of the settlement channel after publication → receipt → commit → wakes.
- Outside a push with `bindTransaction`: `notify` (awaited) → `assertCommittable` → commit → the application must call the function returned by `afterCommit()` to wake subscribers.

## 10. Quality Requirements

- D3 and stamp allocation: [server/tests/stamp.rs](../../../../../crates/server/tests/stamp.rs) `publish_requires_cursor_and_stamp_from_the_host`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `publish allocates one stamp per notify and stores it on the invalidation row`, `concurrent notifies of one record receive distinct stamps`, `rejected mutation publishes nothing even though it called notify first`, `publication rollback uses user transaction and rejects unregistered models`, `handler awaiting the tx after notify still drains pending publication before checkpoint`, `live transport negotiates, wakes only after commit, reconnects, and cleans up`.

## 11. Risks and Technical Debt

- **Confirmed limitation: wakes are in-process only.** `WakeHub` is a map in one Node process; a second server instance, or a publication from a different process, never wakes this process's live sockets, and those clients see the change only when they reconnect and catch up (guarantee N6). Evidence: `WakeHub` in [server/index.mts](../../../../../packages/server/index.mts). No issue tracks horizontal scaling or an external pub/sub.
- **Confirmed limitation: the unbound `backend.notify(tx, …)` never wakes anyone.** It creates a throwaway `Session`, so `touched` is lost; only `bindTransaction(tx)` plus an explicit `afterCommit()` call wakes subscribers, and nothing warns when the shortcut is used. Evidence: `publish` (`sessions.get(tx) ?? new Session()`), `api.notify`; asserted in [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) (`commit alone requires the explicit external after-commit hook`); the example backend uses the shortcut in [examples/rust-round-trip/server.mts](../../../../../examples/rust-round-trip/server.mts). Whether the shortcut should be removed or documented needs deciding.
- **Potential risk: hot channels serialize on one row.** Every publication to a channel updates the same `ahead_channel` row under row locks, and every publication of one record updates its `ahead_record` row; concurrent handlers touching the same channel contend and may retry on serialization failure. Evidence: [persistence-prisma/index.mts](../../../../../packages/persistence-prisma/index.mts) `publish`. Not measured ([#12](https://github.com/zanminwang/ahead/issues/12)).
