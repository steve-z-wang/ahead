# Record stamp design

2026-09-12. Design record for issue #8. Every record delivered by Pull carries a per-record content version called the **stamp**. The client applies content strictly by stamp, so a delayed page from one channel can no longer overwrite newer content that arrived through another channel. Channel cursors keep their current job of ordering delivery on one channel and witnessing settlement.

This design assumes the loader surface merged in #5 (PR #10) and the client tables designed in #9 (`docs/superpowers/specs/2026-09-12-client-storage-design.md`). It is written against the #9 design branch and is rebased once #9 merges.

## Why

The same record, identified by `(model, identity)`, can reach a client through several channels. Each channel has its own cursor, which orders delivery on that channel and nothing else. Two responses for the same record from different channels are not comparable today:

1. A Pull on channel A reads `Task t1` and its response is delayed on the network.
2. `t1` is edited. A Pull on channel B reads the new content and reaches the client first.
3. A's delayed response arrives and overwrites the newer content. Pending local edits then replay over the wrong base.

Since #5 the loader receives the requesting `channel` and may legitimately return different content for the same record on different channels. The client therefore needs a rule for which content wins that does not depend on arrival order.

## Goals

- A delayed or reordered page never regresses a record's content.
- One comparison on the client decides whether content is applied. No arrival-order reasoning, no per-channel content bookkeeping.
- The server allocates versions inside the application's transaction, with no global lock and no new coordination between channels.
- Push, receipts, checkpoints, settlement and the accepted-prefix rules are untouched.

## Naming

The version is called **stamp**, wire field `stamp`. `revision` suggests a browsable history; a stamp is a monotonic number used only for comparison. `version`, `generation`, `sequence` and `epoch` already name other concepts in this codebase.

## Two numbers, each with one job

| Value | Scope | Ordered by | Compared against |
| --- | --- | --- | --- |
| Channel cursor (`syncId`) | one channel | delivery on that channel | the client's cursor for that channel |
| Stamp | one `(model, identity)` | content freshness across channels | the client's last accepted stamp for that record |

Stamps of different records are not comparable. Cursors of different channels are not comparable. Neither number is derived from the other.

## Allocation: one stamp per notify

Every `notify` for a record allocates a new stamp for that record, including several calls for the same record inside one transaction and one call fanning out to several channels. The Rust `publish` already issues one host `publish` request per `(channel, record)`; each of those requests increments the record's stamp.

Consequences:

- The stamps of one record form a total order across all channels. Two channels never deliver the same record with the same stamp.
- A handler that notifies `t1` to A and then to B produces stamp 7 on A and stamp 8 on B. If the loader returns different content for the two channels, the client ends up with B's content because 8 > 7. The order of `notify` calls in the handler decides.
- There is no "reuse the stamp within a transaction" rule and no per-transaction memo.

## Always on

Every record delivered by Pull carries a stamp from creation. There is no dynamic enablement and no compatibility path for unstamped records: a page whose change lacks `stamp` is rejected the same way a page lacking `state` is today. The source alpha already declares the local database format incompatible, so this is the one window where always-on costs no migration. Optional stamps would require fencing rules for in-flight pages, cached before images and frozen pushes that are more complex than the feature itself.

## Wire

`RecordChange` gains one required integer field `stamp`, a safe integer greater than zero. Nothing else changes.

```json
{
  "scope": "A",
  "fromCursor": 9,
  "toCursor": 12,
  "changes": [
    { "syncId": 10, "model": "Task", "identity": { "id": "t1" }, "stamp": 7, "state": { "id": "t1", "title": "Write docs", "done": false } },
    { "syncId": 12, "model": "Task", "identity": { "id": "t2" }, "stamp": 3, "state": null }
  ]
}
```

| Field | Client use |
| --- | --- |
| `scope` | which `otter_subscription` and `otter_claim` rows |
| `fromCursor`, `toCursor` | page continuity, unchanged |
| `syncId` | in-page order and cursor advance, unchanged |
| `model`, `identity` | the record key |
| `stamp` | compared with `otter_record.stamp` |
| `state` | non-null is an upsert, null is a delete, unchanged |

`crates/core/src/protocol.rs`: `RecordChange` gains `pub stamp: u64`; `validate` applies the same safe-integer rule as `syncId`. `fixtures/protocol/counter-and-checkpoint.json` gains cases for a missing, zero, negative and overflowing `stamp`.

## Server

### Tables

`packages/persistence-prisma/migration.sql` after this change:

| Table | Key | Columns |
| --- | --- | --- |
| `otter_client` | `client_id` | `owner_id, sequence, request_hash, receipt` (unchanged) |
| `otter_channel` | `channel` | `head` (unchanged) |
| `otter_record` | `(model, identity_key)` | `stamp` (new table) |
| `otter_invalidation` | `(channel, model, identity_key)` | `identity, cursor, stamp` (new `stamp` column), plus `UNIQUE(channel, cursor)` |

