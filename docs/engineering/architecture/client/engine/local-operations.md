# Local operations

Local reads, writes and transactions.

Current code: [client/mutate.rs](../../../../../crates/client/src/mutate.rs) (`enqueue`, `direct`, `apply_main`, `hold_truth`, `rebuild`, `descendants`, `set_authority`), [client/query.rs](../../../../../crates/client/src/query.rs) (`evaluate`, `related`, `referencing`, `rows_to_objects`), [client/rows.rs](../../../../../crates/client/src/rows.rs) (row codec and table statements); dependency derivation in [client/policies.rs](../../../../../crates/client/src/policies.rs).

## 1. Introduction and Goals

- Make a local write visible at once, remember the last authoritative state underneath it, and keep both consistent through cascades, replays and rollbacks.

## 3. Context and Scope

- Inputs: `Operation {model, op, identity, values}` as a named mutation's wire or companion operation (`enqueue`) or as a direct write (`direct`); `QuerySpec {filter, order_by, limit}`.
- Tables: one main table per model holding the merged view, one `ahead_before_<Model>` twin holding the last known server row for dirty records ([Storage](../storage.md)).
- Callers: [Frontend interface](../frontend-interface.md); [Pull](pull.md) and [Settlement](settlement.md) call `set_authority`, `rebuild` and `hold_truth`.

## 5. Building Block View

- Normalization: identity through `record_key`; `create` values through `normalize_state`; `update` through `validate_patch`; `delete` must carry no values ([Protocol / Common](../../protocol/common.md)).
- Dirty and truth: a record is dirty when any queued operation names it; `hold_truth` copies the main row aside once (`INSERT OR IGNORE … SELECT`), before the first queued operation touches it; `truth` reads the before image when dirty, else the main row.
- `enqueue`: rejects empty names, version 0, no operations or unknown explicit dependencies; for every wire and companion operation in order: normalize, hold truth, cascade a delete to `descendants` (each held and deleted, recorded as an `effect`), apply to the main table; then `policies::derive` fills lifecycle and sequence dependencies and prerequisite keys ([Push](push.md)); finally an ordinal is allocated and the rows inserted.
- `direct`: normalize, cascade deletes, apply to the main table; if the record is dirty, fold the write into the before image so a later rejection keeps it (guarantee L4). Direct writes are final at commit and never queued.
- `rebuild(key)`: replay every still-queued operation for the record over its before image; if replay fails, keep the truth; when no operations remain, drop the before image.
- `set_authority(key, value)`: for a delete, first remove claims and `set_authority(None)` for every descendant; then write into the before image and `rebuild` when dirty, or straight into the main table; then `refresh_pending` extends queued deletes to descendants that appeared later.
- Queries: equality filters run in SQL (`IS NULL` for null); list fields cannot be filtered; ordering and `limit` run in Rust after loading every matching row, with nulls first, UTF-16 string order and the identity as tiebreak; `related` follows a reference, `referencing` filters the referencing model.
- Read-only SQL: `read_sql` runs on the committed reader; statements must be read-only with at least one column and unique column names.

## 6. Runtime View

- Inside a transaction, reads see the transaction's own writes (`Engine::rows` uses the writer connection); outside, they see the last commit.
- Each `enqueue` and `direct` runs in its own savepoint, so a unique-index violation on an optimistic create undoes only that operation (guarantee L3).

## 10. Quality Requirements

- L1, L3, L4, L5: [sqlite/tests/client.rs](../../../../../crates/sqlite/tests/client.rs) `optimistic_edit_holds_truth_once_and_rejection_rebuilds_from_it`, `schema_cascade_is_optimistic_same_fate_and_not_extra_wire_operations`, `declared_unique_constraint_is_atomic`, `direct_cascade_handles_cyclic_relationships_once`; [crates/sim/tests/local.rs](../../../../../crates/sim/tests/local.rs) `l1_…`, `l4_…`, `l5_…`.
- Queries: [sqlite/tests/query.rs](../../../../../crates/sqlite/tests/query.rs); row codec: [sqlite/tests/engine.rs](../../../../../crates/sqlite/tests/engine.rs) `model_rows_round_trip_booleans_lists_and_copy_aside`.

## 11. Risks and Technical Debt

- **Confirmed bug: a direct write on a pending-create row fabricates truth.** `direct_one` falls back to storing the current main row as the before image when the row has no authority yet, so a rejected create leaves the row behind with no claim and no pending mutation. Evidence: [client/mutate.rs](../../../../../crates/client/src/mutate.rs) `direct_one`; the random simulation runner with direct writes is `#[ignore]`d ([crates/sim/tests/invariants.rs](../../../../../crates/sim/tests/invariants.rs)). Open: [#33](https://github.com/zanminwang/ahead/issues/33).
- **Potential risk: a failed replay is silent.** `rebuild` falls back to the truth when a queued operation no longer applies (for example an update after an authoritative delete), and the main row diverges from the still-queued mutation without any diagnostic. Evidence: [client/mutate.rs](../../../../../crates/client/src/mutate.rs) `rebuild`. No test asserts the fallback; whether to surface it needs deciding.
- **Confirmed limitation: query ordering and limit are in memory.** Every matching row is loaded, sorted and truncated in Rust; filters are equality only. Evidence: [client/query.rs](../../../../../crates/client/src/query.rs) `evaluate`. Cost is noted as a cost center in [#12](https://github.com/zanminwang/ahead/issues/12).
- **Potential risk: `refresh_pending` scans the whole queue on every authoritative change.** For each queued delete it recomputes descendants; with long offline queues and large pages this is quadratic. Evidence: [client/mutate.rs](../../../../../crates/client/src/mutate.rs) `refresh_pending`, called from `set_authority`. Not measured.
