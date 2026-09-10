import {
  BackendModelBinding,
  CompactedInvalidation,
  GeneratedBackendContract,
  GeneratedMutationContract,
  LocalSyncMutationRejected,
  LocalSyncProtocolError,
  LockedUplink,
  LocalSyncStorage,
  LocalSyncTransactions,
  StoredUplinkReceipt,
  UplinkExecutor,
  createUplinkExecutor,
  validateBackendOptions,
} from '../src';

/**
 * Named mutations at the server (CAP-439): one resolver call per act, inside
 * one savepoint, with slot fields arriving fully typed — no discriminated
 * unions, no `op` switches, no `children` containers.
 */

interface Tx {
  readonly id: number;
}

const spaceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const momentId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const photoId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const otherPhotoId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const scopeConfiguration = {
  scopeAuthorizer: { canRead: async () => true },
  principalScope: () => `User:${spaceId}`,
};

const momentDescriptor = {
  name: 'Moment',
  identityFields: ['id'],
  fields: [
    {
      name: 'id',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'spaceId',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'caption',
      nullable: true,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
  ],
  forward: { read: async () => [] },
} as const;

const photoDescriptor = {
  name: 'MomentPhoto',
  identityFields: ['id'],
  fields: [
    {
      name: 'id',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'momentId',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'position',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'int' },
    },
  ],
  forward: { read: async () => [] },
} as const;

function generatedContract(): GeneratedBackendContract {
  return {
    enumValues: {},
    models: { moment: momentDescriptor, momentPhoto: photoDescriptor },
  };
}

/// What generation states about the declared acts, and nothing more.
function mutationContract(): GeneratedMutationContract {
  return {
    mutations: {
      captureMoment: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'CaptureMoment',
          slots: [
            {
              name: 'moment',
              model: 'Moment',
              operation: 'create',
              cardinality: 'single',
            },
            {
              name: 'photos',
              model: 'MomentPhoto',
              operation: 'create',
              cardinality: 'list',
              // The act-level wiring (spec 2026-08-16-slot-bindings): every
              // photo's momentId must name the act's own moment.
              bindings: [
                { relation: 'moment', fields: ['momentId'], slot: 'moment' },
              ],
            },
          ],
          forward: async (
            resolver: (context: unknown, arguments_: unknown) => Promise<void>,
            context: unknown,
            arguments_: unknown,
          ) => resolver(context, arguments_),
        },
      },
      reviseMoment: {
        v1: {
          version: 1,
          input: generatedContract(),
          name: 'ReviseMoment',
          slots: [
            {
              name: 'moment',
              model: 'Moment',
              operation: 'update',
              cardinality: 'single',
              allowedPatchFields: ['caption'],
            },
            {
              name: 'cover',
              model: 'MomentPhoto',
              operation: 'delete',
              cardinality: 'optional',
            },
          ],
          forward: async (
            resolver: (context: unknown, arguments_: unknown) => Promise<void>,
            context: unknown,
            arguments_: unknown,
          ) => resolver(context, arguments_),
        },
      },
    },
  } as unknown as GeneratedMutationContract;
}

class Storage implements LocalSyncStorage<Tx> {
  locked: LockedUplink = {
    ownerUserId: 'actor',
    clientId: 'client',
    lastCommittedBatchSequence: 0n,
    requestHash: null,
    responseBytes: null,
  };

  async claimAndLockUplink(): Promise<LockedUplink> {
    return this.locked;
  }

  async saveUplinkReceipt(
    _transaction: Tx,
    receipt: StoredUplinkReceipt,
  ): Promise<void> {
    this.locked = {
      ownerUserId: receipt.ownerUserId,
      clientId: receipt.clientId,
      lastCommittedBatchSequence: receipt.batchSequence,
      requestHash: receipt.requestHash,
      responseBytes: receipt.responseBytes,
    };
  }

  async lockOrCreateDownlinkHead(): Promise<bigint> {
    return 0n;
  }

  async writeDownlinkHead(): Promise<void> {}

  async upsertInvalidation(): Promise<void> {}

  async readDownlinkHead(): Promise<bigint> {
    return 7n;
  }

  async scanInvalidations(): Promise<readonly CompactedInvalidation[]> {
    return [];
  }

  async findInvalidationScopes() {
    return [];
  }
}

class Transactions implements LocalSyncTransactions<Tx> {
  savepointCount = 0;

  constructor(private readonly effects: string[]) {}

  async write<T>(work: (transaction: Tx) => Promise<T>): Promise<T> {
    return work({ id: 1 });
  }

  readSnapshot(): never {
    throw new Error('not used');
  }

  /// A savepoint that really rolls back: the effects recorded inside a failed
  /// one are discarded, so "the mutation rolls back whole" is observable.
  async savepoint<T>(_transaction: Tx, work: () => Promise<T>): Promise<T> {
    this.savepointCount += 1;
    const checkpoint = this.effects.length;
    try {
      return await work();
    } catch (error) {
      this.effects.splice(checkpoint);
      throw error;
    }
  }
}

