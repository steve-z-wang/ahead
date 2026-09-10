# server-persistence-contract

**Participants:** the TypeScript persistence ports and the adapters that
implement them — the in-memory one here, the product's beside the product.

**Owns:** transactions, snapshots, receipts, heads, invalidations, and
committed-change semantics.

**Does not own:** HTTP, Model bindings, or domain behavior.

```bash
conformance/tool/test.sh server-persistence-contract
```

## One definition, two runners

`typescript/persistence-contract.ts` holds every shared assertion, once.
A runner supplies a harness and nothing else:

```ts
export interface PersistenceContractHarness<TTx> {
  readonly persistence: LocalSyncPersistence<TTx>;
  readonly ownerA: string;
  readonly ownerB: string;
  reset(): Promise<void>; // empty state, listener-free source, per case
  close(): Promise<void>; // release what the factory acquired
}

persistenceContract<TTx>(async () => harness);
```

The two owner ids belong only to Uplink claims, whose owner is an authenticated
User. The contract creates its own opaque scope strings. A Head or invalidation
may not require a matching domain row: scope is a consumer-owned text key, not
a registered namespace or a domain foreign key.

The contract imports framework port types and Jest globals, and nothing else.
It must never import Prisma, Nest, a backend path, or an in-memory class: the
import runs product → framework, never the reverse, which is why the runner
that constructs `PrismaLocalSyncPersistence` lives in `backend/`.

| Runner                                                               | Adapter                      | Gate                                                     |
| -------------------------------------------------------------------- | ---------------------------- | -------------------------------------------------------- |
| `typescript/storage-ports.spec.ts`                                   | in-memory                    | `tool/gate.sh` — no product database, ever    |
| `backend/test/integration/prisma-persistence.int-spec.ts` | `PrismaLocalSyncPersistence` | `backend`'s `npm run test:int` — testcontainers Postgres |

Neither gate runs the other's adapter, and neither copies an assertion body.

## The shared matrix

Twenty-three cases, in five groups: **transactions** (commit and rollback,
nested savepoints with the outer write intact, a read snapshot blind to a
commit landing under it); **downlink heads** (zero for a scope with no head,
creation at zero under concurrent first publication, a lock that does not move
an existing head, full exact-string isolation); **uplink receipts** (a new claim at
sequence zero, the first claimant retained as owner against a second account,
exact byte and sequence replay, per-client isolation); **invalidations**
(compaction per scope/Model/identity, every field round-tripped, sync-id
order with an exclusive cursor and a limit, full scope isolation, and sorted
identity-first scope lookup); and
**committed changes** (a wake only once the write committed, silence on
rollback, a wake after a rolled-back savepoint gave its sync ids back, an
untouched scope left alone, a subscriber that attached mid-write woken, an
aborted subscriber never woken, and nothing taken or woken after close).

## What stays beside its adapter

A case belongs to one adapter when no other implementation could be asked the
question. Postgres row locking, SQL, the wall-clock of a long transaction, and
`InMemoryCommittedChanges.reconnect()` / `listenerCount` — which are not on the
`CommittedChanges` port at all — are all of that kind, and they live in their
own runner under a clearly named group.

The reverse move is the one to refuse. If an adapter cannot satisfy a shared
case, that is a finding about the adapter: report it and fix the adapter.
Softening, skipping, or branching an assertion on the adapter's name turns the
contract back into two sets of expectations, which is the drift it exists to
end.

Two behaviors are deliberately _not_ promises, because the adapters differ and
the Framework never depends on either: whether `writeDownlinkHead` alone marks
a scope as touched (the in-memory adapter says yes, Prisma says no — in the
real write path a head move always accompanies an invalidation), and whether
`close()` wakes the listeners already parked (Prisma's does, so shutdown
releases them; the in-memory one does not). The contract asks only what every
adapter must answer the same way.
