# Round-trip walkthrough

Run from the repository root:

```bash
./examples/round-trip/run.sh
```

This is a guided executable over existing conformance scenarios, not a separate
starter app. It prepares both toolchains and generated bindings, starts a fresh
TypeScript host on `127.0.0.1` for each scenario, and launches a real Dart client.
The client uses temporary SQLite storage and cleans it up after each journey.
The server closes after every scenario. First-run setup requires network access.

The script prints three `PASS` lines followed by JSON read from the client:

1. **Two scopes:** a generated runtime synchronizes independently checkpointed
   scopes. The space name becomes `Runtime Renamed` and the queue drains.
2. **One named mutation:** 42 optimistic operations form one queue record. A
   pending prerequisite holds them locally; releasing it lets the entire act
   settle, leaving no pending operation.
3. **Rejection:** the host refuses one caption edit, so it returns to `first`.
   An unrelated accepted entry remains `kept`, and the queue drains.

A mismatch exits nonzero. Each client process has a 90-second timeout.

## Read the code

- [Example launcher](run.cjs): server lifecycle, real client subprocess and assertions.
- [Schema definitions](../../conformance/definitions/): models and named mutations.
- [Host wiring](../../conformance/src/support/wire-harness.ts): generated bindings,
  persistence, resolvers, scope policy and authentication passed to `LocalSyncHost`.
- [Mutation resolvers](../../conformance/src/support/mutation-resolvers.ts): server
  business decisions and publication.
- [Generated runtime journey](../../conformance/end-to-end-sync/dart/scenarios/scoped_streams.dart):
  open the SQLite driver, set scope intent, start synchronization, and read models.
- [Named mutation journey](../../conformance/end-to-end-sync/dart/scenarios/named_mutation.dart):
  project a typed mutation locally, hold its prerequisite, then observe settlement.
- [Rejection journey](../../conformance/end-to-end-sync/dart/scenarios/rejection_rebuild.dart):
  enqueue accepted and refused edits and read their reconciled state.

The scenarios use fixture models such as `Space` and `Moment`. They do not load
an application database or depend on application code.

## Integration boundary

The server stores data in memory and accepts a fixed demonstration credential.
It is intended only for this local walkthrough. A real application supplies its
own authentication, durable persistence, model loaders, mutation resolvers and
scope authorization. Clients supply their credential callback, database
migrations and prerequisite handlers. This source release does not include a
production persistence adapter or publish packages to a registry.
