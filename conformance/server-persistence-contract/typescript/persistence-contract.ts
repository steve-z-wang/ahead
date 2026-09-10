import type {
  CompactedInvalidation,
  LocalSyncPersistence,
} from 'local-sync-backend';

/**
 * One adapter, ready to be asked the same questions as every other adapter.
 *
 * The contract owns the questions; a harness owns construction and cleanup and
 * nothing else. `ownerA` / `ownerB` belong only to Uplink ownership. Scope
 * strings are contract-owned opaque text: a persistence adapter must not
 * require a matching domain row merely because a ledger uses that string.
 */
export interface PersistenceContractHarness<TTx> {
  readonly persistence: LocalSyncPersistence<TTx>;
  readonly ownerA: string;
  readonly ownerB: string;
  /** Empty durable state and a listener-free committed-change source. */
  reset(): Promise<void>;
  /** Release the infrastructure the factory acquired. */
  close(): Promise<void>;
}

export type PersistenceContractFactory<TTx> = () => Promise<PersistenceContractHarness<TTx>>;

// Client ids are UUIDs on the wire and in every adapter's column; the two
// owners are the harness's, but these are the contract's own.
const CLIENT = '8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0001';
const OTHER_CLIENT = '8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0002';
const REQUEST_HASH = 'a'.repeat(64);
const SCOPE_ID = '8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0101';
const OTHER_SCOPE_ID = '8b0a2a2e-5f8f-4c1a-9c1e-2b1d5b1f0102';
// This contract is imported as test source by adapters outside the conformance
// package. Keep its Framework dependency type-only so those adapters do not
// need conformance's node_modules merely to load their own test suite.
const USER_SCOPE = `User:${SCOPE_ID}`;
const OTHER_USER_SCOPE = `User:${OTHER_SCOPE_ID}`;
const SPACE_SCOPE = `Space:${SCOPE_ID}`;

const identityBytes = (identityKey: string): Uint8Array =>
  new TextEncoder().encode(`{"id":"${identityKey}"}`);

/** Buffer and Uint8Array are not equal to Jest, and adapters return both. */
const bytes = (value: Uint8Array | null): Uint8Array => Uint8Array.from(value ?? []);

const scanned = (rows: readonly CompactedInvalidation[]): readonly CompactedInvalidation[] =>
  rows.map((row) => ({ ...row, identityBytes: bytes(row.identityBytes) }));

/**
 * Every assertion the persistence ports make, defined once.
 *
 * What lives here is what any adapter must satisfy: transactions and
 * savepoints, snapshot stability, uplink claims and receipts, downlink heads,
 * invalidation compaction and scanning, and the committed-change hint. What
 * does not live here is any one adapter's mechanics — SQL, locking strategy,
 * timing, listener introspection — which stay beside that adapter.
 *
 * A wake is recorded synchronously, because every adapter announces a commit
 * before the write that carried it resolves. An adapter that cannot is not
 * slow, it is wrong: a subscriber released after the caller has moved on has
 * already missed its page.
 */
