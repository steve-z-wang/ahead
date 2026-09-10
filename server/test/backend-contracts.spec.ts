import {
  AuthenticatedPrincipal,
  BackendModelBinding,
  BackendReadContext,
  BackendWriteContext,
  CommittedChanges,
  CompactedInvalidation,
  LocalSyncBackend,
  LocalSyncMutationRejected,
  LocalSyncPersistence,
  LocalSyncStorage,
  LocalSyncTransactions,
  MutationResolver,
  PrincipalSubscription,
  StoredUplinkReceipt,
} from '../src';

interface TestTx {
  readonly id: string;
}

interface TestIdentity {
  readonly id: string;
}

interface TestState extends TestIdentity {
  readonly title: string;
}

/// A binding is a Model's read half and nothing else (CAP-444): a write is an
/// act, and it reaches the product through a mutation resolver.
const binding = {
  read: {
    async prepareForViewer(
      context: BackendReadContext<TestTx>,
      identities: readonly TestIdentity[],
    ): Promise<void> {
      void context.transaction.id;
      void identities.length;
    },
    async forViewer(
      context: BackendReadContext<TestTx>,
      identities: readonly TestIdentity[],
    ): Promise<readonly (TestState | null)[]> {
      void context.viewerUserId;
      return identities.map((identity) => ({ ...identity, title: 'visible' }));
    },
  },
} satisfies BackendModelBinding<TestTx, TestIdentity, TestState>;

interface CaptureSpaceArguments {
  readonly space: {
    readonly identity: TestIdentity;
    readonly data: { readonly title: string };
  };
}

/// The write context reaches the product here now, and carries the same one
/// transaction type the read context does.
const captureSpace: MutationResolver<TestTx> = (async (
  context: BackendWriteContext<TestTx>,
  arguments_: CaptureSpaceArguments,
): Promise<void> => {
  void context.actorUserId;
  void context.transaction.id;
  void arguments_.space.identity.id;
  void arguments_.space.data.title;
}) as MutationResolver<TestTx>;

type ExactBindings = Readonly<{
  space: typeof binding;
}>;

const completeBindings = { space: binding } satisfies ExactBindings;
// @ts-expect-error every generated Model binding is required
const missingBindings = {} satisfies ExactBindings;

// @ts-expect-error a binding with the wrong identity cannot satisfy the registry
const wrongBinding: BackendModelBinding<
  TestTx,
  { readonly other: string },
  TestState
> = binding;

describe('Backend public contracts', () => {
  it('keeps write/read contexts and generated binding values typed', async () => {
    expect(completeBindings.space).toBe(binding);
    expect(missingBindings).toEqual({});
    expect(wrongBinding).toBe(binding);
    await expect(
      captureSpace(
        { transaction: { id: 'tx' }, actorUserId: 'actor' },
        {
          space: { identity: { id: 'space' }, data: { title: 'a page' } },
        } as never,
      ),
    ).resolves.toBeUndefined();
  });

  it('uses one transaction type for writes, snapshots, and savepoints', async () => {
    const tx: TestTx = { id: 'tx' };
    const transactions: LocalSyncTransactions<TestTx> = {
      write: async (work) => work(tx),
      readSnapshot: async (work) => work(tx),
      savepoint: async (sameTx, work) => {
        expect(sameTx).toBe(tx);
        return work();
      },
    };

    await expect(transactions.write(async (value) => value.id)).resolves.toBe(
      'tx',
    );
    await expect(
      transactions.readSnapshot(async (value) => value.id),
    ).resolves.toBe('tx');
    await expect(transactions.savepoint(tx, async () => 7)).resolves.toBe(7);
  });

  it('uses bigint storage positions and freezes exact receipt bytes', async () => {
    const scope = 'User:8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0001';
    const responseBytes = Uint8Array.from([1, 2, 3]);
    const receipt: StoredUplinkReceipt = {
      ownerUserId: 'user',
      clientId: 'client',
      batchSequence: 4n,
      requestHash: 'hash',
      responseBytes,
    };
    const invalidation: CompactedInvalidation = {
      scope,
      modelKey: 'space',
      identityKey: 'id',
      identityBytes: Uint8Array.from([9]),
      syncId: 5n,
    };
    const storage = {
      claimAndLockUplink: async () => ({
        ownerUserId: 'user',
        clientId: 'client',
        lastCommittedBatchSequence: 3n,
        requestHash: null,
        responseBytes: null,
      }),
      saveUplinkReceipt: async (_tx: TestTx, value: StoredUplinkReceipt) => {
        expect(value.responseBytes).toBe(responseBytes);
      },
      lockOrCreateDownlinkHead: async () => 0n,
      writeDownlinkHead: async (_tx: TestTx, _scope, syncId: bigint) => {
        expect(syncId).toBe(5n);
      },
      upsertInvalidation: async (_tx: TestTx, value: CompactedInvalidation) => {
        expect(value).toBe(invalidation);
      },
      readDownlinkHead: async () => 5n,
      scanInvalidations: async () => [invalidation],
      findInvalidationScopes: async () => [scope],
    } satisfies LocalSyncStorage<TestTx>;
    const committedChanges: CommittedChanges = {
      subscribe: () => undefined,
      close: async () => undefined,
    };
    const persistence = {
      transactions: {
        write: async (work) => work({ id: 'tx' }),
        readSnapshot: async (work) => work({ id: 'tx' }),
        savepoint: async (_tx, work) => work(),
      },
      storage,
      committedChanges,
    } satisfies LocalSyncPersistence<TestTx>;

    await persistence.storage.saveUplinkReceipt({ id: 'tx' }, receipt);
  });

  it('exposes principal-only byte operations and explicit cancellation', () => {
    const principal: AuthenticatedPrincipal = { userId: 'user' };
    const request: PrincipalSubscription = {
      principal,
      requestBytes: Uint8Array.from([1]),
    };
    const backend: LocalSyncBackend<TestTx> = {
      scopeLedger: {
        invalidate: async () => undefined,
        scopesFor: async () => [],
      },
      upload: async () => Uint8Array.from([2]),
      pullDownlink: async () => ({ bytes: Uint8Array.from([3]) }),
      subscribeDownlink: async function* (input) {
        expect(input.signal).toBeInstanceOf(AbortSignal);
        yield { bytes: Uint8Array.from([4]) };
      },
      close: async () => undefined,
    };

    expect(request).not.toHaveProperty('metadata');
    expect(request).not.toHaveProperty('token');
    expect(backend.close()).toBeInstanceOf(Promise);
  });

  it('requires a stable nonblank deterministic rejection code', () => {
    expect(new LocalSyncMutationRejected('space.forbidden').code).toBe(
      'space.forbidden',
    );
    expect(() => new LocalSyncMutationRejected('')).toThrow(RangeError);
    expect(() => new LocalSyncMutationRejected('not a machine code')).toThrow(
      RangeError,
    );
  });
});
