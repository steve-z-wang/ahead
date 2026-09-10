import {
  BackendComponents,
  BackendModelBinding,
  BackendWriteContext,
  CompactedInvalidation,
  GeneratedBackendContract,
  GeneratedMutationContract,
  LocalSyncIdentityError,
  LocalSyncOwnerMismatchError,
  LocalSyncProtocolError,
  LocalSyncSequenceError,
  LocalSyncMutationRejected,
  MutationSettlement,
  LocalSyncStorage,
  LocalSyncTransactions,
  StoredUplinkReceipt,
  UplinkExecutor,
  createUplinkExecutor,
  createScopeLedger,
  validateBackendOptions,
} from '../src';

/**
 * The executor's own subjects — batch sequencing, frozen replay, per-mutation
 * savepoints, positional settlement, rejection classification and receipt
 * hashing — driven the one way a write reaches this server: as a named act
 * (CAP-444).
 */

interface Tx {
  readonly id: number;
}

const UserScope = 'User';
const BookScope = 'Book';
const viewerScopeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const bookScopeId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

interface SpaceIdentity {
  readonly id: string;
}

interface SpaceState extends SpaceIdentity {
  readonly title: string;
  readonly nickname: string | null;
  readonly count: number;
}

interface SpaceCreate {
  readonly title: string;
  readonly nickname: string | null;
  readonly count: number;
}

interface SpacePatch {
  readonly title?: string;
  readonly nickname?: string | null;
  readonly count?: number;
}

interface StarIdentity {
  readonly userId: string;
  readonly momentId: string;
}

interface StarState extends StarIdentity {
  readonly label: string;
  readonly note: string | null;
}

interface StarCreate {
  readonly label: string;
  readonly note: string | null;
}

interface StarPatch {
  readonly label?: string;
  readonly note?: string | null;
}

const spaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const otherSpaceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

function decodeResponse(bytes: Uint8Array): unknown {
  return JSON.parse(Buffer.from(bytes).toString('utf8'));
}

const spaceDescriptor = {
  name: 'Space',
  identityFields: ['id'],
  fields: [
    {
      name: 'count',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'int' },
    },
    {
      name: 'id',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'nickname',
      nullable: true,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
    {
      name: 'title',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
  ],
  forward: { read: async () => [] },
} as const;

const starDescriptor = {
  name: 'Star',
  identityFields: ['userId', 'momentId'],
  fields: [
    {
      name: 'label',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
    {
      name: 'momentId',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'note',
      nullable: true,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
    {
      name: 'userId',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
  ],
  forward: { read: async () => [] },
} as const;

function generatedContract(): GeneratedBackendContract {
  return {
    enumValues: {},
    models: { space: spaceDescriptor, star: starDescriptor },
  };
}

/// One act per `(Model, op)` pair, so every operation kind still has a way in.
function slot(name: string, model: string, operation: string) {
  return {
    name,
    model,
    operation,
    cardinality: 'single',
    ...(operation === 'update'
      ? {
          allowedPatchFields:
            model === 'Space' ? ['title', 'nickname'] : ['note'],
        }
      : {}),
  };
}

const forwardAct = async (
  resolver: (
    context: unknown,
    arguments_: unknown,
  ) => Promise<MutationSettlement | void>,
  context: unknown,
  arguments_: unknown,
) => resolver(context, arguments_);

function mutationContract(): GeneratedMutationContract {
  return {
    mutations: {
      createSpace: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'CreateSpace',
          slots: [slot('space', 'Space', 'create')],
          forward: forwardAct,
        },
      },
      renameSpace: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'RenameSpace',
          slots: [slot('space', 'Space', 'update')],
          forward: forwardAct,
        },
      },
      deleteSpace: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'DeleteSpace',
          slots: [slot('space', 'Space', 'delete')],
          forward: forwardAct,
        },
      },
      starMoment: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'StarMoment',
          slots: [slot('star', 'Star', 'create')],
          forward: forwardAct,
        },
      },
      annotateStar: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'AnnotateStar',
          slots: [slot('star', 'Star', 'update')],
          forward: forwardAct,
        },
      },
      unstarMoment: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'UnstarMoment',
          slots: [slot('star', 'Star', 'delete')],
          forward: forwardAct,
        },
      },
    },
  } as unknown as GeneratedMutationContract;
}

