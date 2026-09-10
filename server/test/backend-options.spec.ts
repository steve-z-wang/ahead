import {
  BackendModelBinding,
  GeneratedBackendContract,
  LocalSyncBackendOptionsError,
  LocalSyncPersistence,
  validateBackendOptions,
} from '../src';

interface Tx {
  readonly value: string;
}

const forward = Object.freeze({ read: async () => [] });
const scopeConfiguration = Object.freeze({
  scopeAuthorizer: Object.freeze({ canRead: async () => true }),
  principalScope: ({ userId }: { readonly userId: string }) => `User:${userId}`,
});

function descriptor(name = 'Space') {
  return {
    name,
    identityFields: ['id'],
    fields: [
      {
        name: 'id',
        nullable: false,
        identity: true,
        type: { kind: 'scalar', name: 'uuid' },
      },
      {
        name: 'name',
        nullable: false,
        identity: false,
        type: { kind: 'scalar', name: 'string' },
      },
    ],
    forward,
  } as const;
}

function contract(
  models: Record<string, ReturnType<typeof descriptor>> = {
    space: descriptor(),
  },
): GeneratedBackendContract {
  return {
    enumValues: {},
    models,
  };
}

const binding: BackendModelBinding<
  Tx,
  { readonly id: string },
  { readonly id: string }
> = {
  read: { forViewer: async (_context, identities) => identities },
};

function persistence(): LocalSyncPersistence<Tx> {
  return {
    transactions: {
      write: async (work) => work({ value: 'write' }),
      readSnapshot: async (work) => work({ value: 'read' }),
      savepoint: async (_transaction, work) => work(),
    },
    storage: {
      claimAndLockUplink: async (_transaction, input) => ({
        ...input,
        lastCommittedBatchSequence: 0n,
        requestHash: null,
        responseBytes: null,
      }),
      saveUplinkReceipt: async () => undefined,
      lockOrCreateDownlinkHead: async () => 0n,
      writeDownlinkHead: async () => undefined,
      upsertInvalidation: async () => undefined,
      readDownlinkHead: async () => 0n,
      scanInvalidations: async () => [],
      findInvalidationScopes: async () => [],
    },
    committedChanges: {
      subscribe: () => undefined,
      close: async () => undefined,
    },
  };
}

