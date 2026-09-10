export interface ClaimUplink {
  readonly ownerUserId: string;
  readonly clientId: string;
}

export interface LockedUplink {
  readonly ownerUserId: string;
  readonly clientId: string;
  readonly lastCommittedBatchSequence: bigint;
  readonly requestHash: string | null;
  readonly responseBytes: Uint8Array | null;
}

export interface StoredUplinkReceipt {
  readonly ownerUserId: string;
  readonly clientId: string;
  readonly batchSequence: bigint;
  readonly requestHash: string;
  readonly responseBytes: Uint8Array;
}

export interface CompactedInvalidation {
  readonly scope: string;
  readonly modelKey: string;
  readonly identityKey: string;
  readonly identityBytes: Uint8Array;
  readonly syncId: bigint;
}

export interface InvalidationScan {
  readonly scope: string;
  readonly afterSyncId: bigint;
  readonly limit: number;
}

export interface InvalidationScopeLookup {
  readonly modelKey: string;
  readonly identityKey: string;
}

export interface LocalSyncStorage<TTx> {
  claimAndLockUplink(transaction: TTx, input: ClaimUplink): Promise<LockedUplink>;
  saveUplinkReceipt(transaction: TTx, receipt: StoredUplinkReceipt): Promise<void>;
  lockOrCreateDownlinkHead(transaction: TTx, scope: string): Promise<bigint>;
  writeDownlinkHead(transaction: TTx, scope: string, syncId: bigint): Promise<void>;
  upsertInvalidation(transaction: TTx, row: CompactedInvalidation): Promise<void>;
  /** The last sync id issued to this scope, or zero for a scope with none. */
  readDownlinkHead(transaction: TTx, scope: string): Promise<bigint>;
  scanInvalidations(
    transaction: TTx,
    query: InvalidationScan,
  ): Promise<readonly CompactedInvalidation[]>;
  findInvalidationScopes(
    transaction: TTx,
    query: InvalidationScopeLookup,
  ): Promise<readonly string[]>;
}