interface Handlers {
  createSpace(
    context: BackendWriteContext<Tx>,
    arguments_: {
      readonly space: {
        readonly identity: SpaceIdentity;
        readonly data: SpaceCreate;
      };
    },
  ): Promise<MutationSettlement | void>;
  renameSpace(
    context: BackendWriteContext<Tx>,
    arguments_: {
      readonly space: {
        readonly identity: SpaceIdentity;
        readonly patch: SpacePatch;
      };
    },
  ): Promise<MutationSettlement | void>;
  deleteSpace(
    context: BackendWriteContext<Tx>,
    arguments_: { readonly space: { readonly identity: SpaceIdentity } },
  ): Promise<MutationSettlement | void>;
  starMoment(
    context: BackendWriteContext<Tx>,
    arguments_: {
      readonly star: {
        readonly identity: StarIdentity;
        readonly data: StarCreate;
      };
    },
  ): Promise<MutationSettlement | void>;
  annotateStar(
    context: BackendWriteContext<Tx>,
    arguments_: {
      readonly star: {
        readonly identity: StarIdentity;
        readonly patch: StarPatch;
      };
    },
  ): Promise<MutationSettlement | void>;
  unstarMoment(
    context: BackendWriteContext<Tx>,
    arguments_: { readonly star: { readonly identity: StarIdentity } },
  ): Promise<MutationSettlement | void>;
}

class Storage implements LocalSyncStorage<Tx> {
  locked:
    | {
        ownerUserId: string;
        clientId: string;
        lastCommittedBatchSequence: bigint;
        requestHash: string | null;
        responseBytes: Uint8Array | null;
      }
    | undefined;
  receiptWrites = 0;
  head = 0n;
  readonly heads = new Map<string, bigint>();
  readonly headReads: string[] = [];
  readonly ledgerHeads = new Map<string, bigint>();
  readonly invalidations: CompactedInvalidation[] = [];
  readonly ledgerTransactions: Tx[] = [];

  async claimAndLockUplink(
    _transaction: Tx,
    input: { ownerUserId: string; clientId: string },
  ) {
    this.locked ??= {
      ...input,
      lastCommittedBatchSequence: 0n,
      requestHash: null,
      responseBytes: null,
    };
    return this.locked;
  }

  async saveUplinkReceipt(_transaction: Tx, receipt: StoredUplinkReceipt) {
    this.receiptWrites += 1;
    this.locked = {
      ownerUserId: receipt.ownerUserId,
      clientId: receipt.clientId,
      lastCommittedBatchSequence: receipt.batchSequence,
      requestHash: receipt.requestHash,
      responseBytes: Uint8Array.from(receipt.responseBytes),
    };
  }

  async readDownlinkHead(_transaction: Tx, scope: string): Promise<bigint> {
    this.headReads.push(scope);
    return this.heads.get(scope) ?? this.head;
  }

  async lockOrCreateDownlinkHead(transaction: Tx, scope: string) {
    this.ledgerTransactions.push(transaction);
    return this.ledgerHeads.get(scope) ?? 0n;
  }

  async writeDownlinkHead(transaction: Tx, scope: string, syncId: bigint) {
    this.ledgerTransactions.push(transaction);
    this.ledgerHeads.set(scope, syncId);
  }

  async upsertInvalidation(transaction: Tx, row: CompactedInvalidation) {
    this.ledgerTransactions.push(transaction);
    this.invalidations.push(row);
  }

  scanInvalidations(): never {
    throw new Error('not used');
  }

  async findInvalidationScopes() {
    return [];
  }
}