```sql
CREATE TABLE IF NOT EXISTS otter_record (
 model text NOT NULL,
 identity_key text NOT NULL,
 stamp bigint NOT NULL CHECK(stamp > 0 AND stamp <= 9007199254740991),
 PRIMARY KEY(model,identity_key)
);
ALTER TABLE otter_invalidation ADD COLUMN stamp bigint NOT NULL CHECK(stamp > 0 AND stamp <= 9007199254740991);
```

The migration file is rewritten rather than appended; the alpha has no migration path.

`otter_invalidation` is not a log. It holds one row per record per channel, and `notify` moves that row's `cursor` to the new channel head. Consequently the row's `stamp` is always the stamp of the latest notification of that record on that channel, and a Pull page never contains the same record twice.

### `publish`

The host `publish` request, per `(channel, record)`, inside the handler's transaction:

1. `INSERT INTO otter_record(model,identity_key,stamp) VALUES($1,$2,1) ON CONFLICT(model,identity_key) DO UPDATE SET stamp=otter_record.stamp+1 RETURNING stamp`. The row lock serialises concurrent notifies of one record; two transactions cannot allocate the same stamp.
2. Increment `otter_channel.head` as today.
3. Upsert the `otter_invalidation` row with `identity`, the new `cursor` and the new `stamp`.

The request returns `{ cursor, stamp }` instead of the bare cursor. The Rust `publish` validates both as safe counters. The `SyncEvent` value returned to the host (`{ scope, syncId }`) is unchanged.

### `scan` and `process_pull`

`scan` returns the extra `stamp` column. `process_pull` validates it as a safe counter and copies it into `RecordChange.stamp`. The loader is called as today, with the row's channel; the stamp is not read from `otter_record` at Pull time.

The pair `(stamp, state)` delivered for a row is the stamp written at `notify` time and the content the loader returns now. They describe the same content because of one application rule: **every change to a record is notified to every channel that provides it.** Under that rule, whenever a record changes, each of its rows in `otter_invalidation` moves to a new stamp before any Pull can read the new content, so a row's stamp and the loader's content always belong to the same change.

A handler that edits a record and notifies only some of its channels has a bug. The framework does not detect it and makes no promise about what the other channels deliver; they return their old stamp with whatever the loader reads now. The rule is documented with `notify`, next to the existing rule that a mutation must notify at least one channel.

### Persistence contract

`packages/persistence-prisma/index.mts`: `publish` returns `{ cursor, stamp }`; `scan` rows carry `stamp`. `packages/server` passes both through unchanged. Adapters built on `PrismaPersistence` inherit the change.

## Client

### Tables

From the #9 design, the tables this feature touches:

| Table | Key | Columns | Role |
| --- | --- | --- | --- |
| `X` (one per model) | identity fields | model fields | merged optimistic view |
| `otter_before_X` | same | same | server truth while the row is dirty |
| `otter_record` | `(model, identity)` | `stamp` | last accepted stamp; a row with no `X` row is a tombstone |
| `otter_claim` | `(channel, model, identity)` | | channels that delivered the record and have not delivered its delete |
| `otter_subscription` | `channel` | `cursor` | last applied cursor per channel |

The stamp lives in `otter_record`, one per record, not on the claim rows. The client only needs the largest stamp it has accepted; it does not need to remember what each channel delivered. Putting the stamp on claim rows and taking the maximum would lose the watermark when a delete removes a claim, and a delayed older upsert on the remaining channel could then resurrect the record.

### Apply

One `RecordChange` is one transaction. Inputs: channel `C`, record `K`, stamp `S`, `state`. `L` is `otter_record[K].stamp`, or 0 when the row is absent.

```
apply(C, K, S, state):
  if syncId <= otter_subscription[C].cursor: reject the page

  L = otter_record[K].stamp or 0

  if S > L:
    otter_record[K].stamp = S
    if state != null:
      if otter_before_X has K:  write state to otter_before_X; rebuild(K)
      else:                      upsert state into X
      otter_claim += (C, K)
    else:
      delete K from X and otter_before_X; cascade declared children
      otter_claim -= (C, K)

  else if S == L:
    if state != null and state != local truth of K: diagnostic(K, S, difference)
    if state != null: otter_claim += (C, K)
    else:             otter_claim -= (C, K)

  else:                                   # S < L: stale content
    if state != null: otter_claim += (C, K)
    else:             otter_claim -= (C, K)

  if otter_record has K and X lacks K and otter_claim has no row for K:
    delete otter_record[K]                # tombstone confirmed by every channel

  otter_subscription[C].cursor = syncId
  settle()
  commit
```

As a table:

| Case | Content | `otter_claim` | `otter_record` |
| --- | --- | --- | --- |
| S < L | discarded | upsert adds C, delete removes C | unchanged; tombstone dropped when claims reach zero |
| S = L, same content | no-op | same | unchanged |
| S = L, different content | keep local, diagnostic | same | unchanged |
| S > L, upsert | set truth, rebuild if dirty | add C | stamp = S |
| S > L, delete | delete truth and view, cascade | remove C only | stamp = S; row dropped when claims reach zero |