/** A refusal a product service throws bare, knowing no wire code. */
class BookIsClosed extends Error {}

function harness(
  resolvers?: Partial<{
    captureMoment: (context: unknown, arguments_: never) => Promise<unknown>;
    reviseMoment: (context: unknown, arguments_: never) => Promise<unknown>;
  }>,
): {
  readonly executor: UplinkExecutor;
  readonly effects: string[];
  readonly seen: unknown[];
  readonly transactions: Transactions;
} {
  const effects: string[] = [];
  const seen: unknown[] = [];
  const transactions = new Transactions(effects);
  const binding: BackendModelBinding<Tx, object, object> = {
    read: { forViewer: async () => [] },
  };
  const components = validateBackendOptions<Tx>({
    contract: generatedContract(),
    models: { moment: binding, momentPhoto: binding },
    ...scopeConfiguration,
    mutationContract: mutationContract(),
    mutations: {
      captureMoment: {
        v1:
          resolvers?.captureMoment ??
          (async (_context: unknown, arguments_: never) => {
            seen.push(arguments_);
            effects.push('captureMoment');
          }),
      },
      reviseMoment: {
        v1:
          resolvers?.reviseMoment ??
          (async (_context: unknown, arguments_: never) => {
            seen.push(arguments_);
            effects.push('reviseMoment');
          }),
      },
    },
    translateRejection: (error) =>
      error instanceof BookIsClosed ? 'capture_moment.not_allowed' : null,
    persistence: {
      transactions,
      storage: new Storage(),
      committedChanges: {
        subscribe: () => undefined,
        close: async () => undefined,
      },
    },
  });
  return {
    executor: createUplinkExecutor(components),
    effects,
    seen,
    transactions,
  };
}

function capture(ordinal = 1, photos = 1) {
  return {
    ordinal,
    name: 'CaptureMoment',
    operations: [
      {
        model: 'Moment',
        op: 'create',
        identity: { id: momentId },
        values: { spaceId, caption: 'a page' },
      },
      ...Array.from({ length: photos }, (_, index) => ({
        model: 'MomentPhoto',
        op: 'create',
        identity: { id: index === 0 ? photoId : otherPhotoId },
        values: { momentId, position: index },
      })),
    ],
  };
}