class Transactions implements LocalSyncTransactions<Tx> {
  writeCount = 0;
  savepointCount = 0;
  readonly tx: Tx = { id: 1 };
  private tail: Promise<void> = Promise.resolve();

  constructor(
    private readonly domainCalls: Array<{ operation: string; value: unknown }>,
  ) {}

  async write<T>(work: (transaction: Tx) => Promise<T>): Promise<T> {
    this.writeCount += 1;
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      return await work(this.tx);
    } finally {
      release();
    }
  }

  readSnapshot(): never {
    throw new Error('not used');
  }

  async savepoint<T>(_transaction: Tx, work: () => Promise<T>): Promise<T> {
    this.savepointCount += 1;
    const checkpoint = this.domainCalls.length;
    try {
      return await work();
    } catch (error) {
      this.domainCalls.splice(checkpoint);
      throw error;
    }
  }
}

function harness(): {
  readonly executor: UplinkExecutor;
  readonly storage: Storage;
  readonly transactions: Transactions;
  readonly calls: Array<{ operation: string; value: unknown }>;
  readonly components: BackendComponents<Tx>;
  /** Swappable in place, so a case can make one act refuse or fail. */
  readonly handlers: Handlers;
} {
  const storage = new Storage();
  const calls: Array<{ operation: string; value: unknown }> = [];
  const transactions = new Transactions(calls);
  const binding: BackendModelBinding<Tx, SpaceIdentity, SpaceState> = {
    read: { forViewer: async () => [] },
  };
  const starBinding: BackendModelBinding<Tx, StarIdentity, StarState> = {
    read: { forViewer: async () => [] },
  };
  const handlers: Handlers = {
    createSpace: async (_context, arguments_) => {
      calls.push({ operation: 'create', value: arguments_.space });
    },
    renameSpace: async (_context, arguments_) => {
      calls.push({ operation: 'update', value: arguments_.space });
    },
    deleteSpace: async (_context, arguments_) => {
      calls.push({ operation: 'delete', value: arguments_.space });
    },
    starMoment: async (_context, arguments_) => {
      calls.push({ operation: 'star.create', value: arguments_.star });
    },
    annotateStar: async (_context, arguments_) => {
      calls.push({ operation: 'star.update', value: arguments_.star });
    },
    unstarMoment: async (_context, arguments_) => {
      calls.push({ operation: 'star.delete', value: arguments_.star });
    },
  };
  const components = validateBackendOptions<Tx>({
    contract: generatedContract(),
    models: { space: binding, star: starBinding },
    scopeAuthorizer: { canRead: async () => true },
    principalScope: () => `${UserScope}:${viewerScopeId}`,
    mutationContract: mutationContract(),
    // Registered once and dispatched through the mutable holder, so swapping a
    // handler mid-case reaches the executor.
    mutations: {
      createSpace: {
        v1: (context: never, arguments_: never) =>
          handlers.createSpace(context, arguments_),
      },
      renameSpace: {
        v1: (context: never, arguments_: never) =>
          handlers.renameSpace(context, arguments_),
      },
      deleteSpace: {
        v1: (context: never, arguments_: never) =>
          handlers.deleteSpace(context, arguments_),
      },
      starMoment: {
        v1: (context: never, arguments_: never) =>
          handlers.starMoment(context, arguments_),
      },
      annotateStar: {
        v1: (context: never, arguments_: never) =>
          handlers.annotateStar(context, arguments_),
      },
      unstarMoment: {
        v1: (context: never, arguments_: never) =>
          handlers.unstarMoment(context, arguments_),
      },
    },
    persistence: {
      transactions,
      storage,
      committedChanges: {
        subscribe: () => undefined,
        close: async () => undefined,
      },
    },
  });
  return {
    executor: createUplinkExecutor(components),
    storage,
    transactions,
    calls,
    components,
    handlers,
  };
}

