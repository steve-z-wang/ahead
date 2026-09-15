# Push

## 1. Introduction and Goals

Server push executes a client's batch exactly once, in order, inside the application's transaction, and answers with a receipt that carries the authoritative result of every record the batch changed. The framework reads those records back itself, in the same transaction, so the client needs no channel to learn what its mutation did.

## 3. Context and Scope

Input: the authenticated owner, the request bytes ([Protocol / Push](../../protocol/push.md)) and a host. Output: the receipt text, also stored for replay; or an error that aborts the transaction (`request.invalid:…`, `model_version_unsupported`, `owner_mismatch`, `gap`, `overlap`, `mutation_version_unsupported:…`, `loader.invalid`, `loader.unregistered`, `host.invalid`, or any thrown handler, loader or persistence error). The [connection](../connection/transport.md) maps these to HTTP statuses.

## 5. Building Block View

- **Decoder.** Turns wire operations into handler arguments and lists the records they target, as described with the schema rules in [Mutations](../../schema/mutations.md).
- **Readback.** Per mutation: the *change set* (uploaded targets plus the handler's `changes`), one `advanceStamp` per changed record, one `load` per changed model at the version the request declared, normalization against that version's retained contract, then the publications the handler asked for ([Notify](notify.md)). Its outcome is the mutation's authority records or a refusal code.
- **Receipt assembly.** The last successful authority per record, in canonical key order, with the rejections.

Code: `process_push` and `decode` in [server/lib.rs](../../../../../crates/server/src/lib.rs); `read_back` in [server/readback.rs](../../../../../crates/server/src/readback.rs).

## 6. Runtime View

1. **Decode and check the declaration.** The request must declare a retained read contract for every model it names; otherwise `model_version_unsupported` refuses the whole request before anything runs, as for a pull.
2. **Lock the client.** `claim` locks the client's row and returns its owner, last sequence and stored receipt. A different owner is the `client.owner_mismatch` error.
3. **Compare sequences.** The same sequence as last time returns the stored receipt without running anything and without comparing the request body to the one that produced it (guarantee P1; section 9). A smaller one is `overlap`; anything but `last + 1` is `gap` (guarantee P2).
4. **Check versions (current implementation; violates P7).** If any mutation names a known mutation at an unregistered version, the whole batch is refused before any handler runs. The agreed replacement is in section 9.
5. **Run each mutation in its savepoint.** Decode its arguments; a decode failure becomes a rejection with the decode code and no handler call. Otherwise open a savepoint and call the handler. A rejection answer rolls the savepoint back and is recorded. A settlement answer starts the readback:
    - the change set is the uploaded operation targets plus the handler's `changes`, deduplicated by canonical key;
    - a changed model the client did not declare is a read refusal: the mutation is rolled back and rejected with `model_version_unsupported`, never served at a guessed version;
    - every changed record gets its next stamp (`advanceStamp`), in canonical key order so two mutations lock the same records the same way;
    - the loaders read every changed record, grouped by model, at the declared version, inside the savepoint; a loader refusal rolls the mutation back and becomes its rejection; a misaligned or non-normalizable row is `loader.invalid` and aborts the delivery;
    - publications go out at those stamps; a record a handler publishes without changing keeps its stamp, initialized only when it has none (`ensureStamp`).
    The savepoint is released either way. A record's authority from a later successful mutation replaces an earlier one's; a later rejected mutation replaces nothing.
6. **Build the receipt.** The client id, the batch sequence, the rejections and the final authority per record, stored with `saveReceipt` and returned.

All of this happens in the transaction the application opened, so business writes, stamps, publications, the client row and the receipt commit or roll back together. A batch that aborts leaves the client row untouched, and the client's retry is still `last + 1`. Subscribers are woken after commit ([Notify](notify.md)).

## 9. Architecture Decisions

**Receipt replay is keyed by client identity and batch sequence, not by request body ([#47](https://github.com/zanminwang/ahead/issues/47)).** After the request-envelope and owner checks, `(clientId, batchSequence)` identifies a delivery. A sequence equal to the client's most recently committed one returns the stored receipt as is, even when the new request carries different mutation content; handlers do not run, nothing is stamped or published and no subscriber is woken. Only that one sequence replays: older sequences stay `overlap` and skipped ones `gap`. The SDKs retry frozen request bytes (guarantee P4), so a different body under a committed sequence is a client defect, and new intent takes a new sequence. A stored receipt is the outcome as it was committed; a retry never re-reads a later state.

**The framework reads results back; application code does not ([#55](https://github.com/zanminwang/ahead/issues/55)).** A handler writes and, optionally, names extra changes and publications; the engine allocates stamps, invokes the loaders and stores the authority, all before the transaction commits. The alternatives were rejected: asking handlers to return records would let a handler's view drift from its loader's, and waiting for a channel page (the previous checkpoint contract) made a subscription a precondition of completing a write and reverted accepted writes on clients that followed no channel. Loaders name no channel, so the record a receipt carries is the record a page would carry at the same stamp (guarantee D4).

**Stamps advance on change, cursors on publication.** A successful mutation advances the stamp of every record it changed, published or not; publishing allocates channel cursors only and reuses the record's stamp (guarantee D3). The persistence contract splits the former single operation into `advanceStamp`, `ensureStamp` and a `publish` that takes the stamp ([Persistence](../persistence.md)).

**Loader refusal is the mutation's rejection — narrow [#95](https://github.com/zanminwang/ahead/issues/95) integration (P6).** A loader may answer a refusal code instead of rows; the engine rolls that mutation back and records the code, exactly as for a handler rejection. A thrown loader error, like any thrown host error, still aborts the delivery for retry. The same refusal in a pull fails the page (`loader.refused`) until per-read isolation is designed ([Pull](pull.md#9-architecture-decisions)).

**Operation rejection is isolated — agreed target ([#95](https://github.com/zanminwang/ahead/issues/95), [P7](../../../guarantees.md#p-push)).** Batching is internal delivery machinery, not an application-selected all-or-nothing transaction. An unsupported mutation version must become a rejection for that ordinal in the durable receipt, without invoking its handler or refusing unrelated valid mutations. The client retains the rejection through its existing [rejection handling](../../client/engine/settlement.md); lifecycle dependents still follow P5. No automatic fallback to another version is permitted. Request-envelope, authentication, declaration and sequence validation still protect the delivery as a whole; the current implementation aborts the batch on unexpected handler errors and unsupported versions.

## 10. Quality Requirements

- **A lost receipt is replayed without a second execution, including under concurrent retries; a retry after an unrelated later write returns the original bytes** (guarantee P1). Evidence: [server/tests/readback.rs](../../../../../crates/server/tests/readback.rs) `a_retried_batch_answers_from_storage_without_running_a_handler`; [crates/sim/tests/push.rs](../../../../../crates/sim/tests/push.rs) `p1_lost_receipt_retry_executes_once_and_returns_the_stored_receipt`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `concurrent same-client retry executes once under PostgreSQL lock`.
- **Gaps and overlaps are refused with stable codes and nothing executes; an unretained declaration is refused before the client is claimed** (guarantee P2). Evidence: `p2_contiguous_sequence_and_server_refuses_gap_and_overlap`; `an_unretained_declaration_is_refused_before_claim`; [server/tests/runtime.rs](../../../../../crates/server/tests/runtime.rs) `push_refusals_carry_stable_codes_and_run_no_handler`.
- **Each changed record is read back once at its allocated stamp, in the version the request declared; two mutations on one record leave the last result; extra `changes` are read back; a deletion reads back as `null`; a no-op success still advances the stamp.** Evidence: `success_reads_back_each_changed_record_once_at_its_stamp`, `repeated_operations_on_one_record_share_one_stamp`, `a_later_mutation_on_the_same_record_replaces_the_earlier_result`, `handler_changes_are_read_back_and_publication_only_records_are_not`, `a_deleted_record_reads_back_as_null`, `a_quiet_success_still_advances_the_stamp_and_reads_back`, `records_are_loaded_at_the_declared_version`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `push commits business + compacted publication + exact durable receipt together`.
- **A loader refusal or an undeclared changed model rejects only that mutation and rolls it back; a thrown loader error, an invalid row or a failed publication aborts the delivery without a receipt; a later rejection keeps an earlier success** (guarantee P6). Evidence: `a_loader_refusal_rejects_the_mutation_and_keeps_earlier_results`, `a_changed_model_the_client_did_not_declare_rejects_that_mutation`, `a_loader_host_error_fails_the_whole_push`, `invalid_loader_rows_fail_the_push`, `a_failed_publication_fails_the_push`, `a_later_rejection_on_the_same_record_keeps_the_first_success`; [runtime.test.mjs](../../../../../integration/persistence/server/runtime.test.mjs) `explicit rejection rolls back only mutation and its publication`, `unknown error rolls back entire batch including earlier effects and client claim`.
- **P7 requires an unsupported version to reject only that mutation. Current coverage instead asserts whole-batch abort and must change; invalid bodies already settle as rejections.** Existing evidence (not proof of P7): `unsupported versions abort before handlers, invalid bodies settle as rejections`.

Verified 2026-09-15 by `cargo test -p ahead-server --locked` (the readback suite) — see the pull request for the persistence-suite run.

## 11. Risks and Technical Debt

**Problem: unsupported mutation versions abort unrelated work.** The preflight loop in `process_push` returns before any handler runs, contradicting P7. Replace it with per-mutation rejection and add a mixed-version batch regression that proves valid unrelated work commits, the unsupported handler never runs, and retries replay the same receipt. Tracked in [#95](https://github.com/zanminwang/ahead/issues/95).

**Accepted limitation.** A client id is bound to the first owner that used it; a later push from another user with the same client id is `client.owner_mismatch` (HTTP 403) and there is no reassignment. Relevant to shared devices.

**Accepted limitation (planned change).** The only size bound is the protocol's 20-mutation cap and the HTTP body limit; a server-side byte cap is part of [#11](https://github.com/zanminwang/ahead/issues/11). Receipts now grow with the records changed, so large records raise the response size in step ([Protocol / Push](../../protocol/push.md#11-risks-and-technical-debt)). The lack of a client-side escape from a batch the server keeps failing is recorded under [Batching](../../client/engine/push/batching.md).
