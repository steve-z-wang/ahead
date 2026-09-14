# Common

Shared fields, counters and encoding conventions.

Current code: [core/lib.rs](../../../../crates/core/src/lib.rs) (`canonical_json`, `Error`), [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`counter`, `read_counter`), identity and state rules in [core/schema.rs](../../../../crates/core/src/schema.rs) (`RecordKey`, `validate_state`, `normalize_state`, `validate_patch`).

## 1. Introduction and Goals

- One byte-exact encoding and one numeric range shared by Rust, TypeScript and Dart, so frozen requests, receipt caching and identity keys agree across runtimes and with the reference implementation.

## 2. Architecture Constraints

- Wire field names are inherited from the reference implementation: `scope` means channel, `syncId` means cursor, `requiredScope` and `requiredSyncId` are the legacy single-checkpoint pair. Renaming them would break byte compatibility (guarantee C1).
- Every counter (cursor, stamp, batch sequence, ordinal, version) is an integer in `0..=2^53−1` so JavaScript reads it exactly.

## 5. Building Block View

- `canonical_json`: objects with keys sorted by UTF-16 code units (JavaScript `Array.sort` order), arrays in place, scalars via RFC 8785 (`serde_jcs`), so `-0` encodes as `0` and `1.0` as `1`.
- `counter` and `read_counter`: accept any finite integral JSON number spelling (`1e0`, `0.0`, `-0`) within range; `positive` forbids zero.
- Identity: `RecordKey {model, identity}`; `encoded_identity()` is the canonical JSON of the normalized identity object and is the `identityKey` the server stores; `encoded()` is the canonical `[model, identity]` pair used for in-memory sets.
- State shapes on one descriptor:
  - `validate_state` (received wire state, guarantee C2): every non-identity field present or nullable, identity keys refused, unknown keys dropped.
  - `normalize_state` (loader output on the server): may include identity fields and omit nullable ones; unknown keys refused.
  - `validate_patch`: subset of non-identity known fields; explicit `null` kept; identity immutable.
- Errors: core has one variant, `Error::Invalid(String)`; there are no error codes below the server SDK's HTTP mapping ([Server / Connection / Transport](../server/connection/transport.md)).
- Shared fixture: [fixtures/protocol/counter-and-checkpoint.json](../../../../fixtures/protocol/counter-and-checkpoint.json) lists boundary cases read by the core tests.

## 8. Crosscutting Concepts

- Limits shared by both sides but not negotiated on the wire: at most 20 mutations per push, a 256 KiB push budget, 50 changes per pull page, 1 MiB HTTP body and WebSocket frame on the server, 8 MiB WebSocket frame on the clients. Their owners are [Client Push](../client/engine/push.md), [Server Pull](../server/engine/pull.md) and the two transports.

## 10. Quality Requirements

- C1 and C2 proofs: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `canonical_numbers_match_javascript_and_utf16_key_order`, `wire_names_remain_legacy_and_counters_are_safe`, `server_pull_request_accepts_js_integer_number_spellings`, `received_state_supports_additive_schema_evolution`, `shared_wire_fixtures_preserve_counter_and_checkpoint_boundaries`.

## 11. Risks and Technical Debt

- **Confirmed limitation: limits are constants, not protocol.** The client infers "page complete" from `changes.len() < 50`, which only holds while both sides keep the same constant; batch size and page size cannot be configured. Evidence: [client/transport.rs](../../../../crates/client/src/transport.rs), [server/lib.rs](../../../../crates/server/src/lib.rs) `process_pull`. Open: [#11](https://github.com/zanminwang/ahead/issues/11).
- **Confirmed debt: errors cross every boundary as message strings.** Bindings and the HTTP layer pattern-match on text such as `gap`, `overlap` and `request.invalid:`; there is no shared code enum. Evidence: [server/index.mts](../../../../packages/server/index.mts) `createHttpHandler`, [bindings/common/src/lib.rs](../../../../bindings/common/src/lib.rs). Owned by [SDKs / Bindings](../sdks/bindings.md).
