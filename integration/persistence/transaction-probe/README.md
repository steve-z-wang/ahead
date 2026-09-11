# PostgreSQL transaction contract

Run `bash integration/persistence/transaction-probe/run.sh` from the repository root.
The script owns a temporary PostgreSQL cluster and cleans it up on success/failure.
The Prisma schema and test package live together under `integration/bindings/node`
so client generation resolves the pinned package without installing dependencies
elsewhere in the repository. The native binding and lifecycle notes are in
[Node binding notes](../../../bindings/node/README.md).

Contracts include shared business/framework rollback, a deliberately global-client
negative control, successful commit and closed handles, poison-on-caught-error,
Rust failure after a host write, disposal, transaction timeout, concurrent scopes,
real deferred-constraint commit failure, synchronous callback throw, unawaited work,
and mutation savepoint rollback while earlier work commits.
