import { InMemoryCommittedChanges } from '../../src/support/in-memory-committed-changes';
import { InMemoryLocalSyncPersistence } from '../../src/support/in-memory-persistence';
import type { InMemoryTx } from '../../src/support/in-memory-transactions';
import { persistenceContract, type PersistenceContractHarness } from './persistence-contract';
const scope = (id: string): string => `User:${id}`;

/**
 * The in-memory adapter, put to the shared contract. Construction and cleanup
 * are all this runner owns: every expectation below the harness is defined
 * once, in persistence-contract.ts, and the product's Prisma adapter answers
 * the same ones in backend/test/integration/local-sync/.
 */
describe('in-memory persistence', () => {
  persistenceContract<InMemoryTx>(async () => {
    let persistence = new InMemoryLocalSyncPersistence();
    const harness: PersistenceContractHarness<InMemoryTx> = {
      get persistence() {
        return persistence;
      },
      // Uplink ownership is independent from the contract-owned Scope UUIDs.
      ownerA: 'viewer-a',
      ownerB: 'viewer-b',
      async reset() {
        persistence = new InMemoryLocalSyncPersistence();
      },
      async close() {
        await persistence.committedChanges.close();
      },
    };
    return harness;
  });
});

/**
 * What only this adapter has. `reconnect` and `listenerCount` are not on the
 * CommittedChanges port, so no other implementation can be asked for them —
 * which is exactly why they stay here rather than in the shared contract.
 */
describe('in-memory committed changes', () => {
  it('forgets a listener whose signal aborted', () => {
    const changes = new InMemoryCommittedChanges();
    const wakes: string[] = [];
    const aborted = new AbortController();
    const a = scope('8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0201');
    const b = scope('8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0202');
    changes.subscribe(a, () => wakes.push('a'), aborted.signal);
    changes.subscribe(b, () => wakes.push('b'), new AbortController().signal);

    changes.notify([a]);
    aborted.abort();
    changes.notify([a]);

    expect(wakes).toEqual(['a']);
    expect(changes.listenerCount).toBe(1);
  });

  it('wakes every live viewer once when the source reconnects', () => {
    const changes = new InMemoryCommittedChanges();
    const wakes: string[] = [];
    changes.subscribe(
      scope('8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0201'),
      () => wakes.push('a'),
      new AbortController().signal,
    );
    changes.subscribe(
      scope('8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0202'),
      () => wakes.push('b'),
      new AbortController().signal,
    );

    changes.reconnect();

    expect(wakes.sort()).toEqual(['a', 'b']);
  });
});
