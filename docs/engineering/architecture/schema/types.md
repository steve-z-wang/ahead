# Types

Scalar and enum types, lists and nullability.

Current code: source names in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs) (`compile`, type mapping near the `"String" => Some("string")` match); descriptor and value normalization in [core/schema.rs](../../../../crates/core/src/schema.rs) (`ValueType`, `ScalarType`, `scalar`, `normalize_value`).

## 1. Introduction and Goals

- Give every model field one language-independent type whose values normalize the same way on the client, the server and the wire.
- Bound numbers to what JavaScript can represent exactly, so counters and integers survive every runtime.

## 3. Context and Scope

- Input: a type name in a `.model` field declaration, optionally followed by `[]` (list) and `?` (nullable).
- Output: a `type` descriptor in the compiled schema, `{"kind":"scalar","name":…}`, `{"kind":"enum","name":…}` or `{"kind":"list","element":…}`, plus a `nullable` flag.
- Consumers: [Compiler / Generate](../compiler/generate.md) maps descriptors to TypeScript and Dart types; [Client / Storage](../client/storage.md) maps them to SQLite column types; the core `Schema` normalizes every value that enters a record.

## 5. Building Block View

- Source names and their descriptors: `String`→`string`, `Bool` or `Boolean`→`boolean`, `Int`→`int`, `Float`→`float`, `UUID`→`uuid`, `DateTime`→`dateTime`; any declared `enum` name→`enum`; anything else is `unknown or unsupported field type`.
- Enum: `enum Name { value value }`; values are identifiers, must be non-empty and unique ([core/schema.rs](../../../../crates/core/src/schema.rs) `validate`).
- List: `T[]` where `T` must be a scalar; a list of enums or of lists is refused (`list elements must be scalar`); a list cannot be nullable (`lists cannot be nullable`).
- Value normalization ([core/schema.rs](../../../../crates/core/src/schema.rs) `scalar`):
  - `int`: any JSON number that is finite, integral and within ±2^53−1; stored as an integer.
  - `float`: finite; `-0` becomes `0`.
  - `uuid`: 36-character RFC 4122 string, version 1–8; lowercased.
  - `dateTime`: RFC 3339 with `T` at position 10; re-encoded as UTC with millisecond precision and `Z`.
  - `null` only for nullable fields; enum values must be one of the declared names.
- Language mapping ([compiler/emit.rs](../../../../crates/compiler/src/emit.rs) `ty`, `decode`, `encoded`): TypeScript `string | boolean | number | number | Date | string`, Dart `String | bool | int | double | DateTime | String`; enums become TypeScript string unions and Dart `enum`s.
- Storage mapping ([client/ddl.rs](../../../../crates/client/src/ddl.rs) `storage_type`): `boolean` and `int`→`INTEGER`, `float`→`REAL`, everything else including enums and lists→`TEXT`; lists travel as JSON text ([client/rows.rs](../../../../crates/client/src/rows.rs) `decode_value`).

## 8. Crosscutting Concepts

- The same `normalize_value` runs on the client before an operation is queued ([Local operations](../client/engine/local-operations.md)), on the server when it decodes arguments and loader rows ([Server Push](../server/engine/push.md), [Server Pull](../server/engine/pull.md)) and on received states ([Client Pull](../client/engine/pull.md)).
- Query ordering compares normalized values: strings by UTF-16 code units, numbers as f64, nulls first ([client/query.rs](../../../../crates/client/src/query.rs) `compare`).

## 10. Quality Requirements

- Integers outside the safe range are refused everywhere: [core/tests/contracts.rs](../../../../crates/core/tests/contracts.rs) `state_is_complete_but_patch_preserves_absent_and_null`; PostgreSQL `bigint` values are narrowed by the server SDK: [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `loader safely converts PostgreSQL BigInt scalar and list values`.
- Identity normalization (UUID lowercasing) is exact and channel-independent: `identities_are_exact_normalized_and_independent_of_channels`.
- Booleans and lists round-trip through SQLite: [sqlite/tests/engine.rs](../../../../crates/sqlite/tests/engine.rs) `model_rows_round_trip_booleans_lists_and_copy_aside`.

## 11. Risks and Technical Debt

- **Confirmed limitation: no list of enums, no nested lists.** `validate_type` accepts only scalar elements. Consequence: a `Status[]` field cannot be declared. Evidence: [core/schema.rs](../../../../crates/core/src/schema.rs) `validate_type`. No rationale is recorded; whether this is a deliberate wire constraint needs deciding.
- **Confirmed limitation: enum values are not enforced by storage.** Enum columns are `TEXT` without a `CHECK`; only `normalize_value` rejects unknown names, so rows written before an enum value was removed remain readable as strings the schema cannot decode. Evidence: [client/ddl.rs](../../../../crates/client/src/ddl.rs) `storage_type`; listed under schema evolution in [#20](https://github.com/zanminwang/ahead/issues/20). Owned by [Client / Storage](../client/storage.md).
- Field defaults (`@default`) are a [Models](models.md) finding.
