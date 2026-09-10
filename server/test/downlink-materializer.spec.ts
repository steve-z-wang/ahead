import {
  BackendModelBinding,
  BackendReadContext,
  CompactedInvalidation,
  GeneratedBackendContract,
  LocalSyncProtocolError,
  LocalSyncScopeForbiddenError,
  LocalSyncStorage,
  LocalSyncTransactions,
  createDownlinkMaterializer,
  validateBackendOptions,
} from "../src";

interface Tx {
  readonly id: number;
  prepared: string[];
}

const viewerId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const viewerScope = `User:${viewerId}`;

interface SpaceIdentity {
  readonly id: string;
}

interface SpaceState extends SpaceIdentity {
  readonly title: string;
}

interface StarIdentity {
  readonly userId: string;
  readonly momentId: string;
}

interface StarState extends StarIdentity {
  readonly label: string;
}

function decodePage(bytes: Uint8Array): unknown {
  return JSON.parse(Buffer.from(bytes).toString("utf8"));
}

const spaceDescriptor = {
  name: "Space",
  identityFields: ["id"],
  fields: [
    {
      name: "id",
      nullable: false,
      identity: true,
      type: { kind: "scalar", name: "uuid" },
    },
    {
      name: "title",
      nullable: false,
      identity: false,
      type: { kind: "scalar", name: "string" },
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

const starDescriptor = {
  name: "Star",
  identityFields: ["userId", "momentId"],
  fields: [
    {
      name: "label",
      nullable: false,
      identity: false,
      type: { kind: "scalar", name: "string" },
    },
    {
      name: "momentId",
      nullable: false,
      identity: true,
      type: { kind: "scalar", name: "uuid" },
    },
    {
      name: "userId",
      nullable: false,
      identity: true,
      type: { kind: "scalar", name: "uuid" },
    },
  ],
  forward: {
    read: async (
      binding: BackendModelBinding<Tx, StarIdentity, StarState>,
      context: BackendReadContext<Tx>,
      identities: readonly StarIdentity[],
    ) => binding.read.forViewer(context, identities),
  },
} as const;

function contract(): GeneratedBackendContract {
  return {
    enumValues: {},
    models: { space: spaceDescriptor, star: starDescriptor },
  };
}

class Storage implements LocalSyncStorage<Tx> {
  head = 0n;
  rows: readonly CompactedInvalidation[] = [];
  readonly calls: Array<{
    operation: string;
    transaction: Tx;
    value?: unknown;
  }> = [];
  moveHeadAfterRead: bigint | null = null;
  returnRowsVerbatim = false;

  async readDownlinkHead(transaction: Tx, scope: string) {
    this.calls.push({ operation: "head", transaction, value: scope });
    const result = this.head;
    if (this.moveHeadAfterRead !== null) this.head = this.moveHeadAfterRead;
    return result;
  }

  async scanInvalidations(
    transaction: Tx,
    query: { scope: string; afterSyncId: bigint; limit: number },
  ) {
    this.calls.push({ operation: "scan", transaction, value: query });
    if (this.returnRowsVerbatim) return this.rows.slice(0, query.limit);
    return this.rows
      .filter(
        (row) => row.scope === query.scope && row.syncId > query.afterSyncId,
      )
      .sort((left, right) => (left.syncId < right.syncId ? -1 : 1))
      .slice(0, query.limit);
  }

  claimAndLockUplink(): never {
    throw new Error("not used");
  }
  saveUplinkReceipt(): never {
    throw new Error("not used");
  }
  lockOrCreateDownlinkHead(): never {
    throw new Error("not used");
  }
  writeDownlinkHead(): never {
    throw new Error("not used");
  }
  upsertInvalidation(): never {
    throw new Error("not used");
  }
  findInvalidationScopes(): never {
    throw new Error("not used");
  }
}

class Transactions implements LocalSyncTransactions<Tx> {
  readonly tx = { id: 1, prepared: [] as string[] };
  readCount = 0;
  writeCount = 0;

  async readSnapshot<T>(work: (transaction: Tx) => Promise<T>): Promise<T> {
    this.readCount += 1;
    return work(this.tx);
  }

  async write<T>(work: (transaction: Tx) => Promise<T>): Promise<T> {
    this.writeCount += 1;
    const before = [...this.tx.prepared];
    try {
      return await work(this.tx);
    } catch (error) {
      this.tx.prepared = before;
      throw error;
    }
  }

  savepoint(): never {
    throw new Error("not used");
  }
}

function fixture(
  options: {
    models?: Record<string, undefined>;
    canRead?: (scope: string) => Promise<boolean>;
  } = {},
) {
  const storage = new Storage();
  const transactions = new Transactions();
  const reads: Array<{
    model: string;
    context: {
      transaction: Tx;
      viewerUserId: string;
      scope: string;
    };
    identities: readonly object[];
  }> = [];
  const binding: BackendModelBinding<Tx, SpaceIdentity, SpaceState> = {
    read: {
      forViewer: async (context, identities) => {
        reads.push({ model: "space", context, identities });
        return identities.map((identity) => ({
          ...identity,
          title: identity.id,
        }));
      },
    },
  };
  const starBinding: BackendModelBinding<Tx, StarIdentity, StarState> = {
    read: {
      forViewer: async (context, identities) => {
        reads.push({ model: "star", context, identities });
        return identities.map((identity) => ({
          ...identity,
          label: "favorite",
        }));
      },
    },
  };
  const registered: Record<string, object> = {
    space: binding,
    star: starBinding,
  };
  for (const key of Object.keys(options.models ?? {})) delete registered[key];
  const components = validateBackendOptions({
    scopeAuthorizer: {
      canRead: async (_context, scope) => options.canRead?.(scope) ?? true,
    },
    principalScope: ({ userId }) => `User:${userId}`,
    contract: contract(),
    models: registered,
    persistence: {
      storage,
      transactions,
      committedChanges: {
        subscribe: () => undefined,
        close: async () => undefined,
      },
    },
  });
  return {
    materializer: createDownlinkMaterializer(components),
    storage,
    transactions,
    reads,
    binding,
    starBinding,
  };
}

function encode(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), "utf8");
}

async function pull(
  materializer: ReturnType<typeof createDownlinkMaterializer>,
  afterSyncId: bigint,
) {
  const page = await materializer.pull({
    principal: { userId: viewerId },
    requestBytes: encode({
      clientId: "client",
      scope: viewerScope,
      fromCursor: Number(afterSyncId),
    }),
  });
  return decodePage(page.bytes);
}

function row(syncId: bigint, id = syncId.toString()): CompactedInvalidation {
  const identity = { id: `${id.padStart(8, "0")}-aaaa-4aaa-8aaa-aaaaaaaaaaaa` };
  return {
    scope: viewerScope,
    modelKey: "space",
    identityKey: JSON.stringify(identity),
    identityBytes: Uint8Array.from(Buffer.from(JSON.stringify(identity))),
    syncId,
  };
}

function starRow(
  syncId: bigint,
  userId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  momentId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
): CompactedInvalidation {
  const identity = { momentId, userId };
  const identityKey = JSON.stringify({ momentId, userId });
  return {
    scope: viewerScope,
    modelKey: "star",
    identityKey,
    identityBytes: Uint8Array.from(Buffer.from(identityKey)),
    syncId,
  };
}

describe("Downlink cursor and page window", () => {
  it.each([
    [{ clientId: "client", fromCursor: -1 }],
    [{ clientId: "", fromCursor: 0 }],
    [{ clientId: "client", fromCursor: 1.5 }],
    [{ clientId: "client" }],
    [{ clientId: "client", fromCursor: 0, limit: 0 }],
  ])(
    "rejects an invalid request before opening a materialization transaction",
    async (request) => {
      const { materializer, transactions } = fixture();

      await expect(
        materializer.pull({
          principal: { userId: viewerId },
          requestBytes: encode(request),
        }),
      ).rejects.toBeInstanceOf(LocalSyncProtocolError);
      expect(transactions.readCount).toBe(0);
      expect(transactions.writeCount).toBe(0);
    },
  );

  it("authorizes the requested scope before reading its head or invalidations", async () => {
    const seen: string[] = [];
    const { materializer, storage, transactions } = fixture({
      canRead: async (scope) => {
        seen.push(scope);
        return false;
      },
    });

    await expect(pull(materializer, 0n)).rejects.toBeInstanceOf(
      LocalSyncScopeForbiddenError,
    );
    expect(seen).toEqual([viewerScope]);
    expect(transactions.readCount).toBe(0);
    expect(transactions.writeCount).toBe(1);
    expect(storage.calls).toEqual([]);
  });

  it("fails loudly on an invalidation for an unregistered Model", async () => {
    // A stored invalidation naming a Model with no registered loader is an
    // invariant defect — the Scope Ledger write should itself have
    // been refused — so it is never a row to quietly skip (CAP-488).
    const { materializer, storage } = fixture({ models: { space: undefined } });
    storage.head = 10n;
    storage.rows = [row(2n)];

    await expect(pull(materializer, 1n)).rejects.toThrow(/unregistered Model/);
  });

  it("uses one materialization transaction, viewer ordering, and the fixed limit of 50", async () => {
    const { materializer, storage, transactions } = fixture();
    storage.head = 80n;
    storage.rows = [
      row(60n),
      ...Array.from({ length: 55 }, (_, index) => row(BigInt(index + 2))),
    ];

    const page = (await pull(materializer, 1n)) as Record<string, unknown>;

    expect(page.fromCursor).toBe(1);
    expect(page.toCursor).toBe(51);
    expect(page.changes).toHaveLength(50);
    expect(transactions.readCount).toBe(0);
    expect(transactions.writeCount).toBe(1);
    expect(storage.calls).toEqual([
      { operation: "head", transaction: transactions.tx, value: viewerScope },
      {
        operation: "scan",
        transaction: transactions.tx,
        value: { scope: viewerScope, afterSyncId: 1n, limit: 50 },
      },
    ]);
  });

  it("serves cursor zero through the ordinary materialization transaction", async () => {
    const { materializer, storage, transactions } = fixture();
    storage.head = 9n;
    storage.rows = [row(3n), row(8n)];

    const page = (await pull(materializer, 0n)) as Record<string, unknown>;

    // Zero is a number, not a control message (CAP-482). It selects the same
    // `syncId > fromCursor` scan every other cursor selects, so a
    // device replaying from the beginning is served the invalidations the
    // Backend retained for it. The transaction may prepare a viewer-relative
    // value, but zero itself still has no command semantics.
    expect(transactions.writeCount).toBe(1);
    expect(transactions.readCount).toBe(0);
    expect(page.fromCursor).toBe(0);
    expect(page.changes).toHaveLength(2);
  });

  it("advances a short or empty page through the snapshot head across gaps", async () => {
    const short = fixture();
    short.storage.head = 9n;
    short.storage.rows = [row(3n), row(8n)];
    await expect(pull(short.materializer, 1n)).resolves.toMatchObject({
      fromCursor: 1,
      toCursor: 9,
    });

    const empty = fixture();
    empty.storage.head = 12n;
    await expect(pull(empty.materializer, 4n)).resolves.toEqual({
      fromCursor: 4,
      scope: viewerScope,
      changes: [],
      toCursor: 12,
    });
  });

  it("rejects a cursor ahead of the viewer head as a protocol error", async () => {
    // A page answering it would carry through < from — an instruction to walk
    // the client's cursor backwards — and crash every live subscription.
    const { materializer, storage } = fixture();
    storage.head = 3n;

    await expect(pull(materializer, 7n)).rejects.toBeInstanceOf(
      LocalSyncProtocolError,
    );
  });

  it("uses the repeatable-read head ceiling despite later movement", async () => {
    const { materializer, storage } = fixture();
    storage.head = 5n;
    storage.moveHeadAfterRead = 99n;
    storage.rows = [row(3n)];

    await expect(pull(materializer, 0n)).resolves.toMatchObject({
      toCursor: 5,
    });
  });
});

describe("Downlink typed materialize", () => {
  it("prepares each Model group before reading it in the same transaction", async () => {
    const fixture_ = fixture();
    fixture_.storage.head = 7n;
    fixture_.storage.rows = [row(2n), row(7n, "7")];
    const calls: string[] = [];
    fixture_.binding.read.prepareForViewer = async (context, identities) => {
      calls.push("prepare");
      expect(context.transaction).toBe(fixture_.transactions.tx);
      expect(identities).toHaveLength(2);
      context.transaction.prepared.push(...identities.map(({ id }) => id));
    };
    fixture_.binding.read.forViewer = async (context, identities) => {
      calls.push("read");
      expect(context.transaction.prepared).toEqual(
        identities.map(({ id }) => id),
      );
      return identities.map((identity) => ({ ...identity, title: "visible" }));
    };

    await expect(pull(fixture_.materializer, 0n)).resolves.toBeDefined();

    expect(calls).toEqual(["prepare", "read"]);
  });

  it("rolls preparation back when its Model read fails", async () => {
    const fixture_ = fixture();
    fixture_.storage.head = 2n;
    fixture_.storage.rows = [row(2n)];
    fixture_.binding.read.prepareForViewer = async (context) => {
      context.transaction.prepared.push("receipt");
    };
    fixture_.binding.read.forViewer = async () => {
      throw new Error("read failed after preparation");
    };

    await expect(pull(fixture_.materializer, 0n)).rejects.toThrow(
      "read failed after preparation",
    );
    expect(fixture_.transactions.tx.prepared).toEqual([]);
  });

  it("batches once per Model and restores page order for upserts and deletes", async () => {
    const fixture_ = fixture();
    fixture_.storage.head = 8n;
    fixture_.storage.rows = [row(2n), starRow(5n), row(7n, "7")];
    fixture_.binding.read.forViewer = async (context, identities) => {
      fixture_.reads.push({ model: "space", context, identities });
      return [{ ...identities[0], title: "visible" }, null];
    };

    const page = await pull(fixture_.materializer, 1n);

    expect(fixture_.reads).toEqual([
      {
        model: "space",
        context: {
          transaction: fixture_.transactions.tx,
          viewerUserId: viewerId,
          scope: viewerScope,
        },
        identities: [
          { id: "00000002-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
          { id: "00000007-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
        ],
      },
      {
        model: "star",
        context: {
          transaction: fixture_.transactions.tx,
          viewerUserId: viewerId,
          scope: viewerScope,
        },
        identities: [
          {
            userId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            momentId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          },
        ],
      },
    ]);
    expect(page).toEqual({
      fromCursor: 1,
      scope: viewerScope,
      toCursor: 8,
      changes: [
        {
          syncId: 2,
          model: "Space",
          identity: { id: "00000002-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
          // Identity rides beside the state, never inside it (CAP-428).
          state: { title: "visible" },
        },
        {
          syncId: 5,
          model: "Star",
          identity: {
            userId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            momentId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          },
          state: {
            label: "favorite",
          },
        },
        // Absence, not a delete case: the row left the viewer's world.
        {
          syncId: 7,
          model: "Space",
          identity: { id: "00000007-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
          state: null,
        },
      ],
    });
  });

  it("aborts the whole snapshot when a reader fails or returns misaligned results", async () => {
    const failure = fixture();
    failure.storage.head = 2n;
    failure.storage.rows = [row(2n)];
    failure.binding.read.forViewer = async () => {
      throw new Error("read failed");
    };
    await expect(pull(failure.materializer, 0n)).rejects.toThrow("read failed");

    const misaligned = fixture();
    misaligned.storage.head = 3n;
    misaligned.storage.rows = [row(2n), row(3n)];
    misaligned.binding.read.forViewer = async () => [null];
    await expect(pull(misaligned.materializer, 0n)).rejects.toThrow(
      "misaligned",
    );

    const invalidState = fixture();
    invalidState.storage.head = 2n;
    invalidState.storage.rows = [row(2n)];
    invalidState.binding.read.forViewer = async () => [undefined as never];
    await expect(pull(invalidState.materializer, 0n)).rejects.toThrow(
      "invalid state",
    );
  });

  it.each([
    [[row(2n), { ...row(3n), syncId: 2n }], "order"],
    [[{ ...row(2n), scope: "User:other" }], "order"],
    [[{ ...row(2n), modelKey: "missing" }], "Model"],
  ])(
    "rejects corrupt persisted rows before calling readers: %s",
    async (rows, message) => {
      const fixture_ = fixture();
      fixture_.storage.head = 3n;
      fixture_.storage.rows = rows;
      fixture_.storage.returnRowsVerbatim = true;

      await expect(pull(fixture_.materializer, 0n)).rejects.toThrow(message);
      expect(fixture_.reads).toEqual([]);
    },
  );
});