function encode(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

async function upload(
  executor: UplinkExecutor,
  mutations: readonly unknown[],
  batchSequence = 1,
) {
  return executor.execute({
    principal: { userId: 'actor' },
    requestBytes: encode({ clientId: 'client', batchSequence, mutations }),
  });
}

function decodeResponse(bytes: Uint8Array): {
  requiredSyncId: number;
  rejections: { ordinal: number; code: string }[];
} {
  return JSON.parse(Buffer.from(bytes).toString('utf8'));
}

describe('named mutation execution', () => {
  it('calls one resolver per act, with slot fields fully typed', async () => {
    const { executor, effects, seen, transactions } = harness();

    await upload(executor, [capture(1, 2)]);

    expect(effects).toEqual(['captureMoment']);
    // One savepoint for the act, not one per operation.
    expect(transactions.savepointCount).toBe(1);
    expect(seen).toHaveLength(1);
    expect(seen[0]).toEqual({
      moment: {
        identity: { id: momentId },
        data: { spaceId, caption: 'a page' },
      },
      photos: [
        { identity: { id: photoId }, data: { momentId, position: 0 } },
        { identity: { id: otherPhotoId }, data: { momentId, position: 1 } },
      ],
    });
  });

  it('gives a list slot every operation it was handed, and an empty one none', async () => {
    const { executor, seen } = harness();

    await upload(executor, [capture(1, 0)]);

    expect((seen[0] as { photos: unknown[] }).photos).toEqual([]);
  });

  it('decodes an absent optional slot as null', async () => {
    const { executor, seen } = harness();

    await upload(executor, [
      {
        ordinal: 1,
        name: 'ReviseMoment',
        operations: [
          {
            model: 'Moment',
            op: 'update',
            identity: { id: momentId },
            values: { caption: 'revised' },
          },
        ],
      },
    ]);

    expect(seen[0]).toEqual({
      moment: { identity: { id: momentId }, patch: { caption: 'revised' } },
      cover: null,
    });
  });

  it('rejects an unknown name and a slot violation', async () => {
    const bodies = [
      { ...capture(), name: 'NoSuchAct' },
      // An operation no slot declared.
      {
        ...capture(),
        operations: [
          ...capture().operations,
          {
            model: 'Moment',
            op: 'delete',
            identity: { id: momentId },
          },
        ],
      },
      // The required single slot is missing.
      {
        ordinal: 1,
        name: 'CaptureMoment',
        operations: [
          {
            model: 'MomentPhoto',
            op: 'create',
            identity: { id: photoId },
            values: { momentId, position: 0 },
          },
        ],
      },
    ];

    for (const body of bodies) {
      const { executor, effects } = harness();
      const response = decodeResponse(await upload(executor, [body]));
      expect(response.rejections).toEqual([
        { ordinal: 1, code: 'mutation.invalid' },
      ]);
      expect(effects).toEqual([]);
    }
  });

  // Slot bindings (spec 2026-08-16-slot-bindings): the wire is a claim, so
  // the act's declared wiring is held against its bound create rows before
  // the resolver runs. The client's own verifier disciplines only the client.
  it('rejects a bound create naming a different parent, as the act', async () => {
    const tampered = {
      ...capture(1, 1),
      operations: [
        capture(1, 1).operations[0],
        {
          model: 'MomentPhoto',
          op: 'create',
          identity: { id: photoId },
          // A momentId that is not the act's own moment.
          values: { momentId: spaceId, position: 0 },
        },
      ],
    };

    const { executor, effects, seen, transactions } = harness();
    const response = decodeResponse(await upload(executor, [tampered]));

    // The act's own machine name, so the client can say what was refused —
    // not the anonymous `mutation.invalid` of a shapeless envelope.
    expect(response.rejections).toEqual([
      { ordinal: 1, code: 'capture_moment.invalid' },
    ]);
    // Refused whole before anything executed: no resolver, no savepoint.
    expect(effects).toEqual([]);
    expect(seen).toEqual([]);
    expect(transactions.savepointCount).toBe(0);
  });

  it('rolls one refused act back whole while its neighbour proceeds', async () => {
    const attempted: string[] = [];
    const { executor, effects, transactions } = harness({
      captureMoment: async () => {
        // Recorded inside the savepoint, so the rollback is what removes it.
        attempted.push('captureMoment');
        effects.push('captureMoment');
        throw new LocalSyncMutationRejected('capture_moment.not_allowed');
      },
    });

    const response = decodeResponse(
      await upload(executor, [
        capture(1),
        {
          ordinal: 2,
          name: 'ReviseMoment',
          operations: [
            {
              model: 'Moment',
              op: 'update',
              identity: { id: momentId },
              values: { caption: 'revised' },
            },
          ],
        },
      ]),
    );

    expect(response.rejections).toEqual([
      { ordinal: 1, code: 'capture_moment.not_allowed' },
    ]);
    // It ran, and then left nothing behind; the other act stands.
    expect(attempted).toEqual(['captureMoment']);
    expect(effects).toEqual(['reviseMoment']);
    expect(transactions.savepointCount).toBe(2);
    expect(response.requiredSyncId).toBe(7);
  });

  it('translates a bare product refusal through the registered seam', async () => {
    const { executor } = harness({
      captureMoment: async () => {
        throw new BookIsClosed('the book is closed');
      },
    });

    const response = decodeResponse(await upload(executor, [capture(1)]));

    // The resolver threw its own refusal, knowing no wire code (CAP-441).
    expect(response.rejections).toEqual([
      { ordinal: 1, code: 'capture_moment.not_allowed' },
    ]);
  });

  it('aborts the request on a defect the translator does not claim', async () => {
    const { executor } = harness({
      captureMoment: async () => {
        throw new TypeError('a genuine defect');
      },
    });

    await expect(upload(executor, [capture(1)])).rejects.toBeInstanceOf(
      TypeError,
    );
  });

  // An element without a name is not an older spelling of a write — it is a
  // shape this protocol has no resolver for, and never will (CAP-444).
  it('refuses an element that names no act, and lands its neighbour', async () => {
    const { executor, effects, transactions } = harness();

    const response = decodeResponse(
      await upload(executor, [
        {
          ordinal: 1,
          model: 'Moment',
          op: 'delete',
          identity: { id: momentId },
        },
        capture(2),
      ]),
    );

    expect(response.rejections).toEqual([
      { ordinal: 1, code: 'mutation.invalid' },
    ]);
    expect(effects).toEqual(['captureMoment']);
    // The unnamed element never opened a savepoint: nothing of it executes.
    expect(transactions.savepointCount).toBe(1);
  });

  it('takes a batch of 20 acts, each one savepoint', async () => {
    const { executor, transactions } = harness();

    await upload(
      executor,
      Array.from({ length: 20 }, (_, index) => capture(index + 1)),
    );

    expect(transactions.savepointCount).toBe(20);
  });

  it('refuses resolvers that do not answer the generated contract', () => {
    expect(() =>
      validateBackendOptions<Tx>({
        contract: generatedContract(),
        models: {
          moment: { read: { forViewer: async () => [] } },
          momentPhoto: { read: { forViewer: async () => [] } },
        },
        ...scopeConfiguration,
        mutationContract: mutationContract(),
        mutations: { captureMoment: { v1: async () => undefined } },
        persistence: {
          transactions: new Transactions([]),
          storage: new Storage(),
          committedChanges: {
            subscribe: () => undefined,
            close: async () => undefined,
          },
        },
      }),
    ).toThrow(/mutation resolvers must exactly match/);
  });
});
