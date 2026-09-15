# Guarantees

The behavioral contract of the Rust sync core. These are requirements, not a claim that every case is implemented or tested. [Coverage review](testing/review.md) records known gaps and decisions still needed; [component documentation](architecture.md) owns API, encoding, schema and adapter rules.

Simulation exercises these behaviors across clients and message sequences. Real-database tests must also verify claims that depend on persistence or transaction semantics. IDs remain stable so scenarios can refer to them.

## L. Local writes

| ID | Required behavior |
| --- | --- |
| L1 | Reads show the authoritative base with pending local edits replayed in order. A transaction sees its own writes; other readers see them after commit. |
| L2 | Committed records, queued mutations and rejections survive database reopen. |
| L3 | A failed transaction rolls back its changes. A nested savepoint can roll back its own scope without discarding the outer transaction. |
| L4 | Direct writes never enter the push queue. Companion edits follow their mutation's acceptance or rejection. Direct edits to an authoritative record survive rejection of a pending mutation, but later server authority may replace them. A record whose create is still pending has no authoritative base: if the create is rejected the record goes, direct edits included. A page the client has already applied does not undo a direct edit. |
| L5 | Local deletion applies the cascades declared by the schema, with the same rollback scope as the initiating operation. |

## P. Push

| ID | Required behavior |
| --- | --- |
| P1 | Retrying the same frozen batch with the same client ID and sequence returns its durable receipt without executing its handlers again. This relies on persisted client identity and sequence, and atomic server receipt storage. |
| P2 | The server accepts new batches in contiguous sequence order, returns cached receipts for retries, and refuses gaps or overlaps without executing them. |
| P3 | Unready prerequisites block their mutations. Lifecycle dependents wait for predecessor acceptance; sequence dependents may follow their predecessor in the same batch. Independent ready work can proceed. |
| P4 | Frozen request bytes remain unchanged across retries, restart and supported schema reconciliation. |
| P5 | Explicit rejection removes the mutation's optimism, rejects its lifecycle dependents, and retains a readable rejection until dismissed. Other pending edits replay on the remaining base. |
| P6 | Explicit rejection rolls back that mutation's savepoint. An unexpected handler or publication failure rolls back the entire batch, including business changes and its receipt, so the client can retry. |

## A. Authority and settlement

Channel cursors order delivery within a subscription. Record stamps order authoritative content across channels.

| ID | Required behavior |
| --- | --- |
| A1 | Delivered server values replace settled optimism; later pending edits replay over the authoritative base. |
| A2 | Within a subscription, the cursor never decreases. Covered pages do nothing; overlapping pages apply only their unseen suffix. A page starting beyond the local cursor cannot skip the gap. |
| A3 | Accepted optimism waits for all required checkpoints on subscribed channels, whether pages or the receipt arrive first. Checkpoints outside the subscriptions are not awaited. |
| A4 | Required checkpoints come from channels notified by the handler. Missing or ambiguous selection for an accepted mutation aborts the batch. |
| A5 | Accepted batches settle in sequence order; a later ready batch must not pass an earlier waiting batch. |

A3's current non-subscribed-channel behavior rebuilds from existing authority: an update can revert and a local create can disappear until delivered through a subscribed channel. Whether to retain this behavior needs a decision in [Settlement](architecture/client/engine/settlement.md).

## D. Distribution

These requirements assume valid backend records, correct publication, and eventual delivery. Convergence means authoritative content agrees after pending work settles; direct-only local data is outside that comparison.

| ID | Required behavior |
| --- | --- |
| D1 | Clients subscribed to the same channel converge on its authoritative records once changes stop and receipts and pages have been delivered. |
| D2 | A newer record stamp replaces authority; older content cannot regress it. Equal stamps with equal content are idempotent; conflicting equal-stamp content does not replace the stored value. |
| D3 | Each channel publication allocates a record stamp. Channel cursors advance independently of record stamps. |
| D4 | Moves between channels preserve the latest content and correct claims despite delayed source or destination pages, including declared child membership. |
| D5 | A newer deletion removes the content while retaining outstanding claims; an older deletion cannot erase newer content. Releasing one channel's claim preserves others. |
| D6 | Unsubscribe releases that channel's claims and removes records no remaining channel claims, subject to pending local edits. A loader's null record is a deletion. |

## R. Resilience

| ID | Required behavior |
| --- | --- |
| R1 | Local reads and writes continue offline. Queued work resumes and converges when connectivity, subscriptions and backend processing recover. No delivery-time bound is promised. |
| R2 | Dropped, duplicated, delayed and reordered messages preserve the safety properties above. Eventual convergence requires delivery to resume; permanent message loss cannot provide progress. |
| R3 | After a process interruption, durable committed sync state can be reopened and resumed without losing committed work. This is a recovery requirement; close/reopen tests alone do not establish arbitrary crash-boundary coverage. |
| R4 | A stale client writer cannot overwrite state committed by a newer writer generation. |

See [Testing](testing.md) for responsibility and code maps, and [Coverage review](testing/review.md) for the evidence still needed.
