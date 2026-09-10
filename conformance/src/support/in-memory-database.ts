import type { CompactedInvalidation } from 'local-sync-backend';

/** One durable Model row, with the viewers allowed to read it. */
export interface StoredRow {
  readonly state: Record<string, unknown>;
  readonly viewers: string[];
}

export interface StoredUplinkClient {
  ownerUserId: string;
  lastCommittedBatchSequence: bigint;
  requestHash: string | null;
  responseBytes: Uint8Array | null;
}

export type ScopeMap<T> = Map<string, T>;
export type ModelInvalidations = Map<string, Map<string, CompactedInvalidation>>;

/**
 * Everything the Framework asks a database to hold. It is one plain value so a
 * transaction is a copy of it and a rollback is discarding that copy.
 */
export interface DatabaseState {
  uplinkClients: Map<string, StoredUplinkClient>;
  downlinkHeads: ScopeMap<bigint>;
  invalidations: ScopeMap<ModelInvalidations>;
  rows: Map<string, Map<string, StoredRow>>;
}

export function emptyDatabaseState(): DatabaseState {
  return {
    uplinkClients: new Map(),
    downlinkHeads: new Map(),
    invalidations: new Map(),
    rows: new Map(),
  };
}

export function cloneDatabaseState(state: DatabaseState): DatabaseState {
  return {
    uplinkClients: new Map([...state.uplinkClients].map(([key, value]) => [key, { ...value }])),
    downlinkHeads: cloneScopeMap(state.downlinkHeads, (value) => value),
    invalidations: cloneScopeMap(
      state.invalidations,
      (models) =>
        new Map(
          [...models].map(([modelKey, identities]) => [
            modelKey,
            new Map(
              [...identities].map(([identityKey, row]) => [
                identityKey,
                { ...row },
              ]),
            ),
          ]),
        ),
    ),
    rows: new Map(
      [...state.rows].map(([model, rows]) => [
        model,
        new Map(
          [...rows].map(([identity, row]) => [
            identity,
            { state: { ...row.state }, viewers: [...row.viewers] },
          ]),
        ),
      ]),
    ),
  };
}

export function readScopeMap<T>(map: ScopeMap<T>, scope: string): T | undefined {
  return map.get(scope);
}

export function writeScopeMap<T>(map: ScopeMap<T>, scope: string, value: T): void {
  map.set(scope, value);
}

export function scopesInMap<T>(map: ScopeMap<T>): string[] {
  return [...map.keys()];
}

function cloneScopeMap<T>(source: ScopeMap<T>, cloneValue: (value: T) => T): ScopeMap<T> {
  return new Map(
    [...source].map(([scope, value]) => [scope, cloneValue(value)]),
  );
}
