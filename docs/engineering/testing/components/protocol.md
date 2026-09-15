# Protocol contract tests

Verify the messages shared by client and server: field names, counters, canonical encoding, checkpoints, stamps and malformed input. The [protocol documents](../../architecture/protocol/README.md) define the contract.

Existing entry point: [core contracts](../../../../crates/core/tests/contracts.rs), including shared wire fixtures and numeric boundaries.

```sh
cargo test -p ahead-core --test contracts --locked
```

Use explicit expected wire values and invalid inputs. A round trip alone can miss matching encoder and decoder errors. Encoding a semantic hash does not establish server retry validation; that behavior belongs in [server tests](server.md). Actual HTTP and WebSocket behavior belongs in [connection integration](../integration/connection.md).

## Coverage review

Reviewed 2026-09-14 by reading assertions in [contracts.rs](../../../../crates/core/tests/contracts.rs) and the shared fixture; not executed.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Canonical JSON matches JavaScript key order and number spelling; unknown fields are preserved ([Common](../../architecture/protocol/common.md)) | `canonical_numbers_match_javascript_and_utf16_key_order`, `batch_envelope_keeps_unknown_data_in_receipt_hash` | covered | none |
| Counters accept JavaScript spellings and refuse values beyond 2^53−1 | `server_pull_request_accepts_js_integer_number_spellings`, `wire_names_remain_legacy_and_counters_are_safe`, `shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries` | covered | none |
| Received state: extra fields dropped, missing required refused, identity refused | `received_state_supports_additive_schema_evolution`, `state_is_complete_but_patch_preserves_absent_and_null`; server side `ordered_slot_decodes_known_fields_and_ignores_new_fields` | covered | none |
| Push request: 1 to 20 mutations, positive unique ordinals, non-blank client id ([Push](../../architecture/protocol/push.md)) | `push_batches_hold_one_to_twenty_mutations_with_distinct_ordinals` (0 and 21 refused, 1 and 20 accepted, duplicate and zero ordinals refused); `push_and_pull_requests_refuse_a_blank_client_id` (empty and whitespace client ids refused on push and pull, a missing field refused) | covered | Verified 2026-09-14: `cargo test -p ahead-core --test contracts --locked` (16 tests). |
| Receipt: legacy fallback, explicit empty list refused, duplicate channel refused | `checkpoint_wire_roundtrip_retains_legacy_fallback`, `receipt_distinguishes_missing_checkpoints_from_explicit_empty` | covered | none |
| Receipt hash detects a different body on retry | `batch_envelope_keeps_unknown_data_in_receipt_hash` (core only) | undecided | The server never compares hashes and the PostgreSQL suite asserts the cached receipt is returned for a different body. This is a contract decision recorded in [Server Push](../../architecture/server/engine/push.md), not a missing test. |
| Pull page: state and stamp keys required, cursors strictly increasing within the page ([Pull](../../architecture/protocol/pull.md)) | `field_default_and_record_stamp_round_trip_and_ahead_prefix_is_rejected`, `wire_names_remain_legacy_and_counters_are_safe`, shared fixture | covered | none |
| Subscribe frame: exactly one, unknown keys refused, scopes normalized ([Subscriptions](../../architecture/protocol/subscriptions.md)) | [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs) `live_subscribe_requires_one_subscribe_frame_and_normalizes_scopes`; [stamp.rs](../../../../crates/server/tests/stamp.rs) `live_negotiation_establishes_current_heads_and_rejects_cursor_modes` | covered | The "second frame closes with 1002" rule is asserted only against the real server in [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs); that is the right place. |
