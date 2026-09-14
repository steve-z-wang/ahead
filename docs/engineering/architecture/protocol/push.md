# Push

Mutation batches, receipts, rejections and checkpoints.

Current code: [core/protocol.rs](../../../../crates/core/src/protocol.rs) (`PushRequest`, `PushReceipt`, `ChannelCheckpoint`, `Rejection`).

Engine behavior: [Client Push](../client/engine/push/README.md), [Client Settlement](../client/engine/settlement.md), [Server Push](../server/engine/push.md).

## 3. Context and Scope

- Request, `POST /sync/mutations`: `{clientId, batchSequence, mutations:[{ordinal, name, version?, operations:[{model, op, identity, values?}]}]}`. Unknown fields anywhere are preserved.
- Response, HTTP 200: a receipt `{requiredCheckpoints:[{scope, syncId}], requiredScope, requiredSyncId, rejections:[{ordinal, code}]}`.
- Protocol-level failures are HTTP statuses, not receipts: `400 request.invalid`, `401 unauthenticated`, `403 client.owner_mismatch`, `409 gap`, `409 overlap`, `409 mutation_version_unsupported {ordinal, name, version}`, `500 server` ([Server / Connection / Transport](../server/connection/transport.md)).

## 5. Building Block View

- `PushRequest::decode`: `clientId` non-blank; `batchSequence` positive counter; 1–20 mutations, each an object with a positive, unique `ordinal`; the rest of each mutation is kept raw for the server's decoder ([Mutations](../schema/mutations.md)). `encode` re-emits the canonical JSON of the raw value, which is what makes a frozen batch byte-stable (guarantee P4).
- `semantic_hash`: SHA-256 of the canonical bytes. Computed and tested in core; not consumed by the server (see [Server Push](../server/engine/push.md)).
- `PushReceipt::decode`: when `requiredCheckpoints` is absent, the legacy pair becomes the single checkpoint; an explicit empty checkpoint list with no rejections is refused (`empty checkpoint set`); channels must be unique; each rejection needs a positive ordinal and a non-blank code. `encode` validates the same rules.
- Rejection codes seen on the wire: `mutation.invalid`, `<mutation>.not_allowed`, `<mutation>.invalid`, and handler codes matching `^[a-z][a-z0-9]*([._-][a-z0-9]+)*$`. The client adds `dependency.rejected` and `dropped` locally; they never travel.
- Ordinals are client-allocated and unique per client for its lifetime (`ahead_client.next_ordinal`), so `(clientId, ordinal)` identifies a mutation across retries.

## 6. Runtime View

- Batch `n+1` is accepted only after `n`; the same `n` returns the stored receipt; anything else is `gap` or `overlap` (guarantee P2, [Server Push](../server/engine/push.md)).
- A receipt with `requiredCheckpoints: []` and at least one rejection means the whole batch was rejected and nothing needs to be awaited.

## 10. Quality Requirements

- [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `batch_envelope_keeps_unknown_data_in_receipt_hash`, `checkpoint_wire_roundtrip_retains_legacy_fallback`, `receipt_distinguishes_missing_checkpoints_from_explicit_empty`.
- Round trip between real client and server: [crates/sim/tests/push.rs](../../../../crates/sim/tests/push.rs) `receipts_round_trip`.

## 11. Risks and Technical Debt

- **Confirmed debt: the legacy pair is mandatory forever.** `requiredScope` and `requiredSyncId` have no serde default, so a receipt without them fails to decode even when `requiredCheckpoints` is present; the server fills them with the first sorted checkpoint or `""`/`0`. Evidence: [core/protocol.rs](../../../../crates/core/src/protocol.rs) `PushReceipt`. No issue tracks retiring them.
- **Confirmed debt: `semantic_hash` is unused at runtime.** See [Server Push](../server/engine/push.md); the guarantee text for C1 is corrected in [guarantees](../../guarantees.md).
- Batch size limits are a [Common](common.md) finding ([#11](https://github.com/zanminwang/ahead/issues/11)).
