import {
  createUplinkExecutor,
  GeneratedBackendContract,
  LocalSyncPersistence,
  LockedUplink,
  validateBackendOptions,
} from '../src';

const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const oldModel = {
  name: 'Page',
  identityFields: ['id'],
  fields: [
    {
      name: 'id',
      identity: true,
      nullable: false,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'text',
      identity: false,
      nullable: false,
      type: { kind: 'scalar', name: 'string' },
    },
  ],
} as const;
const newModel = {
  ...oldModel,
  fields: [
    ...oldModel.fields,
    {
      name: 'title',
      identity: false,
      nullable: false,
      type: { kind: 'scalar', name: 'string' },
    },
  ],
} as const;

function fixture() {
  const seen: Array<{ version: number; input: unknown }> = [];
  let receipt: LockedUplink = {
    ownerUserId: 'user',
    clientId: 'client',
    lastCommittedBatchSequence: 0n,
    requestHash: null,
    responseBytes: null,
  };
  const persistence: LocalSyncPersistence<object> = {
    transactions: {
      write: async (work) => work({}),
      readSnapshot: async (work) => work({}),
      savepoint: async (_tx, work) => work(),
    },
    storage: {
      claimAndLockUplink: async () => receipt,
      saveUplinkReceipt: async (_tx, value) => {
        receipt = { ...value, lastCommittedBatchSequence: value.batchSequence };
      },
      lockOrCreateDownlinkHead: async () => 0n,
      writeDownlinkHead: async () => undefined,
      upsertInvalidation: async () => undefined,
      readDownlinkHead: async () => 4n,
      scanInvalidations: async () => [],
      findInvalidationScopes: async () => [],
    },
    committedChanges: {
      subscribe: () => undefined,
      close: async () => undefined,
    },
  };
  const descriptor = (version: number) => ({
    name: 'CreatePage',
    version,
    slots: [
      {
        name: 'page',
        model: 'Page',
        operation: 'create',
        cardinality: 'single',
      },
    ],
    input: {
      enumValues: {},
      models: { page: version === 1 ? oldModel : newModel },
    },
    forward: async (
      resolver: (context: unknown, input: unknown) => Promise<void>,
      context: unknown,
      input: unknown,
    ) => resolver(context, input),
  });
  const versions: Record<string, unknown> = {
    v1: descriptor(1),
    v2: descriptor(2),
  };
  const handlers: Record<string, unknown> = {
    v1: async (_context: unknown, input: unknown) => {
      seen.push({ version: 1, input });
    },
    v2: async (_context: unknown, input: unknown) => {
      seen.push({ version: 2, input });
    },
  };
  const build = () =>
    createUplinkExecutor(
      validateBackendOptions({
        contract: {
          enumValues: {},
          models: { page: { ...newModel, forward: { read: async () => [] } } },
        } as GeneratedBackendContract,
        models: {},
        persistence,
        scopeAuthorizer: { canRead: async () => true },
        principalScope: () => 'User:user',
        mutationContract: { mutations: { createPage: versions } } as never,
        mutations: { createPage: handlers },
      }),
    );
  return { build, seen, versions, handlers, receipt: () => receipt };
}

function act(
  ordinal: number,
  version?: unknown,
  values = { text: 'old page' },
) {
  return {
    ordinal,
    name: 'CreatePage',
    ...(version === undefined ? {} : { version }),
    operations: [{ model: 'Page', op: 'create', identity: { id }, values }],
  };
}

const request = (mutations: unknown[]) => ({
  principal: { userId: 'user' },
  requestBytes: Buffer.from(
    JSON.stringify({ clientId: 'client', batchSequence: 1, mutations }),
  ),
});

