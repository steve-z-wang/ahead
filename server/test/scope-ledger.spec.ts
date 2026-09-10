import {
  CompactedInvalidation,
  GeneratedBackendContract,
  LocalSyncIdentityError,
  LocalSyncStorage,
  SyncModelDescriptor,
  createScopeLedger,
} from '../src';

interface Tx {
  readonly id: string;
}

const UserScope = 'User';
const SpaceScope = 'Space';
const userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const otherId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

const forward = Object.freeze({
  create: async () => undefined,
  update: async () => undefined,
  delete: async () => undefined,
  read: async () => [],
});

const model = {
  name: 'IdentitySample',
  identityFields: ['id'],
  fields: [
    {
      name: 'id',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
  ],
  forward,
} as const satisfies SyncModelDescriptor<{ readonly id: string }>;

function contract(): GeneratedBackendContract {
  return { enumValues: {}, models: { identitySample: model } };
}

function scope(model_: string, id = userId): string {
  return `${model_}:${id}`;
}

function scopeLabel(value: string): string {
  return value;
}

class RecordingStorage implements LocalSyncStorage<Tx> {
  readonly calls: Array<{
    readonly operation: string;
    readonly transaction: Tx;
    readonly scope?: string;
    readonly syncId?: bigint;
    readonly row?: CompactedInvalidation;
  }> = [];
  readonly heads = new Map<string, bigint>();
  readonly rows: CompactedInvalidation[] = [];
  failure: Error | null = null;

  async lockOrCreateDownlinkHead(transaction: Tx, scope_: string) {
    this.calls.push({ operation: 'lock', transaction, scope: scope_ });
    return this.heads.get(scopeLabel(scope_)) ?? 0n;
  }

  async writeDownlinkHead(transaction: Tx, scope_: string, syncId: bigint) {
    this.calls.push({ operation: 'head', transaction, scope: scope_, syncId });
    if (this.failure !== null) throw this.failure;
    this.heads.set(scopeLabel(scope_), syncId);
  }

  async upsertInvalidation(transaction: Tx, row: CompactedInvalidation) {
    this.calls.push({
      operation: 'invalidation',
      transaction,
      scope: row.scope,
      syncId: row.syncId,
      row,
    });
    const existing = this.rows.findIndex(
      (candidate) =>
        scopeLabel(candidate.scope) === scopeLabel(row.scope) &&
        candidate.modelKey === row.modelKey &&
        candidate.identityKey === row.identityKey,
    );
    if (existing === -1) this.rows.push(row);
    else this.rows[existing] = row;
  }

  async findInvalidationScopes(
    transaction: Tx,
    query: { modelKey: string; identityKey: string },
  ) {
    this.calls.push({ operation: 'scopesFor', transaction });
    return this.rows
      .filter(
        (row) =>
          row.modelKey === query.modelKey && row.identityKey === query.identityKey,
      )
      .map((row) => row.scope);
  }

  claimAndLockUplink(): never {
    throw new Error('not used by ScopeLedger');
  }
  saveUplinkReceipt(): never {
    throw new Error('not used by ScopeLedger');
  }
  readDownlinkHead(): never {
    throw new Error('ScopeLedger must lock the head before allocation');
  }
  scanInvalidations(): never {
    throw new Error('not used by ScopeLedger');
  }
}

function fixture(registeredModels = new Set(['identitySample'])) {
  const storage = new RecordingStorage();
  const ledger = createScopeLedger({
    contract: contract(),
    storage,
    registeredModels,
  });
  return { ledger, storage };
}

describe('ScopeLedger', () => {
  it('returns void and writes nothing for an empty scope list', async () => {
    const { ledger, storage } = fixture();

    await expect(
      ledger.invalidate(
        { id: 'tx' },
        { model, identity: { id: userId.toUpperCase() }, scopes: [] },
      ),
    ).resolves.toBeUndefined();
    expect(storage.calls).toEqual([]);
  });

  it('normalizes, sorts, and deduplicates concrete scopes before allocation', async () => {
    const { ledger, storage } = fixture();
    storage.heads.set(scopeLabel(scope(UserScope)), 4n);
    const transaction = { id: 'caller-owned' };

    await expect(
      ledger.invalidate(transaction, {
        model,
        identity: { id: userId.toUpperCase() },
        scopes: [
          scope(UserScope),
          scope(SpaceScope),
          scope(UserScope),
          scope(UserScope, otherId),
        ],
      }),
    ).resolves.toBeUndefined();

    expect(
      storage.calls.map(
        (call) => `${call.operation}:${call.scope && scopeLabel(call.scope)}`,
      ),
    ).toEqual([
      `lock:Space:${userId}`,
      `head:Space:${userId}`,
      `invalidation:Space:${userId}`,
      `lock:User:${userId}`,
      `head:User:${userId}`,
      `invalidation:User:${userId}`,
      `lock:User:${otherId}`,
      `head:User:${otherId}`,
      `invalidation:User:${otherId}`,
    ]);
    expect(storage.heads.get(`Space:${userId}`)).toBe(1n);
    expect(storage.heads.get(`User:${userId}`)).toBe(5n);
    expect(storage.heads.get(`User:${otherId}`)).toBe(1n);
    expect(storage.calls.every((call) => call.transaction === transaction)).toBe(
      true,
    );
    expect(storage.rows).toHaveLength(3);
    for (const row of storage.rows) {
      expect(row.modelKey).toBe('identitySample');
      expect(row.identityKey).toBe(`{"id":"${userId}"}`);
      expect(Buffer.from(row.identityBytes).toString('utf8')).toBe(row.identityKey);
    }
  });

  it('advances an existing compacted entry instead of appending another', async () => {
    const { ledger, storage } = fixture();
    const target = scope(UserScope);

    await ledger.invalidate(
      { id: 'first' },
      { model, identity: { id: userId }, scopes: [target] },
    );
    await ledger.invalidate(
      { id: 'second' },
      { model, identity: { id: userId }, scopes: [target] },
    );

    expect(storage.heads.get(scopeLabel(target))).toBe(2n);
    expect(storage.rows).toHaveLength(1);
    expect(storage.rows[0].syncId).toBe(2n);
  });

  it('rejects an exhausted counter before writing a new position', async () => {
    const { ledger, storage } = fixture();
    const target = scope(UserScope);
    storage.heads.set(scopeLabel(target), (1n << 63n) - 1n);

    await expect(
      ledger.invalidate(
        { id: 'tx' },
        { model, identity: { id: userId }, scopes: [target] },
      ),
    ).rejects.toBeInstanceOf(RangeError);
    expect(storage.calls.map((call) => call.operation)).toEqual(['lock']);
  });

  it('rejects an unregistered synchronized Model before storage', async () => {
    const { ledger, storage } = fixture(new Set());

    await expect(
      ledger.invalidate(
        { id: 'tx' },
        { model, identity: { id: userId }, scopes: [scope(UserScope)] },
      ),
    ).rejects.toBeInstanceOf(LocalSyncIdentityError);
    expect(storage.calls).toEqual([]);
  });

  it('propagates persistence failure through the caller-owned transaction', async () => {
    const { ledger, storage } = fixture();
    storage.failure = new Error('write failed');

    await expect(
      ledger.invalidate(
        { id: 'tx' },
        { model, identity: { id: userId }, scopes: [scope(UserScope)] },
      ),
    ).rejects.toThrow('write failed');
    expect(storage.calls.map((call) => call.operation)).toEqual(['lock', 'head']);
  });

  it('finds concrete scopes using the canonical Model identity', async () => {
    const { ledger, storage } = fixture();
    storage.rows.push(
      {
        scope: scope(UserScope),
        modelKey: 'identitySample',
        identityKey: `{"id":"${userId}"}`,
        identityBytes: new TextEncoder().encode(`{"id":"${userId}"}`),
        syncId: 1n,
      },
      {
        scope: scope(SpaceScope),
        modelKey: 'identitySample',
        identityKey: `{"id":"${userId}"}`,
        identityBytes: new TextEncoder().encode(`{"id":"${userId}"}`),
        syncId: 1n,
      },
    );

    await expect(
      ledger.scopesFor(
        { id: 'tx' },
        { model, identity: { id: userId.toUpperCase() } },
      ),
    ).resolves.toEqual([scope(SpaceScope), scope(UserScope)]);
    expect(storage.calls.map((call) => call.operation)).toEqual(['scopesFor']);
  });
});
