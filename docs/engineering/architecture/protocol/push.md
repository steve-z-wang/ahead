# Push

Engine behavior: [Client Push](../client/engine/push/README.md), [Client Settlement](../client/engine/settlement.md), [Server Push](../server/engine/push.md).

## 3. Context and Scope

- Request, `POST /sync/mutations`: `{clientId, batchSequence, mutations:[{ordinal, name, version?, operations:[{model, op, identity, values?}]}]}`. Unknown fields are preserved.
- Response, HTTP 200: `{requiredCheckpoints:[{scope, syncId}], requiredScope, requiredSyncId, rejections:[{ordinal, code}]}`.
- Protocol failures are HTTP statuses, not receipts: `400 request.invalid`, `401 unauthenticated`, `403 client.owner_mismatch`, `409 gap`, `409 overlap`, `409 mutation_version_unsupported {ordinal, name, version}`, `500 server` ([Server / Connection / Transport](../server/connection/transport.md)).

## 5. Building Block View

- **Request rules.** `clientId` non-blank; `batchSequence` positive; 1 to `limits::PUSH_MUTATIONS` (20) mutations, each with a positive ordinal unique within the batch. The mutation body beyond `ordinal` is opaque to the protocol layer and decoded against the schema by the server ([Mutations](../schema/mutations.md)). Encoding re-emits the canonical JSON of the whole raw value, which is what keeps a frozen batch byte-stable (guarantee P4).
- **Receipt rules.** When `requiredCheckpoints` is absent the legacy pair becomes the single checkpoint; an explicit empty list with no rejections is invalid; checkpoint channels are unique; each rejection has a positive ordinal and a non-blank code.
- **Identity of a mutation.** Ordinals are allocated by the client and never reused, so `(clientId, ordinal)` identifies a mutation across retries.
- **Rejection codes.** `mutation.invalid`, `<mutation>.not_allowed`, `<mutation>.invalid`, and handler codes matching `^[a-z][a-z0-9]*([._-][a-z0-9]+)*$`. The client adds `dependency.rejected` and `dropped` locally; they never travel.
- **Receipt hash.** `PushRequest::semantic_hash` hashes the canonical bytes. It is tested in core but not consumed by the server ([Server Push](../server/engine/push.md)).

Code: [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`PushRequest`, `PushReceipt`, `limits`).

## 6. Runtime View

Batch `n+1` is accepted only after `n`. Resending `n` returns the stored receipt; anything else is `gap` or `overlap` (guarantee P2). A receipt with an empty checkpoint list and at least one rejection means the whole batch was rejected and nothing is awaited.

## 10. Quality Requirements

- Unknown request fields survive a round trip and change the hash; a receipt without `requiredCheckpoints` decodes to the legacy checkpoint, and an explicit empty list is refused. Evidence: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `batch_envelope_keeps_unknown_data_in_receipt_hash`, `checkpoint_wire_roundtrip_retains_legacy_fallback`, `receipt_distinguishes_missing_checkpoints_from_explicit_empty`.
- The receipt a client stores equals the one the server stored, byte for byte. Evidence: [crates/sim/tests/push.rs](../../../../crates/sim/tests/push.rs) `receipts_round_trip`.

## 11. Risks and Technical Debt

- **Decision needed ([#63](https://github.com/zanminwang/ahead/issues/63)): whether to retire `requiredScope` and `requiredSyncId`.** They are mandatory on the wire even when `requiredCheckpoints` is present; the server fills them from the first sorted checkpoint or with `""` and `0`. Inventory (2026-09-14, code inspection):
    - *Emitters.* `process_push` in [server/lib.rs](../../../../crates/server/src/lib.rs); every test that builds a `PushReceipt` (the SQLite harness, `bindings/common/tests/session.rs`, the JS and Dart live-test fixtures, `fixtures/protocol/counter-and-checkpoint.json`).
    - *Decoders.* `PushReceipt::decode` requires both fields and uses them only as the fallback checkpoint when `requiredCheckpoints` is absent; `validate` range-checks `requiredSyncId`. The client engine settles from `requiredCheckpoints` and `rejections` alone; neither SDK reads the pair.
    - *Stated constraint.* [Common §2](common.md) says wire names inherited from the reference implementation must not change; no external client of this server is known, and the sim's byte comparison of stored receipts is within one version.
    - *Staged path if retired.* (1) make the pair optional on decode while keeping the fallback for receipts without `requiredCheckpoints`, which stays compatible with receipts already stored on servers; (2) stop emitting it; (3) remove the fields. Each step is a wire-contract change and waits for the decision.
