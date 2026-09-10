import type { LocalSyncTransactions } from 'local-sync-backend';
import { cloneDatabaseState, emptyDatabaseState, type DatabaseState } from './in-memory-database';

/** The transaction handle the Framework threads through every port call. */
export interface InMemoryTx {
  state: DatabaseState;
  readonly touchedScopes: Set<string>;
  readonly readOnly: boolean;
}

/**
 * A write runs against a copy and replaces the committed state only when it
 * returns; a read runs against a copy nobody can change under it, which is what
 * repeatable read means here.
 */
export class InMemoryTransactions implements LocalSyncTransactions<InMemoryTx> {
  private committed: DatabaseState = emptyDatabaseState();
  private writing: Promise<unknown> = Promise.resolve();

  /** Committed rows, for a test that wants to look without a transaction. */
  get snapshot(): DatabaseState {
    return cloneDatabaseState(this.committed);
  }

  constructor(private readonly onCommit: (scopes: Set<string>) => void) {}

  async write<T>(work: (transaction: InMemoryTx) => Promise<T>): Promise<T> {
    // Serialize writes: a lock this fake cannot hold across processes is a lock
    // it must hold here, or "claim and lock" would mean nothing.
    const previous = this.writing;
    let release = (): void => {};
    this.writing = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous.catch(() => undefined);
    try {
      const transaction: InMemoryTx = {
        state: cloneDatabaseState(this.committed),
        touchedScopes: new Set<string>(),
        readOnly: false,
      };
      const result = await work(transaction);
      this.committed = transaction.state;
      this.onCommit(transaction.touchedScopes);
      return result;
    } finally {
      release();
    }
  }

  async readSnapshot<T>(work: (transaction: InMemoryTx) => Promise<T>): Promise<T> {
    return work({
      state: cloneDatabaseState(this.committed),
      touchedScopes: new Set<string>(),
      readOnly: true,
    });
  }

  async savepoint<T>(transaction: InMemoryTx, work: () => Promise<T>): Promise<T> {
    const restore = cloneDatabaseState(transaction.state);
    try {
      return await work();
    } catch (error) {
      transaction.state = restore;
      throw error;
    }
  }
}
