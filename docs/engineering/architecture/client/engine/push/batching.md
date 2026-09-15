# Batching

## 1. Introduction and Goals

- Freeze eligible mutations into a numbered request whose bytes remain stable across retries.

## 3. Context and Scope

- Input: the [Queue](queue.md), [dependency rules](dependencies.md) and a byte budget.
- Output: canonical [PushRequest](../../../protocol/push.md) bytes, or no batch.
- [Connection](../../connection/README.md) owns delivery and retry timing; [Settlement](../settlement.md) processes receipts.

## 5. Building Block View

- Code: selection and encoding in [push.rs](../../../../../../crates/client/src/push.rs); durable push assignment in [queue.rs](../../../../../../crates/client/src/queue.rs).

## 6. Runtime View

- Return an unacknowledged batch before preparing another one.
- Otherwise scan unsent mutations in ordinal order, skipping blocked candidates, and select at most 20.
- Skip a candidate that exceeds the byte budget, except that the first eligible mutation is allowed through. A zero budget produces no batch.
- Assign a push number transactionally. Encode only wire operations from the stored rows.

## 10. Quality Requirements

- Retrying or reopening the same frozen batch preserves its sequence and bytes: [restart and frozen-byte test](../../../../../../crates/sqlite/tests/push.rs).
- A large mutation cannot starve the queue solely because of the byte budget: `byte_budget_skips_large_candidate_but_always_allows_one` in the same test file.

## 11. Risks and Technical Debt

- A deterministic handler failure can block later batches: retries preserve the failed batch, and sent mutations cannot be dropped. Evidence: [Client::drop_mutation](../../../../../../crates/client/src/lib.rs) and [Server Push](../../../server/engine/push.md). Recovery from a permanently failing frozen batch is [#56](https://github.com/zanminwang/ahead/issues/56).
- The count cap is fixed at 20; the default byte budget is 256 KiB. Limit configuration is tracked in [#11](https://github.com/zanminwang/ahead/issues/11).
- Each size check re-encodes the candidate batch. Its cost grows with batch size; measurement belongs to [#12](https://github.com/zanminwang/ahead/issues/12).
