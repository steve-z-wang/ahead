# client-storage-contract

**Participants:** the Dart database port and each adapter that implements it.

**Owns:** transactions, savepoints, snapshots, migration execution, statements
and queries, reactivity, lifecycle and error semantics.

**Does not own:** sync state-machine behavior. An adapter's own
implementation details stay package-local, in
`client/local_sync_database_sqlite/test/`.

```bash
conformance/tool/test.sh client-storage-contract
```

## Registering an adapter

`dart/database_contract.dart` holds every assertion. An adapter file holds a
name and a factory, and nothing else — no `test(...)` of its own, or the next
adapter starts by copying assertions.

```dart
typedef OpenContractDatabase = Future<Database> Function(Directory directory);

void databaseContract({
  required String adapterName,
  required OpenContractDatabase open,
});
```

The factory opens the fixture database inside the supplied directory, applying
the fixture schema at version 1. It is called more than once per case with the
same directory — the contract reopens the database to prove migrations are
durable, and opens a second handle to prove one transaction's view is stable —
so it must address the same database each time. The contract owns the
directory, closes every handle it obtained, and cleans up.

The fixture schema is four tables: `fixture_items` (autoincrementing `id`, a
`NOT NULL UNIQUE` text `name`), `fixture_others` (autoincrementing `id`, the
unrelated table reactivity must ignore), and `fixture_parents` /
`fixture_children` joined by a cascading foreign key. `dart/` holds the exact
SQL, twice: as the requirement in `database_contract.dart`'s doc comment, and
as SQLite's answer to it in `sqlite_database_contract_test.dart`.

## The matrix

Fourteen cases, per adapter:

| Case | Proves |
|---|---|
| query and execute return materialized results | columns, ordered rows, affected rows, last insert id — read fully, not lazily over a live cursor |
| migrations are not reapplied when the database reopens | migration execution is durable and runs once |
| reopens repeatedly after reactive readers are closed | open/close leaks no lifecycle state after reactive readers |
| transaction commits, returns a value, and rolls back failures | the callback's value is returned; a thrown error rolls the writes back |
| savepoint can roll back without aborting its outer transaction | a nested unit fails alone, and its outer transaction still commits |
| transaction view is stable until a competing write can commit | a second connection's write cannot land mid-transaction, and lands after |
| transaction handle expires with its callback | an escaped handle is closed, never a second lane into the database |
| watch emits initially and after a relevant committed write | current state first, then committed changes |
| watch ignores writes to unrelated tables | reactivity is scoped to the query's tables |
| watchTables emits for named tables without a signal query | the table-level signal needs no query to carry it |
| watch reflects commit state and ignores rollback state | no reactive state exists that the database does not hold |
| constraint failures use the common error model | `DatabaseErrorKind.constraint`, whatever the engine says |
| enables foreign keys on pooled connections | a declared cascade is enforced, on any connection the pool hands out |
| close is idempotent and rejects later calls | closing twice is fine; using a closed database is `DatabaseErrorKind.closed` |
