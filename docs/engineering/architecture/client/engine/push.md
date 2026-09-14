# Push

Queue mutations, track dependencies and freeze batches.

Current code: [client/queue.rs](../../../../../crates/client/src/queue.rs) (queue tables, ordinals, push numbers, dependencies, prerequisites, checkpoints, rejections), [client/push.rs](../../../../../crates/client/src/push.rs) (`freeze`, `encode_push`, `in_flight`); dependency derivation in [client/policies.rs](../../../../../crates/client/src/policies.rs).

## 1. Introduction and Goals

- Turn queued mutations into byte-stable batches in an order the server can execute safely, and never send a mutation before what it depends on is known to have succeeded.

## 3. Context and Scope

- Input: queued mutations (`ahead_mutation`, `ahead_mutation_operation`, `ahead_mutation_dependency`, `ahead_mutation_prerequisite`).
- Output: the canonical [PushRequest](../../protocol/push.md) bytes for one batch, numbered by `ahead_client.next_push`.
- Callers: `Client::freeze` from [Frontend interface](../frontend-interface.md), driven by `SyncCycle` ([Connection / Controller](../connection/controller.md)).

## 5. Building Block View

- Ordinal and push counters live in `ahead_client` and are bumped inside the write transaction; both are capped at 2^53−1.
- Operation kinds per mutation: `wire` (sent), `companion` (local, same fate as the mutation, never sent), `effect` (cascaded deletes derived by the engine).
- Dependencies (`ahead_mutation_dependency`, `kind` `lifecycle` or `sequence`, `depends_on < ordinal`):
  - lifecycle: derived when an operation's record, or a record it references, was created by an earlier queued mutation, or when a create follows a queued delete of the same record; also accepted explicitly from the caller.
  - sequence: derived from the mutation's `@@sequence` policy by resolving slot paths against earlier queued mutations of the named predecessor ([Mutations](../../schema/mutations.md)).
- Prerequisites: keys in `ahead_mutation_prerequisite` ([Prerequisites](../../schema/prerequisites.md)).
- `freeze(max_bytes)`: if a push is in flight (a push number with no checkpoint rows), re-encode and return it; otherwise walk unsent mutations in ordinal order, skipping any with an outstanding prerequisite key, an unsent lifecycle dependency, or an unsent sequence dependency not already chosen for this batch; skip a candidate that would push the canonical request over `max_bytes` unless it is the first; stop at 20 mutations; allocate the push number, stamp the chosen rows and encode.
- `encode_push`: rebuilds the request JSON from rows and round-trips it through `PushRequest::decode/encode`, so bytes depend only on stored rows (guarantee P4).

## 6. Runtime View

- A lifecycle dependent is never in the same batch as its parent and is frozen only after the parent's receipt removed the parent from the unsent set; a sequence dependent may share the batch when its predecessor was chosen earlier in it (guarantee P3).
- Because a blocked or oversized candidate is skipped rather than stopping the scan, an independent later mutation can reach the server before an earlier one. Ordering across batches is guaranteed only through dependencies.

## 10. Quality Requirements

- P2–P4: [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p2_…`, `p3_…`, `p4_…`; [sqlite/tests/push.rs](../../../../../crates/sqlite/tests/push.rs) `offline_queue_and_frozen_bytes_survive_restart_and_ack_waits_for_pull`, `lifecycle_dependency_waits_for_parent_ack_but_sequence_can_share_batch`, `schema_sequence_relationship_blocks_dependent_but_not_independent_work`, `failed_prerequisite_stays_optimistic_independent_work_can_overtake`, `byte_budget_skips_large_candidate_but_always_allows_one`.
- Queue persistence: [sqlite/tests/engine.rs](../../../../../crates/sqlite/tests/engine.rs) `queue_rows_reconstruct_mutations_and_cascade_on_delete`.

## 11. Risks and Technical Debt

- **Confirmed limitation: a poisoned batch blocks the queue with no recovery.** The server aborts a whole batch on any handler exception and the client retries the same bytes; `drop_mutation` refuses sent mutations, so a deterministic handler bug halts that client's pushes until the server is fixed. Evidence: [client/lib.rs](../../../../../crates/client/src/lib.rs) `drop_mutation`; [Server Push](../../server/engine/push.md). No issue tracks an operator or application escape hatch; needs deciding.
- **Confirmed limitation: limits are hard-coded.** 20 mutations (`MAX_MUTATIONS`) and 256 KiB (`Client::freeze`). Open: [#11](https://github.com/zanminwang/ahead/issues/11).
- **Confirmed debt: quadratic re-encoding during freeze.** Each candidate re-encodes the whole candidate batch to check the byte budget. Evidence: [client/push.rs](../../../../../crates/client/src/push.rs) `freeze`; named as a cost center in [#12](https://github.com/zanminwang/ahead/issues/12).
- **Potential risk: skip-ahead ordering is undocumented for schema authors.** Two test names promise clauses their bodies do not assert (guarantee P3 note), and no user-facing text explains that independent mutations can overtake blocked ones. Evidence: [sqlite/tests/push.rs](../../../../../crates/sqlite/tests/push.rs) `lifecycle_dependency_waits_for_parent_ack_but_sequence_can_share_batch`, `schema_sequence_relationship_blocks_dependent_but_not_independent_work`.