describe('mutation versions', () => {
  it('rejects known fields outside a retained update projection while ignoring future keys', async () => {
    const f = fixture();
    f.versions.v1 = {
      ...(f.versions.v1 as object),
      slots: [
        {
          name: 'page',
          model: 'Page',
          operation: 'update',
          cardinality: 'single',
          allowedPatchFields: ['text'],
        },
      ],
      input: {
        enumValues: {},
        models: { page: { ...oldModel, knownFields: ['id', 'text', 'title'] } },
      },
    };
    const update = (ordinal: number, values: object) => ({
      ordinal,
      name: 'CreatePage',
      version: 1,
      operations: [{ model: 'Page', op: 'update', identity: { id }, values }],
    });
    const answer = JSON.parse(
      Buffer.from(
        await f
          .build()
          .execute(
            request([
              update(1, { text: 'bad', title: 'forbidden' }),
              update(2, { text: 'good', futureKey: 'ignored' }),
            ]),
          ),
      ).toString(),
    );
    expect(answer.rejections).toEqual([
      { ordinal: 1, code: 'create_page.not_allowed' },
    ]);
    expect(f.seen).toEqual([
      {
        version: 1,
        input: { page: { identity: { id }, patch: { text: 'good' } } },
      },
    ]);
  });

  it('routes absent and explicit v1 through its historical input, alongside v2', async () => {
    const f = fixture();
    const response = await f
      .build()
      .execute(
        request([
          act(1),
          act(2, 1),
          act(3, 2, { text: 'new page', title: 'title' } as never),
        ]),
      );
    expect(JSON.parse(Buffer.from(response).toString()).rejections).toEqual([]);
    expect(f.seen.map((x) => x.version)).toEqual([1, 1, 2]);
    expect(f.seen[0].input).toEqual({
      page: { identity: { id }, data: { text: 'old page' } },
    });
  });

  it('validates using the selected version before calling its handler', async () => {
    const f = fixture();
    const response = await f.build().execute(request([act(1, 2), act(2, 1)]));
    expect(JSON.parse(Buffer.from(response).toString()).rejections).toEqual([
      { ordinal: 1, code: 'mutation.invalid' },
    ]);
    expect(f.seen.map((x) => x.version)).toEqual([1]);
  });

  it.each([null, 0, -1, 1.5, '1', 9007199254740992])(
    'settles invalid version %p positionally',
    async (version) => {
      const f = fixture();
      const response = await f
        .build()
        .execute(request([act(1, version), act(2)]));
      expect(JSON.parse(Buffer.from(response).toString()).rejections).toEqual([
        { ordinal: 1, code: 'mutation.invalid' },
      ]);
      expect(f.seen.map((x) => x.version)).toEqual([1]);
    },
  );

  it('preflights an unsupported version without effects or a receipt', async () => {
    const f = fixture();
    await expect(
      f.build().execute(request([act(1), act(2, 3)])),
    ).rejects.toMatchObject({
      code: 'mutation_version_unsupported',
      ordinal: 2n,
      mutationName: 'CreatePage',
      version: 3,
    });
    expect(f.seen).toEqual([]);
    expect(f.receipt().lastCommittedBatchSequence).toBe(0n);
  });

  it('replays a committed receipt before checking current version availability', async () => {
    const f = fixture();
    const upload = request([act(1, 1)]);
    const first = await f.build().execute(upload);
    delete f.versions.v1;
    delete f.handlers.v1;
    const replay = await f.build().execute(upload);
    expect(replay).toEqual(first);
    expect(f.seen).toHaveLength(1);
  });

  it('does not normalize absent version into the receipt hash', async () => {
    const f = fixture();
    const executor = f.build();
    await executor.execute(request([act(1)]));
    await expect(executor.execute(request([act(1, 1)]))).rejects.toMatchObject({
      reason: 'request_conflict',
    });
  });

  it('refuses missing and extra version handlers at boot', () => {
    const f = fixture();
    delete f.handlers.v2;
    expect(f.build).toThrow(/version|match/);
    f.handlers.v2 = async () => undefined;
    f.handlers.v3 = async () => undefined;
    expect(f.build).toThrow(/version|match/);
  });
});