describe('validateBackendOptions', () => {
  it('captures one immutable persistence aggregate and fixed page size', () => {
    const models = { space: binding };
    const input = {
      contract: contract(),
      models,
      persistence: persistence(),
      ...scopeConfiguration,
    };
    const components = validateBackendOptions(input);

    expect(components.downlinkPageSize).toBe(50);
    expect(components.models).not.toBe(models);
    expect(components.models.space).toBe(binding);
    expect(components.persistence.transactions).toBe(
      input.persistence.transactions,
    );
    expect(components.persistence.storage).toBe(input.persistence.storage);
    expect(components.persistence.committedChanges).toBe(
      input.persistence.committedChanges,
    );
    expect(Object.isFrozen(components)).toBe(true);
    expect(Object.isFrozen(components.models)).toBe(true);
    expect(Object.isFrozen(components.persistence)).toBe(true);
  });

  // The registered loaders ARE the Downlink surface (CAP-488): the contract
  // names every generated Model, and the Backend registers the ones it
  // actually persists and publishes. Partial, but exact.
  it('accepts a subset of the generated contract', () => {
    const components = validateBackendOptions<Tx>({
      contract: contract(),
      models: {},
      persistence: persistence(),
      ...scopeConfiguration,
    });

    expect(Object.keys(components.models)).toEqual([]);
    expect(Object.keys(components.contract.models)).toContain('space');
  });

  it('rejects a binding the generated contract does not name', () => {
    expect(() =>
      validateBackendOptions({
        contract: contract(),
        models: { space: binding, user: binding },
        persistence: persistence(),
        ...scopeConfiguration,
      }),
    ).toThrow(LocalSyncBackendOptionsError);
  });

  // Binding referents are settled at capture, never at decode: a defect
  // discovered while an uplink batch decodes has no rejection code and
  // poisons the whole batch on every retry, so the boot is where a bad
  // contract must die.
  describe('slot binding referents', () => {
    function withMutation(
      slots: readonly Record<string, unknown>[],
    ): Parameters<typeof validateBackendOptions<Tx>>[0] {
      return {
        contract: contract(),
        models: { space: binding },
        persistence: persistence(),
        ...scopeConfiguration,
        mutationContract: {
          mutations: {
            captureThing: {
              v1: {
                input: contract(),
                name: 'CaptureThing',
                version: 1,
                slots,
                forward: async () => undefined,
              },
            },
          },
        } as never,
        mutations: { captureThing: { v1: async () => undefined } },
      };
    }

    const parent = {
      name: 'moment',
      model: 'Space',
      operation: 'create',
      cardinality: 'single',
    };

    it('captures a binding whose referents all hold', () => {
      const components = validateBackendOptions(
        withMutation([
          parent,
          {
            name: 'stars',
            model: 'Space',
            operation: 'create',
            cardinality: 'list',
            bindings: [{ relation: 'moment', fields: ['id'], slot: 'moment' }],
          },
        ]),
      );
      expect(
        components.mutationContract.mutations.captureThing.v1.slots[1].bindings,
      ).toEqual([{ relation: 'moment', fields: ['id'], slot: 'moment' }]);
    });

    it('rejects a binding naming an unknown slot', () => {
      expect(() =>
        validateBackendOptions(
          withMutation([
            parent,
            {
              name: 'stars',
              model: 'Space',
              operation: 'create',
              cardinality: 'list',
              bindings: [{ relation: 'moment', fields: ['id'], slot: 'page' }],
            },
          ]),
        ),
      ).toThrow(/unknown slot "page"/);
    });

    it('rejects a binding to a slot that is not single-cardinality', () => {
      expect(() =>
        validateBackendOptions(
          withMutation([
            { ...parent, cardinality: 'optional' },
            {
              name: 'stars',
              model: 'Space',
              operation: 'create',
              cardinality: 'list',
              bindings: [
                { relation: 'moment', fields: ['id'], slot: 'moment' },
              ],
            },
          ]),
        ),
      ).toThrow(/not single-cardinality/);
    });

    it('rejects a binding whose fields disagree with the identity arity', () => {
      expect(() =>
        validateBackendOptions(
          withMutation([
            parent,
            {
              name: 'stars',
              model: 'Space',
              operation: 'create',
              cardinality: 'list',
              bindings: [
                { relation: 'moment', fields: ['a', 'b'], slot: 'moment' },
              ],
            },
          ]),
        ),
      ).toThrow(/names 2 fields against "Space"'s identity of 1/);
    });
  });

  describe('update patch projections', () => {
    function withUpdate(
      slot: Record<string, unknown>,
    ): Parameters<typeof validateBackendOptions<Tx>>[0] {
      return {
        contract: contract(),
        models: { space: binding },
        persistence: persistence(),
        ...scopeConfiguration,
        mutationContract: {
          mutations: {
            renameSpace: {
              v1: {
                version: 1,
                input: contract(),
                name: 'RenameSpace',
                slots: [slot],
                forward: async () => undefined,
              },
            },
          },
        } as never,
        mutations: { renameSpace: { v1: async () => undefined } },
      };
    }

    const update = {
      name: 'space',
      model: 'Space',
      operation: 'update',
      cardinality: 'single',
    };

    it('captures and freezes a valid projection', () => {
      const components = validateBackendOptions(
        withUpdate({ ...update, allowedPatchFields: ['name'] }),
      );
      const projection =
        components.mutationContract.mutations.renameSpace.v1.slots[0]
          .allowedPatchFields;
      expect(projection).toEqual(['name']);
      expect(Object.isFrozen(projection)).toBe(true);
    });

    it.each([
      [update, /must declare allowedPatchFields/],
      [{ ...update, allowedPatchFields: [] }, /must be a nonempty array/],
      [
        { ...update, allowedPatchFields: ['name', 'name'] },
        /contains duplicate field "name"/,
      ],
      [
        { ...update, allowedPatchFields: ['id'] },
        /cannot include identity field "id"/,
      ],
      [
        { ...update, allowedPatchFields: ['missing'] },
        /names unknown field "missing"/,
      ],
      [
        { ...update, operation: 'create', allowedPatchFields: ['name'] },
        /only update slots may declare allowedPatchFields/,
      ],
    ])('rejects malformed projection %#', (slot, message) => {
      expect(() => validateBackendOptions(withUpdate(slot))).toThrow(message);
    });
  });

  it('rejects empty and duplicate generated descriptors', () => {
    expect(() =>
      validateBackendOptions({
        contract: contract({}),
        models: {},
        persistence: persistence(),
        ...scopeConfiguration,
      }),
    ).toThrow(LocalSyncBackendOptionsError);
    const duplicated = contract({
      first: descriptor('Space'),
      second: descriptor('Space'),
    });
    expect(() =>
      validateBackendOptions({
        contract: duplicated,
        models: { first: binding, second: { ...binding } },
        persistence: persistence(),
        ...scopeConfiguration,
      }),
    ).toThrow(LocalSyncBackendOptionsError);
  });

  it.each([
    {},
    { transactions: {}, storage: {}, committedChanges: {} },
    {
      transactions: persistence().transactions,
      storage: {},
      committedChanges: persistence().committedChanges,
    },
    {
      transactions: persistence().transactions,
      storage: persistence().storage,
      committedChanges: { subscribe: () => undefined },
    },
  ])('rejects malformed persistence %#', (malformed) => {
    expect(() =>
      validateBackendOptions({
        contract: contract(),
        models: { space: binding },
        persistence: malformed as LocalSyncPersistence<Tx>,
        ...scopeConfiguration,
      }),
    ).toThrow(LocalSyncBackendOptionsError);
  });

  it('requires scope services without a Scope Model registry', () => {
    const base = {
      contract: contract(),
      models: { space: binding },
      persistence: persistence(),
    };

    expect(() =>
      validateBackendOptions({ ...base, ...scopeConfiguration }),
    ).not.toThrow();
    expect(() =>
      validateBackendOptions({
        ...base,
        ...scopeConfiguration,
        scopeAuthorizer: {} as never,
      }),
    ).toThrow(/scopeAuthorizer.canRead must be a function/);
    expect(() =>
      validateBackendOptions({
        ...base,
        ...scopeConfiguration,
        principalScope: undefined as never,
      }),
    ).toThrow(/principalScope must be a function/);
  });
});
