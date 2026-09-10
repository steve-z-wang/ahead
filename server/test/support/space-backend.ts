import {
  BackendModelBinding,
  BackendReadContext,
  BackendWriteContext,
  CommittedChanges,
  CompactedInvalidation,
  GeneratedBackendContract,
  GeneratedMutationContract,
  LocalSyncBackend,
  LocalSyncStorage,
  LocalSyncTransactions,
  StoredUplinkReceipt,
  createLocalSyncBackend,
} from '../../src';

/// One Model, one read binding, one declared act, and storage that remembers —
/// the smallest world a server can actually serve, shared by the specs that
/// need a real one.

export interface Tx {
  readonly id: number;
}

export const UserScope = 'User';

export interface SpaceIdentity {
  readonly id: string;
}

export interface SpaceState extends SpaceIdentity {
  readonly title: string;
  /** An Int, because canonical JSON cannot encode the bigint one used to be. */
  readonly position: number;
}

export interface SpaceCreate {
  readonly title: string;
  readonly position: number;
  readonly nickname: string | null;
}

export function decodeWire(bytes: Uint8Array): unknown {
  return JSON.parse(Buffer.from(bytes).toString('utf8'));
}

export const descriptor = {
  name: 'Space',
  identityFields: ['id'],
  fields: [
    {
      name: 'id',
      nullable: false,
      identity: true,
      type: { kind: 'scalar', name: 'uuid' },
    },
    {
      name: 'title',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
    {
      name: 'position',
      nullable: false,
      identity: false,
      type: { kind: 'scalar', name: 'int' },
    },
    {
      name: 'nickname',
      nullable: true,
      identity: false,
      type: { kind: 'scalar', name: 'string' },
    },
  ],
  forward: {
    read: async (
      binding: BackendModelBinding<Tx, SpaceIdentity, SpaceState>,
      context: BackendReadContext<Tx>,
      identities: readonly SpaceIdentity[],
    ) => binding.read.forViewer(context, identities),
  },
} as const;

export function contract(): GeneratedBackendContract {
  return {
    enumValues: {},
    models: { space: descriptor },
  };
}

/// The one act this world declares. A write reaches the server no other way.
export interface CreateSpaceArguments {
  readonly space: {
    readonly identity: SpaceIdentity;
    readonly data: SpaceCreate;
  };
}

export type CreateSpaceResolver = (
  context: BackendWriteContext<Tx>,
  arguments_: CreateSpaceArguments,
) => Promise<void>;

export function mutationContract(): GeneratedMutationContract {
  return {
    mutations: {
      createSpace: {
        v1: {
          version: 1,
          input: contract(),
          name: 'CreateSpace',
          slots: [
            {
              name: 'space',
              model: 'Space',
              operation: 'create',
              cardinality: 'single',
            },
          ],
          forward: async (
            resolver: CreateSpaceResolver,
            context: BackendWriteContext<Tx>,
            arguments_: CreateSpaceArguments,
          ) => resolver(context, arguments_),
        },
      },
    },
  } as unknown as GeneratedMutationContract;
}

/// One `CreateSpace` element, as a client spells it on the wire.
export function createSpaceAct(
  ordinal: number,
  identity: unknown = { id },
  values: unknown = { title: 'new', position: 3 },
): unknown {
  return {
    ordinal,
    name: 'CreateSpace',
    operations: [{ model: 'Space', op: 'create', identity, values }],
  };
}

export class PersistenceStorage implements LocalSyncStorage<Tx> {
  locked:
    | {
        ownerUserId: string;
        clientId: string;
        lastCommittedBatchSequence: bigint;
        requestHash: string | null;
        responseBytes: Uint8Array | null;
      }
    | undefined;
  readonly heads = new Map<string, bigint>();
  readonly headReads: string[] = [];
  readonly invalidations = new Map<string, CompactedInvalidation>();
  ledgerTransaction: Tx | null = null;

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
    this.locked = {
      ...receipt,
      lastCommittedBatchSequence: receipt.batchSequence,
    };
  }

  async lockOrCreateDownlinkHead(transaction: Tx, scope: string) {
    this.ledgerTransaction = transaction;
    return this.heads.get(scope) ?? 0n;
  }

  async writeDownlinkHead(transaction: Tx, scope: string, syncId: bigint) {
    this.ledgerTransaction = transaction;
    this.heads.set(scope, syncId);
  }

  async upsertInvalidation(transaction: Tx, row: CompactedInvalidation) {
    this.ledgerTransaction = transaction;
    this.invalidations.set(
      `${row.scope}:${row.modelKey}:${row.identityKey}`,
      row,
    );
  }

  async readDownlinkHead(_transaction: Tx, scope: string): Promise<bigint> {
    this.headReads.push(scope);
    return this.heads.get(scope) ?? 0n;
  }
  async scanInvalidations(
    _transaction: Tx,
    query: { scope: string; afterSyncId: bigint; limit: number },
  ) {
    return [...this.invalidations.values()]
      .filter(
        (row) => row.scope === query.scope && row.syncId > query.afterSyncId,
      )
      .sort((left, right) => (left.syncId < right.syncId ? -1 : 1))
      .slice(0, query.limit);
  }

  async findInvalidationScopes(
    _transaction: Tx,
    query: { modelKey: string; identityKey: string },
  ) {
    return [...this.invalidations.values()]
      .filter(
        (row) =>
          row.modelKey === query.modelKey &&
          row.identityKey === query.identityKey,
      )
      .map((row) => row.scope);
  }
}

export class Transactions implements LocalSyncTransactions<Tx> {
  readonly tx = { id: 1 };
  async write<T>(work: (transaction: Tx) => Promise<T>) {
    return work(this.tx);
  }
  async readSnapshot<T>(work: (transaction: Tx) => Promise<T>) {
    return work(this.tx);
  }
  async savepoint<T>(_transaction: Tx, work: () => Promise<T>) {
    return work();
  }
}

export class Changes implements CommittedChanges {
  closeCount = 0;
  cleanupCount = 0;
  subscribe(_scope: string, _wake: () => void, signal: AbortSignal): void {
    signal.addEventListener(
      'abort',
      () => {
        this.cleanupCount += 1;
      },
      { once: true },
    );
  }
  async close(): Promise<void> {
    this.closeCount += 1;
  }
}

export function fixture() {
  const storage = new PersistenceStorage();
  const transactions = new Transactions();
  const changes = new Changes();
  let backend: LocalSyncBackend<Tx>;
  const calls: string[] = [];
  const binding: BackendModelBinding<Tx, SpaceIdentity, SpaceState> = {
    read: {
      forViewer: async (_context, identities) => {
        calls.push('read');
        return identities.map((identity) => ({
          ...identity,
          title: 'visible',
          position: 7,
        }));
      },
    },
  };
  const createSpace: CreateSpaceResolver = async (context, arguments_) => {
    calls.push('create');
    await backend.scopeLedger.invalidate(context.transaction, {
      model: descriptor,
      identity: arguments_.space.identity,
      scopes: [`${UserScope}:${context.actorUserId}`],
    });
  };
  backend = createLocalSyncBackend({
    scopeAuthorizer: {
      canRead: async ({ viewerUserId }, scope) =>
        scope === `${UserScope}:${viewerUserId}`,
    },
    principalScope: ({ userId }) => `${UserScope}:${userId}`,
    contract: contract(),
    models: { space: binding },
    mutationContract: mutationContract(),
    mutations: { createSpace: { v1: createSpace } },
    persistence: { storage, transactions, committedChanges: changes },
  });
  return { backend, storage, transactions, changes, calls, binding };
}

export function encode(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

export const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