/// One act, as a client spells it: a name and the operations it already
/// showed on screen.
function act(
  ordinal: bigint | number,
  name: string,
  operations: readonly unknown[],
) {
  return { ordinal: Number(ordinal), name, operations };
}

function createSpace(
  ordinal: bigint | number = 1n,
  values: unknown = { title: 'title', count: 2 },
  identity: unknown = { id: spaceId },
) {
  return act(ordinal, 'CreateSpace', [
    { model: 'Space', op: 'create', identity, values },
  ]);
}

function renameSpace(ordinal: bigint | number = 1n) {
  return act(ordinal, 'RenameSpace', [
    {
      model: 'Space',
      op: 'update',
      identity: { id: spaceId },
      values: { title: 'renamed' },
    },
  ]);
}

function request(
  batchSequence: bigint,
  mutations: readonly unknown[] = [createSpace(1n)],
  clientId = 'client',
) {
  return { clientId, batchSequence: Number(batchSequence), mutations };
}

function encode(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

async function upload(executor: UplinkExecutor, value: unknown) {
  return executor.execute({
    principal: { userId: 'actor' },
    requestBytes: encode(value),
  });
}

describe('Uplink sequence and envelope validation', () => {
  it('rejects undecodable and invalid top-level envelopes before a transaction', async () => {
    const invalid = [
      Uint8Array.from([255]),
      encode(request(0n)),
      encode(request(1n, [], 'client')),
      encode(request(1n, [createSpace(1n)], '')),
      encode(
        request(
          1n,
          Array.from({ length: 21 }, (_, index) => createSpace(index + 1)),
        ),
      ),
    ];

    for (const requestBytes of invalid) {
      const { executor, transactions } = harness();
      await expect(
        executor.execute({ principal: { userId: 'actor' }, requestBytes }),
      ).rejects.toBeInstanceOf(LocalSyncProtocolError);
      expect(transactions.writeCount).toBe(0);
    }
  });

  it('accepts one mutation larger than the 256 KiB client target', async () => {
    const { executor, transactions, calls } = harness();
    const oversized = createSpace(1n, {
      title: 'x'.repeat(300 * 1024),
      count: 1,
    });

    await expect(
      upload(executor, request(1n, [oversized])),
    ).resolves.toBeInstanceOf(Uint8Array);
    expect(transactions.writeCount).toBe(1);
    expect(calls).toHaveLength(1);
  });

  it('enforces owner and exact next sequence after atomic claim', async () => {
    const owner = harness();
    owner.storage.locked = {
      ownerUserId: 'other',
      clientId: 'client',
      lastCommittedBatchSequence: 0n,
      requestHash: null,
      responseBytes: null,
    };
    await expect(upload(owner.executor, request(1n))).rejects.toBeInstanceOf(
      LocalSyncOwnerMismatchError,
    );

    const gap = harness();
    await expect(upload(gap.executor, request(2n))).rejects.toMatchObject({
      constructor: LocalSyncSequenceError,
      reason: 'gap',
    });

    const overlap = harness();
    overlap.storage.locked = {
      ownerUserId: 'actor',
      clientId: 'client',
      lastCommittedBatchSequence: 3n,
      requestHash: 'old',
      responseBytes: encode({ requiredSyncId: 0, rejections: [] }),
    };
    await expect(upload(overlap.executor, request(2n))).rejects.toMatchObject({
      constructor: LocalSyncSequenceError,
      reason: 'overlap',
    });
  });

  it('atomically assigns one owner when principals race to claim a client', async () => {
    const fixture = harness();
    const requestBytes = encode(request(1n));
    const actor = fixture.executor.execute({
      principal: { userId: 'actor' },
      requestBytes,
    });
    const other = fixture.executor.execute({
      principal: { userId: 'other' },
      requestBytes,
    });

    await expect(actor).resolves.toBeInstanceOf(Uint8Array);
    await expect(other).rejects.toBeInstanceOf(LocalSyncOwnerMismatchError);
    expect(fixture.storage.locked?.ownerUserId).toBe('actor');
    expect(fixture.calls).toHaveLength(1);
  });

  it('commits an exact next batch and freezes its response receipt', async () => {
    const { executor, storage, calls } = harness();
    storage.head = 9n;

    const responseBytes = await upload(executor, request(1n));
    expect(decodeResponse(responseBytes)).toEqual({
      requiredCheckpoints: [
        {
          scope: `User:${viewerScopeId}`,
          syncId: 9,
        },
      ],
      requiredSyncId: 9,
      requiredScope: `User:${viewerScopeId}`,
      rejections: [],
    });
    expect(storage.headReads).toEqual([`${UserScope}:${viewerScopeId}`]);
    expect(calls.map((call) => call.operation)).toEqual(['create']);
    expect(storage.locked).toMatchObject({
      ownerUserId: 'actor',
      clientId: 'client',
      lastCommittedBatchSequence: 1n,
      responseBytes,
    });
    expect(storage.receiptWrites).toBe(1);
  });

  it('settles an accepted batch against every resolver-selected scope', async () => {
    const fixture = harness();
    fixture.storage.heads.set(`Book:${bookScopeId}`, 41n);
    fixture.storage.heads.set(`User:${viewerScopeId}`, 9n);
    fixture.handlers.createSpace = async () => ({
      scope: `${BookScope}:${bookScopeId}`,
    });
    fixture.handlers.renameSpace = async () => ({
      scope: `${UserScope}:${viewerScopeId}`,
    });

    const response = decodeResponse(
      await upload(
        fixture.executor,
        request(1n, [createSpace(), renameSpace(2n)]),
      ),
    );

    expect(response).toEqual({
      requiredCheckpoints: [
        { scope: `Book:${bookScopeId}`, syncId: 41 },
        { scope: `User:${viewerScopeId}`, syncId: 9 },
      ],
      requiredScope: `User:${viewerScopeId}`,
      requiredSyncId: 9,
      rejections: [],
    });
    expect(fixture.storage.headReads).toEqual([
      `${BookScope}:${bookScopeId}`,
      `${UserScope}:${viewerScopeId}`,
    ]);
  });

  it('deduplicates selected scopes and separately preserves the legacy principal checkpoint', async () => {
    const fixture = harness();
    fixture.storage.heads.set(`Book:${bookScopeId}`, 41n);
    fixture.storage.heads.set(`User:${viewerScopeId}`, 9n);
    fixture.handlers.createSpace = async () => ({
      scope: `${BookScope}:${bookScopeId}`,
    });
    fixture.handlers.renameSpace = async () => ({
      scope: `${BookScope}:${bookScopeId}`,
    });

    const response = decodeResponse(
      await upload(
        fixture.executor,
        request(1n, [createSpace(), renameSpace(2n)]),
      ),
    );

    expect(response).toEqual({
      requiredCheckpoints: [{ scope: `Book:${bookScopeId}`, syncId: 41 }],
      requiredScope: `User:${viewerScopeId}`,
      requiredSyncId: 9,
      rejections: [],
    });
    expect(fixture.storage.headReads).toEqual([
      `${BookScope}:${bookScopeId}`,
      `${UserScope}:${viewerScopeId}`,
    ]);
  });

  it('aborts instead of freezing an invalid resolver-selected scope as a rejection', async () => {
    const fixture = harness();
    fixture.handlers.createSpace = async () => ({
      scope: { model: 'Unknown', id: bookScopeId } as unknown as string,
    });

    await expect(upload(fixture.executor, request(1n))).rejects.toThrow(
      /scope must be a string/,
    );
    expect(fixture.storage.receiptWrites).toBe(0);
  });
});

describe('Uplink replay and frozen receipt bytes', () => {
  it('returns exact stored bytes without dispatch, head read, or receipt write', async () => {
    const { executor, storage, calls, transactions, handlers } = harness();
    const requestBytes = encode(request(1n));
    const first = await executor.execute({
      principal: { userId: 'actor' },
      requestBytes,
    });
    const frozen = Uint8Array.from(first);
    first[0] ^= 0xff;
    calls.length = 0;
    storage.head = 99n;
    handlers.createSpace = async () => {
      throw new Error('changed resolver must not run for replay');
    };

    const replay = await executor.execute({
      principal: { userId: 'actor' },
      requestBytes,
    });

    expect(replay).toEqual(frozen);
    expect(calls).toEqual([]);
    expect(storage.receiptWrites).toBe(1);
    expect(transactions.savepointCount).toBe(1);
  });

  it('replays without reaching anything downstream', async () => {
    const { executor, storage, calls, handlers } = harness();
    const requestBytes = encode(request(1n));
    const first = await executor.execute({
      principal: { userId: 'actor' },
      requestBytes,
    });
    calls.length = 0;
    handlers.createSpace = async () => {
      throw new Error('nothing downstream may run for replay');
    };
    storage.head = 99n;

    await expect(
      executor.execute({ principal: { userId: 'actor' }, requestBytes }),
    ).resolves.toEqual(first);
    expect(calls).toEqual([]);
    expect(storage.receiptWrites).toBe(1);
  });

  it('hashes semantic content rather than protobuf byte ordering', async () => {
    const { executor, storage } = harness();
    await upload(executor, request(1n));
    const reordered = {
      mutations: [
        {
          operations: [
            {
              values: { count: 2, title: 'title' },
              identity: { id: spaceId },
              op: 'create',
              model: 'Space',
            },
          ],
          name: 'CreateSpace',
          ordinal: 1,
        },
      ],
      batchSequence: 1,
      clientId: 'client',
    };

    await expect(upload(executor, reordered)).resolves.toEqual(
      storage.locked!.responseBytes,
    );
    expect(storage.receiptWrites).toBe(1);
  });

  it('rejects same-sequence semantic conflict and serializes duplicates', async () => {
    const conflict = harness();
    await upload(conflict.executor, request(1n));
    const changed = createSpace(1n, { title: 'changed', count: 2 });
    await expect(
      upload(conflict.executor, request(1n, [changed])),
    ).rejects.toMatchObject({
      constructor: LocalSyncSequenceError,
      reason: 'request_conflict',
    });

    const duplicate = harness();
    const requestBytes = encode(request(1n));
    const [left, right] = await Promise.all([
      duplicate.executor.execute({
        principal: { userId: 'actor' },
        requestBytes,
      }),
      duplicate.executor.execute({
        principal: { userId: 'actor' },
        requestBytes,
      }),
    ]);
    expect(right).toEqual(left);
    expect(duplicate.calls).toHaveLength(1);
    expect(duplicate.storage.receiptWrites).toBe(1);
  });
});

describe('Uplink savepoint and rejection policy', () => {
  it('rolls back deterministic rejection, continues, and freezes final head', async () => {
    const fixture = harness();
    fixture.storage.head = 7n;
    fixture.handlers.createSpace = async (context, arguments_) => {
      fixture.calls.push({ operation: 'create', value: arguments_.space });
      const { identity, data } = arguments_.space;
      if (data.title === 'reject') {
        throw new LocalSyncMutationRejected('space.forbidden');
      }
      if (data.title === 'publish') {
        const scopeLedger = createScopeLedger({
          contract: fixture.components.contract,
          storage: fixture.storage,
          registeredModels: new Set(
            Object.keys(fixture.components.contract.models),
          ),
        });
        await scopeLedger.invalidate(context.transaction, {
          model: spaceDescriptor,
          identity,
          scopes: [`${UserScope}:${viewerScopeId}`],
        });
      }
    };
    const rejected = createSpace(1n, { title: 'reject', count: 1 });
    const invalid = createSpace(2n, { title: 'missing count' });
    const published = createSpace(
      3n,
      { title: 'publish', count: 3 },
      { id: otherSpaceId },
    );

    const response = decodeResponse(
      await upload(
        fixture.executor,
        request(1n, [rejected, invalid, published]),
      ),
    );

    expect(response).toEqual({
      requiredCheckpoints: [
        {
          scope: `User:${viewerScopeId}`,
          syncId: 7,
        },
      ],
      requiredSyncId: 7,
      requiredScope: `User:${viewerScopeId}`,
      rejections: [
        { ordinal: 1, code: 'space.forbidden' },
        { ordinal: 2, code: 'mutation.invalid' },
      ],
    });
    // Two savepoints, not three: the `mutation.invalid` entry fails during
    // decode, before any savepoint opens, because nothing of it executes.
    expect(fixture.transactions.savepointCount).toBe(2);
    expect(fixture.calls).toEqual([
      {
        operation: 'create',
        value: {
          identity: { id: otherSpaceId },
          data: { title: 'publish', nickname: null, count: 3 },
        },
      },
    ]);
    expect(fixture.storage.ledgerHeads.get(`User:${viewerScopeId}`)).toBe(1n);
    expect(fixture.storage.invalidations).toHaveLength(1);
    expect(
      fixture.storage.ledgerTransactions.every(
        (transaction) => transaction === fixture.transactions.tx,
      ),
    ).toBe(true);
  });

  it('aborts the batch on an unknown resolver failure', async () => {
    const fixture = harness();
    fixture.handlers.createSpace = async () => {
      fixture.calls.push({ operation: 'create', value: 'temporary' });
      throw new Error('unexpected');
    };

    await expect(upload(fixture.executor, request(1n))).rejects.toThrow(
      'unexpected',
    );
    expect(fixture.calls).toEqual([]);
    expect(fixture.storage.receiptWrites).toBe(0);
    expect(fixture.storage.locked?.lastCommittedBatchSequence).toBe(0n);
  });

  it('aborts the batch when a resolver throws a protocol error', async () => {
    // `mutation.invalid` means the envelope body never reached a resolver. A
    // protocol or identity error thrown BY a resolver is a server-side defect;
    // freezing it into a receipt would make the client delete a valid write.
    const fixture = harness();
    fixture.handlers.createSpace = async () => {
      throw new LocalSyncProtocolError('descriptor drift inside the resolver');
    };

    await expect(upload(fixture.executor, request(1n))).rejects.toThrow(
      'descriptor drift',
    );
    expect(fixture.storage.receiptWrites).toBe(0);
    expect(fixture.storage.locked?.lastCommittedBatchSequence).toBe(0n);
  });

  it('aborts the batch when a resolver throws an identity error', async () => {
    const fixture = harness();
    fixture.handlers.createSpace = async () => {
      throw new LocalSyncIdentityError('stale descriptor in Scope Ledger');
    };

    await expect(upload(fixture.executor, request(1n))).rejects.toThrow(
      'stale descriptor',
    );
    expect(fixture.storage.receiptWrites).toBe(0);
    expect(fixture.storage.locked?.lastCommittedBatchSequence).toBe(0n);
  });
});

describe('Uplink generated typed dispatch', () => {
  it('rejects a known field outside the update projection before the resolver', async () => {
    const fixture = harness();
    const mutation = act(1n, 'RenameSpace', [
      {
        model: 'Space',
        op: 'update',
        identity: { id: spaceId },
        values: { count: 3 },
      },
    ]);

    const response = decodeResponse(
      await upload(fixture.executor, request(1n, [mutation])),
    );

    expect(response).toMatchObject({
      rejections: [{ ordinal: 1, code: 'rename_space.not_allowed' }],
    });
    expect(fixture.calls).toEqual([]);
    expect(fixture.transactions.savepointCount).toBe(0);
  });

  it('ignores unknown additive fields while forwarding allowed patch fields', async () => {
    const fixture = harness();
    const mutation = act(1n, 'RenameSpace', [
      {
        model: 'Space',
        op: 'update',
        identity: { id: spaceId },
        values: { title: 'renamed', futureField: 'newer client' },
      },
    ]);

    const response = decodeResponse(
      await upload(fixture.executor, request(1n, [mutation])),
    );

    expect(response).toMatchObject({ rejections: [] });
    expect(fixture.calls).toEqual([
      {
        operation: 'update',
        value: {
          identity: { id: spaceId },
          patch: { title: 'renamed' },
        },
      },
    ]);
  });

  it('rejects an update that is empty after unknown fields are ignored', async () => {
    const fixture = harness();
    const mutation = act(1n, 'RenameSpace', [
      {
        model: 'Space',
        op: 'update',
        identity: { id: spaceId },
        values: { futureField: 'newer client' },
      },
    ]);

    const response = decodeResponse(
      await upload(fixture.executor, request(1n, [mutation])),
    );

    expect(response).toMatchObject({
      rejections: [{ ordinal: 1, code: 'mutation.invalid' }],
    });
    expect(fixture.calls).toEqual([]);
    expect(fixture.transactions.savepointCount).toBe(0);
  });

  it('forwards every operation, composite IDs, and patch tri-state exactly', async () => {
    const fixture = harness();
    const userId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const momentId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    const mutations = [
      createSpace(1n),
      act(2n, 'RenameSpace', [
        {
          model: 'Space',
          op: 'update',
          identity: { id: spaceId },
          // A named key is the write; held at null it is the clear.
          values: { title: 'renamed', nickname: null },
        },
      ]),
      act(3n, 'DeleteSpace', [
        {
          model: 'Space',
          op: 'delete',
          identity: { id: spaceId },
        },
      ]),
      act(4n, 'StarMoment', [
        {
          model: 'Star',
          op: 'create',
          identity: { momentId, userId },
          values: { label: 'favorite' },
        },
      ]),
      act(5n, 'AnnotateStar', [
        {
          model: 'Star',
          op: 'update',
          identity: { userId, momentId },
          values: { note: 'hello' },
        },
      ]),
      act(6n, 'UnstarMoment', [
        {
          model: 'Star',
          op: 'delete',
          identity: { userId, momentId },
        },
      ]),
      // An operation no slot of this act declares: UnstarMoment spells one
      // Star delete and nothing else. (It used to be a schema version the
      // server did not carry — CAP-481 deleted that number, so the act is
      // made invalid by what it says instead.)
      act(7n, 'UnstarMoment', [
        {
          model: 'Space',
          op: 'delete',
          identity: { id: spaceId },
        },
      ]),
    ];

    const response = decodeResponse(
      await upload(fixture.executor, request(1n, mutations)),
    );

    expect(response).toEqual({
      requiredCheckpoints: [
        {
          scope: `User:${viewerScopeId}`,
          syncId: 0,
        },
      ],
      requiredSyncId: 0,
      requiredScope: `User:${viewerScopeId}`,
      rejections: [{ ordinal: 7, code: 'mutation.invalid' }],
    });
    expect(fixture.calls).toEqual([
      {
        operation: 'create',
        value: {
          identity: { id: spaceId },
          data: { count: 2, nickname: null, title: 'title' },
        },
      },
      {
        operation: 'update',
        value: {
          identity: { id: spaceId },
          patch: { nickname: null, title: 'renamed' },
        },
      },
      { operation: 'delete', value: { identity: { id: spaceId } } },
      {
        operation: 'star.create',
        value: {
          identity: { userId, momentId },
          data: { label: 'favorite', note: null },
        },
      },
      {
        operation: 'star.update',
        value: {
          identity: { userId, momentId },
          patch: { note: 'hello' },
        },
      },
      {
        operation: 'star.delete',
        value: { identity: { userId, momentId } },
      },
    ]);
    expect(fixture.transactions.savepointCount).toBe(6);
  });
});
