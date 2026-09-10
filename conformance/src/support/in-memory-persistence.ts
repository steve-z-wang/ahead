import type { LocalSyncPersistence } from 'local-sync-backend';
import type { DatabaseState } from './in-memory-database';
import { InMemoryCommittedChanges } from './in-memory-committed-changes';
import { InMemoryStorage } from './in-memory-storage';
import { InMemoryTransactions, type InMemoryTx } from './in-memory-transactions';

/**
 * The one persistence argument a product hands the Framework. Its three ports
 * stay separately testable; setup never takes them apart.
 */
export class InMemoryLocalSyncPersistence implements LocalSyncPersistence<InMemoryTx> {
  readonly committedChanges = new InMemoryCommittedChanges();
  readonly storage = new InMemoryStorage();
  readonly transactions = new InMemoryTransactions((scopes) =>
    this.committedChanges.notify(scopes),
  );

  /** Committed rows, for a test that inspects the host after a call. */
  get snapshot(): DatabaseState {
    return this.transactions.snapshot;
  }
}
