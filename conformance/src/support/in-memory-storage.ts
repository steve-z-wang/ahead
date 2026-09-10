import type {
  ClaimUplink,
  CompactedInvalidation,
  InvalidationScan,
  InvalidationScopeLookup,
  LocalSyncStorage,
  LockedUplink,
  StoredUplinkReceipt,
} from 'local-sync-backend';
import { readScopeMap, scopesInMap, writeScopeMap } from './in-memory-database';
import type { InMemoryTx } from './in-memory-transactions';

/** Locks, rows, and nothing else: every sync decision belongs to the core. */
export class InMemoryStorage implements LocalSyncStorage<InMemoryTx> {
  async claimAndLockUplink(transaction: InMemoryTx, input: ClaimUplink): Promise<LockedUplink> {
    const existing = transaction.state.uplinkClients.get(input.clientId);
    if (existing === undefined) {
      const created = {
        ownerUserId: input.ownerUserId,
        lastCommittedBatchSequence: 0n,
        requestHash: null,
        responseBytes: null,
      };
      transaction.state.uplinkClients.set(input.clientId, created);
      return { clientId: input.clientId, ...created };
    }
    return { clientId: input.clientId, ...existing };
  }

  async saveUplinkReceipt(transaction: InMemoryTx, receipt: StoredUplinkReceipt): Promise<void> {
    transaction.state.uplinkClients.set(receipt.clientId, {
      ownerUserId: receipt.ownerUserId,
      lastCommittedBatchSequence: receipt.batchSequence,
      requestHash: receipt.requestHash,
      responseBytes: receipt.responseBytes,
    });
  }

  async lockOrCreateDownlinkHead(transaction: InMemoryTx, scope: string): Promise<bigint> {
    const existing = readScopeMap(transaction.state.downlinkHeads, scope);
    if (existing !== undefined) return existing;
    writeScopeMap(transaction.state.downlinkHeads, scope, 0n);
    return 0n;
  }

  async writeDownlinkHead(transaction: InMemoryTx, scope: string, syncId: bigint): Promise<void> {
    writeScopeMap(transaction.state.downlinkHeads, scope, syncId);
    transaction.touchedScopes.add(scope);
  }

  async upsertInvalidation(transaction: InMemoryTx, row: CompactedInvalidation): Promise<void> {
    let models = readScopeMap(transaction.state.invalidations, row.scope);
    if (models === undefined) {
      models = new Map();
      writeScopeMap(transaction.state.invalidations, row.scope, models);
    }
    let identities = models.get(row.modelKey);
    if (identities === undefined) {
      identities = new Map();
      models.set(row.modelKey, identities);
    }
    identities.set(row.identityKey, row);
    transaction.touchedScopes.add(row.scope);
  }

  async readDownlinkHead(transaction: InMemoryTx, scope: string): Promise<bigint> {
    return readScopeMap(transaction.state.downlinkHeads, scope) ?? 0n;
  }

  async scanInvalidations(
    transaction: InMemoryTx,
    query: InvalidationScan,
  ): Promise<readonly CompactedInvalidation[]> {
    const models = readScopeMap(transaction.state.invalidations, query.scope);
    const rows =
      models === undefined
        ? []
        : [...models.values()].flatMap((identities) => [...identities.values()]);
    return rows
      .filter((row) => row.syncId > query.afterSyncId)
      .sort((left, right) => (left.syncId < right.syncId ? -1 : 1))
      .slice(0, query.limit);
  }

  async findInvalidationScopes(
    transaction: InMemoryTx,
    query: InvalidationScopeLookup,
  ): Promise<readonly string[]> {
    return scopesInMap(transaction.state.invalidations)
      .filter((scope) =>
        readScopeMap(transaction.state.invalidations, scope)
          ?.get(query.modelKey)
          ?.has(query.identityKey),
      )
      .sort();
  }
}