export function persistenceContract<TTx>(factory: PersistenceContractFactory<TTx>): void {
  let harness!: PersistenceContractHarness<TTx>;

  const storage = () => harness.persistence.storage;
  const transactions = () => harness.persistence.transactions;

  /** What the Framework actually does to a scope: move the head, dirty a row. */
  async function publish(
    transaction: TTx,
    scope: string,
    identityKey: string,
    syncId: bigint,
  ): Promise<void> {
    await storage().lockOrCreateDownlinkHead(transaction, scope);
    await storage().writeDownlinkHead(transaction, scope, syncId);
    await storage().upsertInvalidation(transaction, {
      scope,
      modelKey: 'moment',
      identityKey,
      identityBytes: identityBytes(identityKey),
      syncId,
    });
  }

  function head(scope: string): Promise<bigint> {
    return transactions().readSnapshot((tx) => storage().readDownlinkHead(tx, scope));
  }

  function scan(
    scope: string,
    afterSyncId: bigint,
    limit: number,
  ): Promise<readonly CompactedInvalidation[]> {
    return transactions()
      .readSnapshot((tx) => storage().scanInvalidations(tx, { scope, afterSyncId, limit }))
      .then(scanned);
  }

  /** Records who was woken, in order, so a negative case needs no timer. */
  function recorder(): {
    readonly wakes: string[];
    subscribe(scope: string, signal?: AbortSignal): void;
  } {
    const wakes: string[] = [];
    return {
      wakes,
      subscribe(scope, signal = new AbortController().signal) {
        harness.persistence.committedChanges.subscribe(
          scope,
          () => wakes.push(scope),
          signal,
        );
      },
    };
  }

  beforeAll(async () => {
    harness = await factory();
  });

  beforeEach(async () => {
    await harness.reset();
  });

  afterAll(async () => {
    await harness.close();
  });

  describe('transactions', () => {
    it('commits a write and discards a rolled-back one', async () => {
      await transactions().write(async (tx) => {
        await storage().lockOrCreateDownlinkHead(tx, USER_SCOPE);
        await storage().writeDownlinkHead(tx, USER_SCOPE, 7n);
      });

      await expect(
        transactions().write(async (tx) => {
          await storage().writeDownlinkHead(tx, USER_SCOPE, 9n);
          throw new Error('abandon the batch');
        }),
      ).rejects.toThrow('abandon the batch');

      expect(await head(USER_SCOPE)).toBe(7n);
    });

    it('rolls back one savepoint, nests, and leaves the outer write whole', async () => {
      await transactions().write(async (tx) => {
        await storage().lockOrCreateDownlinkHead(tx, USER_SCOPE);
        await storage().writeDownlinkHead(tx, USER_SCOPE, 1n);

        await expect(
          transactions().savepoint(tx, async () => {
            await storage().writeDownlinkHead(tx, USER_SCOPE, 2n);
            await transactions().savepoint(tx, async () => {
              await storage().writeDownlinkHead(tx, USER_SCOPE, 3n);
            });
            throw new Error('rejected');
          }),
        ).rejects.toThrow('rejected');

        expect(await storage().readDownlinkHead(tx, USER_SCOPE)).toBe(1n);
        await transactions().savepoint(tx, async () => {
          await storage().writeDownlinkHead(tx, USER_SCOPE, 7n);
        });
      });

      expect(await head(USER_SCOPE)).toBe(7n);
    });

    it('keeps a read snapshot stable while a writer commits under it', async () => {
      await transactions().write(async (tx) => {
        await storage().lockOrCreateDownlinkHead(tx, USER_SCOPE);
        await storage().writeDownlinkHead(tx, USER_SCOPE, 1n);
      });

      const seen = await transactions().readSnapshot(async (tx) => {
        const before = await storage().readDownlinkHead(tx, USER_SCOPE);
        await transactions().write(async (writeTx) => {
          await storage().lockOrCreateDownlinkHead(writeTx, USER_SCOPE);
          await storage().writeDownlinkHead(writeTx, USER_SCOPE, 5n);
        });
        const after = await storage().readDownlinkHead(tx, USER_SCOPE);
        return { before, after };
      });

      expect(seen).toEqual({ before: 1n, after: 1n });
      expect(await head(USER_SCOPE)).toBe(5n);
    });
  });

  describe('downlink heads', () => {
    it('reads zero for a viewer that has no head yet', async () => {
      expect(await head(USER_SCOPE)).toBe(0n);
    });

    it('creates a missing head at zero under concurrent first publication', async () => {
      const observed = await Promise.all([
        transactions().write((tx) => storage().lockOrCreateDownlinkHead(tx, USER_SCOPE)),
        transactions().write((tx) => storage().lockOrCreateDownlinkHead(tx, USER_SCOPE)),
      ]);

      expect(observed).toEqual([0n, 0n]);
      expect(await head(USER_SCOPE)).toBe(0n);
    });

    it('locks an existing head without moving it', async () => {
      await transactions().write(async (tx) => {
        await storage().lockOrCreateDownlinkHead(tx, USER_SCOPE);
        await storage().writeDownlinkHead(tx, USER_SCOPE, 5n);
      });

      const locked = await transactions().write((tx) =>
        storage().lockOrCreateDownlinkHead(tx, USER_SCOPE),
      );

      expect(locked).toBe(5n);
      expect(await head(USER_SCOPE)).toBe(5n);
    });

    it('keeps each full scope string head to itself', async () => {
      await transactions().write(async (tx) => {
        await storage().lockOrCreateDownlinkHead(tx, USER_SCOPE);
        await storage().writeDownlinkHead(tx, USER_SCOPE, 4n);
      });

      expect(await head(OTHER_USER_SCOPE)).toBe(0n);
      expect(await head(SPACE_SCOPE)).toBe(0n);
    });
  });

  describe('uplink receipts', () => {
    it('claims a new client at sequence zero with no receipt', async () => {
      const locked = await transactions().write((tx) =>
        storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
        }),
      );

      expect(locked).toEqual({
        clientId: CLIENT,
        ownerUserId: harness.ownerA,
        lastCommittedBatchSequence: 0n,
        requestHash: null,
        responseBytes: null,
      });
    });

    it('returns the first claimant as owner to a second account', async () => {
      await transactions().write((tx) =>
        storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
        }),
      );

      const locked = await transactions().write((tx) =>
        storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerB,
          clientId: CLIENT,
        }),
      );

      expect(locked.ownerUserId).toBe(harness.ownerA);
    });

    it('replays the exact stored bytes and batch sequence', async () => {
      const responseBytes = Uint8Array.from([8, 3, 18, 0, 255, 0, 17]);
      await transactions().write(async (tx) => {
        await storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
        });
        await storage().saveUplinkReceipt(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
          batchSequence: 1n,
          requestHash: REQUEST_HASH,
          responseBytes,
        });
      });

      const replayed = await transactions().write((tx) =>
        storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
        }),
      );

      expect(replayed.lastCommittedBatchSequence).toBe(1n);
      expect(replayed.requestHash).toBe(REQUEST_HASH);
      expect(bytes(replayed.responseBytes)).toEqual(responseBytes);
    });

    it("keeps each client's receipt to itself", async () => {
      await transactions().write(async (tx) => {
        await storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
        });
        await storage().saveUplinkReceipt(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
          batchSequence: 1n,
          requestHash: REQUEST_HASH,
          responseBytes: Uint8Array.from([1]),
        });
      });

      const other = await transactions().write((tx) =>
        storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: OTHER_CLIENT,
        }),
      );
      const first = await transactions().write((tx) =>
        storage().claimAndLockUplink(tx, {
          ownerUserId: harness.ownerA,
          clientId: CLIENT,
        }),
      );

      expect(other.lastCommittedBatchSequence).toBe(0n);
      expect(other.requestHash).toBeNull();
      expect(first.lastCommittedBatchSequence).toBe(1n);
    });
  });

  describe('invalidations', () => {
    it('compacts one row per scope string, Model, and identity', async () => {
      await transactions().write(async (tx) => {
        await publish(tx, USER_SCOPE, 'id-1', 1n);
        await publish(tx, USER_SCOPE, 'id-1', 4n);
        await publish(tx, SPACE_SCOPE, 'id-1', 2n);
      });

      expect((await scan(USER_SCOPE, 0n, 50)).map((row) => row.syncId)).toEqual([4n]);
      expect((await scan(SPACE_SCOPE, 0n, 50)).map((row) => row.syncId)).toEqual([2n]);
    });

    it('returns every field it was given', async () => {
      await transactions().write((tx) => publish(tx, USER_SCOPE, 'id-1', 3n));

      expect(await scan(USER_SCOPE, 0n, 50)).toEqual([
        {
          scope: USER_SCOPE,
          modelKey: 'moment',
          identityKey: 'id-1',
          identityBytes: identityBytes('id-1'),
          syncId: 3n,
        },
      ]);
    });

    it('scans in sync-id order, after the cursor, up to the limit', async () => {
      await transactions().write(async (tx) => {
        await publish(tx, USER_SCOPE, 'id-0', 3n);
        await publish(tx, USER_SCOPE, 'id-1', 1n);
        await publish(tx, USER_SCOPE, 'id-2', 2n);
      });

      expect((await scan(USER_SCOPE, 0n, 50)).map((row) => row.syncId)).toEqual([1n, 2n, 3n]);
      expect((await scan(USER_SCOPE, 1n, 1)).map((row) => row.identityKey)).toEqual(['id-2']);
    });

    it('scans only the asking scope string rows', async () => {
      await transactions().write(async (tx) => {
        await publish(tx, USER_SCOPE, 'a-1', 1n);
        await publish(tx, SPACE_SCOPE, 'b-1', 1n);
      });

      expect((await scan(USER_SCOPE, 0n, 50)).map((row) => row.identityKey)).toEqual(['a-1']);
    });

    it('finds the concrete scopes containing one Model identity in stable order', async () => {
      await transactions().write(async (tx) => {
        await publish(tx, USER_SCOPE, 'shared', 1n);
        await publish(tx, SPACE_SCOPE, 'shared', 1n);
        await publish(tx, OTHER_USER_SCOPE, 'other', 1n);
      });

      const scopes = await transactions().readSnapshot((tx) =>
        storage().findInvalidationScopes(tx, {
          modelKey: 'moment',
          identityKey: 'shared',
        }),
      );

      expect(scopes).toEqual([SPACE_SCOPE, USER_SCOPE]);
    });
  });

  describe('committed changes', () => {
    it('wakes a viewer only once the write it belongs to has committed', async () => {
      const { wakes, subscribe } = recorder();
      subscribe(USER_SCOPE);

      await transactions().write(async (tx) => {
        await publish(tx, USER_SCOPE, 'm-1', 1n);
        expect(wakes).toEqual([]);
      });

      expect(wakes).toEqual([USER_SCOPE]);
    });

    it('stays silent when the write rolls back', async () => {
      const { wakes, subscribe } = recorder();
      subscribe(USER_SCOPE);

      await expect(
        transactions().write(async (tx) => {
          await publish(tx, USER_SCOPE, 'm-1', 1n);
          throw new Error('abandon the batch');
        }),
      ).rejects.toThrow('abandon the batch');

      expect(wakes).toEqual([]);
    });

    it('wakes a viewer whose earlier sync ids died with a rolled-back savepoint', async () => {
      const { wakes, subscribe } = recorder();
      subscribe(USER_SCOPE);

      // A rejected mutation gives its sync ids back: the head ends BELOW the
      // highest number this write ever allocated. Anything that remembered
      // that high-water mark would wait for a head that never arrives.
      await transactions().write(async (tx) => {
        await expect(
          transactions().savepoint(tx, async () => {
            await publish(tx, USER_SCOPE, 'm-1', 1n);
            await publish(tx, USER_SCOPE, 'm-2', 2n);
            await publish(tx, USER_SCOPE, 'm-3', 3n);
            throw new Error('reject this position');
          }),
        ).rejects.toThrow('reject this position');
        await publish(tx, USER_SCOPE, 'm-4', 1n);
      });

      expect(wakes).toEqual([USER_SCOPE]);
      expect(await head(USER_SCOPE)).toBe(1n);
    });

    it('leaves a viewer the write never touched alone', async () => {
      const { wakes, subscribe } = recorder();
      subscribe(USER_SCOPE);
      subscribe(SPACE_SCOPE);

      await transactions().write((tx) => publish(tx, USER_SCOPE, 'm-1', 1n));

      expect(wakes).toEqual([USER_SCOPE]);
    });

    it('wakes a subscriber that attached while the write was still open', async () => {
      const { wakes, subscribe } = recorder();

      await transactions().write(async (tx) => {
        await publish(tx, USER_SCOPE, 'm-1', 1n);
        // Who is listening is decided when the commit is announced, not when
        // the row was written — this subscriber arrived in between.
        subscribe(USER_SCOPE);
      });

      expect(wakes).toEqual([USER_SCOPE]);
    });

    it('never wakes a subscriber whose signal aborted', async () => {
      const { wakes, subscribe } = recorder();
      const aborted = new AbortController();
      subscribe(USER_SCOPE, aborted.signal);
      aborted.abort();

      await transactions().write((tx) => publish(tx, USER_SCOPE, 'm-1', 1n));

      expect(wakes).toEqual([]);
    });

    it('takes no subscriber and wakes nobody once the source has closed', async () => {
      const { wakes, subscribe } = recorder();
      await harness.persistence.committedChanges.close();
      subscribe(USER_SCOPE);

      await transactions().write((tx) => publish(tx, USER_SCOPE, 'm-1', 1n));

      expect(wakes).toEqual([]);
    });
  });
}