Rejecting stale content never drops the claim bookkeeping it carries. Page validation, per-change commit and skip-on-failure are unchanged.

### Delete applies across channels

A delete with a newer stamp removes the local record regardless of how many claims remain. The remaining `otter_claim` rows are exactly the channels whose copy of the delete has not arrived yet. Each channel's delete removes its claim; when none remain, the `otter_record` row is dropped. At that point every claiming channel's cursor is past the delete, so an older upsert cannot arrive. There is no TTL and no separate pending set.

The previous behaviour, releasing one claim and deleting only when the last claim leaves, and the earlier `removeFromChannel` proposal in `docs/next-things.md`, are replaced. Channels are notification routes and do not define record content; the claim ledger exists so that unsubscribing a channel can drop records no other channel provides.

A null from the loader has two possible causes: the record is gone, or this viewer may not see it on this channel. The client treats both as a delete. Hiding a record on one channel is a change to that record, so the rule above applies: the handler notifies every channel that provides it. Otherwise the local copy stays absent until the other channel's next notification, which is the application's bug, not the framework's.

### Equal stamp, different content

Because stamps are unique per notification, equal stamps can only come from the same `otter_invalidation` row delivered twice with different loader output, which is a server bug such as a non-deterministic loader. The client keeps its copy, advances the cursor and reports a diagnostic carrying model, identity, stamp and the difference. It does not stall the channel.

### Invariants

Assertable in the client engine:

- `otter_record` has a row and `X` does not: tombstone, and `otter_claim` holds exactly the channels still to confirm.
- `X` has a row: `otter_record` has a row and at least one claim exists.
- `otter_record.stamp` never decreases.
- Every `otter_claim` row belongs to a channel with an `otter_subscription` row.

### Unsubscribe

Unchanged from #9: delete the subscription row, that channel's claims, and every record (main row, before row, `otter_record` row) no other channel claims. Resubscribing pulls from 0.

## Worked example

Handler notifies `t1` to A, then to B, in one transaction.

Server `otter_record`

| model | identity_key | stamp |
| --- | --- | --- |
| Task | t1 | 8 |

Server `otter_invalidation`

| channel | model | identity_key | cursor | stamp |
| --- | --- | --- | --- | --- |
| A | Task | t1 | 10 | 7 |
| B | Task | t1 | 5 | 8 |

Client after pulling A then B: `Task` holds B's content, `otter_record` says 8, `otter_claim` has A and B, `otter_subscription` says A = 10, B = 5.

A later edit notified to both channels moves A's row to `cursor 11, stamp 9` and B's row to `cursor 6, stamp 10`. The client pulls B, applies 10. If a delayed A response with stamp 7 arrives afterwards it is discarded; A's cursor still advances. The next Pull on A delivers stamp 9, which is also discarded.

## Acceptance scenarios

Each is a scenario under `fixtures/scenarios` run by `integration/rust/tests/scenarios.rs`, plus unit coverage where noted.

1. **Delayed page.** Same record through A and B; newer content arrives first through B; A's delayed older page cannot regress content or the visible replayed result. A's cursor advances.
2. **Idempotent redelivery.** The same page delivered twice on one channel is a no-op. The same row with different content on redelivery produces the diagnostic and advances the cursor.
3. **Fan-out.** One handler notifying A then B produces two stamps; each channel's cursor advances independently; rollback leaves neither table changed.
4. **Concurrent notify.** Two transactions notifying one record concurrently receive distinct stamps (persistence test in `integration/persistence`).
5. **Move A → B and A → B → A**, including delayed updates and child-record cascade.
6. **Delete across channels.** Delete notified to A and B; the record disappears after the first channel's delete; the tombstone survives until the second; an older upsert arriving in between is discarded; the tombstone is dropped after the last claim.
7. **Pending edits.** Local edits replay over the newest base; ACK-before-Pull and Pull-before-ACK keep correct checkpoint and prefix settlement.
8. **Close and reopen** at each durable boundary preserves stamps, claims and tombstones.
9. **Unstamped page** is rejected; `fixtures/protocol` cases for missing, zero, negative and overflowing `stamp`.

## Tests to update

- `crates/core`: `RecordChange` validation and the protocol fixtures.
- `crates/server`: `process_pull` copies `stamp`; `publish` validates `{ cursor, stamp }`.
- `integration/persistence/server/runtime.test.mjs`: `publish` returns both counters; `scan` returns `stamp`; concurrent notify yields distinct stamps.
- `crates/client` and `integration/rust`: the apply rules above; every existing scenario still passes with stamps added to its pages.
- `integration/e2e`: the round trip unchanged in behaviour.

`bash scripts/test.sh` must pass on macOS and Linux before merge.

## Sequencing

#5 is merged. #9 lands the client tables this design writes to. Implement this issue on top of #9.

## Out of scope

Per-mutation transactions or receipts, removal of accepted-prefix ordering, wholesale Pull failure-policy changes, counter encoding changes, channel generations and snapshot reset, and any TTL-based cleanup of tombstones.
