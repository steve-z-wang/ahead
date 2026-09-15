# Server tests

Verify request validation, duplicate-batch handling, rejection, loader results and publication checkpoints. See [Server architecture](../../architecture/server/README.md).

[Existing Rust tests](../../../../crates/server/tests) provide a host implementation so each test can control responses and inspect calls.

```sh
cargo test -p ahead-server --locked
```

Assert both the response and the business calls that are permitted or prevented. A host fixture can establish sequencing, but real database locking and rollback need [Persistence tests](../integration/persistence.md).

Next review: map host-fixture assertions to server requirements and identify cases covered only by the PostgreSQL suite.

## Coverage review

Reviewed 2026-09-14 against the server architecture documents; tests read, not executed. Much of the server's decision logic (checkpoint resolution, rejection versus failure, wake sets) lives in the TypeScript runtime and is therefore proven only in the PostgreSQL suite [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs); those rows are listed here because they are component rules, even though the environment is an integration one.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Config validation: descriptors, patch capabilities, slot shapes; every mutation version has a handler and every model a loader ([Backend interface](../../architecture/server/backend-interface.md)) | [runtime.rs](../../../../crates/server/tests/runtime.rs) `startup_rejects_invalid_patch_capabilities`; `backend validates config and complete registrations at startup` | covered | none |
| Argument decoding and rejection codes ([Mutations](../../architecture/schema/mutations.md)) | `ordered_slot_decodes_known_fields_and_ignores_new_fields`, `known_disallowed_patch_is_explicit_refusal`, `undeclared_operation_is_invalid`, `create_binding_mismatch_refuses_the_whole_act`, `historical_known_field_outside_capability_is_refused` | covered | Greedy adjacent slots: see [Schema](schema.md). |
| Same sequence returns the stored receipt without executing; gaps and overlaps refused (P1, P2) | sim `p1_…`, `p2_…`; `push commits business + compacted publication + exact durable receipt together`; `concurrent same-client retry executes once under PostgreSQL lock` | covered | A different body with the same sequence returns the cached receipt; hash enforcement is *undecided* ([Server Push §11](../../architecture/server/engine/push.md)). |
| Unsupported version aborts before any handler runs | `unsupported versions abort before handlers, invalid bodies settle with empty checkpoints` asserts the rejection message matches `mutation_version_unsupported` and no handler ran | covered at the API | The HTTP mapping (`409` with ordinal, name, version) is not asserted, and there is no in-process Rust test; add a Rust host-fixture case. |
| Checkpoint is the notified channel; none or ambiguous aborts; checkpoint errors bypass `translateRejection` (A4) | `checkpoint is the single notified channel; several need an explicit choice; none is an error`, `checkpoint errors bypass translateRejection…`; sim `a4_handler_without_a_channel_aborts_the_batch` | covered | none |
| Rejection rolls back one savepoint; other errors roll back the batch, the client row and publications (P6) | `explicit rejection rolls back only mutation and its publication`, `unknown error rolls back entire batch…`, `publication failures poison push…`, `registered translator rejects one mutation; malformed translator code aborts transaction`; sim `p6_…` | covered | none |
| Owner mismatch refused | `push commits business…` (`owner_mismatch` at the API) | partial | HTTP `403 client.owner_mismatch` not asserted. |
| Pull: stamps copied, positive stamp required, compaction, 50-row pages, loader receives channel, defects abort ([Server Pull](../../architecture/server/engine/pull.md)) | [stamp.rs](../../../../crates/server/tests/stamp.rs); `compaction materializes latest state…`, `50-row pages retain original cursor progression…`, `loaders receive the channel…`, `loader defects abort pull…`, `undefined loader entries remain defects…`, `nonfinite nullable loader values are defects…` | covered | none |
| Head, scan and load observe one snapshot | `repeatable-read runner keeps head, scan, and loader coherent across concurrent publication` | covered at RepeatableRead | Nothing tests an application runner at a weaker isolation level; the requirement is prose ([Persistence §11](../../architecture/server/persistence.md)). |
| Notify: one stamp per publication, cursors independent, rejected mutations publish nothing, wakes only after commit (D3) | `publish allocates one stamp per notify…`, `concurrent notifies of one record receive distinct stamps`, `rejected mutation publishes nothing…`, `live transport negotiates, wakes only after commit…`; [stamp.rs](../../../../crates/server/tests/stamp.rs) `publish_requires_cursor_and_stamp_from_the_host` | covered | The `backend.notify(tx, …)` shortcut never wakes subscribers; the test proves the bound path only. Whether to remove or document the shortcut is *undecided* ([Notify §11](../../architecture/server/engine/notify.md)). |
| HTTP status mapping and limits ([Server transport](../../architecture/server/connection/transport.md)) | `HTTP adapter authenticates…` (401, 200, 400), `onError captures server-side failures…` (500), `listen answers pull…` | partial | `403`, `409 gap/overlap`, `409 mutation_version_unsupported`, `404`, `405` and `413` have no assertion. One table-driven HTTP test would close this. |
| Live controller: one subscribe frame, wake after commit, page split, reconnect, duplicate receipt wakes nobody | `live transport negotiates, wakes only after commit, reconnects, and cleans up`; Rust `live_subscribe_…`, `live_page_progression_…`, `live_negotiation_…` | covered | A drain error closing with `1011` is not asserted. |
