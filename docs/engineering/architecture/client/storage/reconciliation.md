# Reconciliation

## 1. Introduction and Goals

The client stores no schema descriptor. The tables themselves are the record of what schema created them, and opening the client compares them with the compiled schema it was given. Reconciliation makes the tables match when it can do so without losing data, and refuses to open when it cannot.

## 3. Context and Scope

Runs once inside the opening transaction, after the framework tables exist and before the client row is read ([Frontend interface](../frontend-interface.md)). Input: the compiled schema and `PRAGMA table_info` of each model table. Output: the tables match, or an error and an untouched file.

## 5. Building Block View

Per model there are two tables with identical columns: the visible table named after the model and `ahead_before_<Model>` for before images ([Writes](../engine/local-operations/writes.md)). Column types follow [Types](../../schema/types.md); the identity is the primary key in `@@id` order; each `@@unique` becomes a unique index on the visible table. Ten framework tables (`ahead_client`, `ahead_record`, `ahead_claim`, `ahead_subscription`, the four queue tables, `ahead_push_checkpoint`, `ahead_rejection`) are created with `IF NOT EXISTS`.

Code: [client/ddl.rs](../../../../../crates/client/src/ddl.rs).

## 6. Runtime View

What reconciliation does depends on the kind of difference. The three outcomes are different in kind and should not be summarized as "schema changes are refused":

| Difference between schema and table | Outcome |
| --- | --- |
| Model table missing | created, with its before table and indexes |
| Field missing from the table, nullable | column added to both tables |
| Field missing, non-nullable, default in the descriptor | column added with that default |
| Field missing, non-nullable, no default | **refused**; open fails |
| Identity columns differ | **refused** |
| Column storage type differs | **refused** |
| Column in the table but not in the schema | **kept**, never read or written |
| Unique index no longer declared | **kept**, still enforced |
| Enum value set changed | **not detected**; the column is `TEXT` |
| Model removed from the schema | its tables are **kept** |

Consequences worth knowing: a field rename is handled as "remove the old field, add the new one", so the old column stays in place and the new column follows the rows above for an added field: filled with `null` if nullable, with the declared default if it has one, and refused (open fails) if it is non-nullable without a default; the old column's values are not carried over. A stale unique index keeps constraining rows; and rows holding an enum value the schema no longer declares remain readable as strings that normalization will reject. A refused reconciliation rolls back and leaves the file exactly as it was; the only remedy today is a new database file (guarantee N3).

## 10. Quality Requirements

- **Additive changes open and fill existing rows; unknown columns survive.** Evidence: [sqlite/tests/ddl.rs](../../../../../crates/sqlite/tests/ddl.rs) `adds_missing_columns_to_both_tables_and_keeps_unknown_ones`.
- **Identity, type and default-less non-nullable changes are refused without touching the file** (guarantee C3). Evidence: `rejects_non_nullable_column_without_default_identity_change_and_type_change`.
- **A fresh database gets model, before and framework tables and enforces unique indexes.** Evidence: `creates_model_before_and_framework_tables`.

Tests read, not executed. Reconciliation with a non-empty queue is not tested; the claim that queued operation bytes survive an additive change follows from the row layout (guarantee C3 note).

## 11. Risks and Technical Debt

**Problem: a non-nullable field cannot be added to a model with data.** The descriptor supports a default, but the compiler cannot emit one ([Models](../../schema/models.md)), so the "added with default" row above is unreachable from a `.model` file. Tracked in [#27](https://github.com/zanminwang/ahead/issues/27) and [#20](https://github.com/zanminwang/ahead/issues/20).

**Accepted limitation (contract to be decided in [#20](https://github.com/zanminwang/ahead/issues/20)).** Kept columns, kept indexes and undetected enum changes are the current behavior, not a design; #20 lists the open decisions, including whether stale indexes should be dropped and what an explicit reset looks like.
