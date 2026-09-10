import {
  contract,
  createSpaceAct,
  decodeWire,
  encode,
  fixture,
  UserScope,
} from './support/space-backend';
import { LocalSyncBackendOptionsError, createLocalSyncBackend } from '../src';

const viewerId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

describe('createLocalSyncBackend', () => {
  it('routes all surfaces and exposes the ScopeLedger used during Uplink', async () => {
    const fixture_ = fixture();
    const principal = { userId: viewerId };
    const upload = await fixture_.backend.upload({
      principal,
      requestBytes: encode({
        clientId: 'client',
        batchSequence: 1,
        mutations: [createSpaceAct(1)],
      }),
    });
    expect(decodeWire(upload)).toMatchObject({ requiredSyncId: 1 });
    expect(fixture_.storage.ledgerTransaction).toBe(fixture_.transactions.tx);

    const requestBytes = encode({
      clientId: 'client',
      scope: `${UserScope}:${viewerId}`,
      fromCursor: 0,
    });
    const pulled = await fixture_.backend.pullDownlink({ principal, requestBytes });
    expect(decodeWire(pulled.bytes)).toMatchObject({
      fromCursor: 0,
      toCursor: 1,
    });

    const controller = new AbortController();
    const stream = fixture_.backend.subscribeDownlink({
      principal,
      requestBytes,
      signal: controller.signal,
    });
    expect(decodeWire((await stream.next()).value!.bytes)).toMatchObject({
      toCursor: 1,
    });
    controller.abort();
    expect(fixture_.calls).toEqual(['create', 'read', 'read']);
  });

  it('validates options and subscription signals synchronously', () => {
    const fixture_ = fixture();
    // Registering no loader at all is legal — it is a Backend that publishes
    // nothing (CAP-488). Naming one the contract does not is not.
    expect(() =>
      createLocalSyncBackend({
        scopeAuthorizer: { canRead: async () => true },
        principalScope: ({ userId }) => `${UserScope}:${userId}`,
        contract: contract(),
        models: { notAModel: {} },
        persistence: {
          storage: fixture_.storage,
          transactions: fixture_.transactions,
          committedChanges: fixture_.changes,
        },
      }),
    ).toThrow(LocalSyncBackendOptionsError);
    expect(() =>
      fixture_.backend.subscribeDownlink({
        principal: { userId: viewerId },
        requestBytes: encode({
          clientId: 'client',
          scope: `${UserScope}:${viewerId}`,
          fromCursor: 0,
        }),
        signal: undefined as never,
      }),
    ).toThrow('AbortSignal');
  });

  it('closes live subscriptions and committed changes exactly once', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    const stream = fixture_.backend.subscribeDownlink({
      principal: { userId: viewerId },
      requestBytes: encode({
        clientId: 'client',
        scope: `${UserScope}:${viewerId}`,
        fromCursor: 0,
      }),
      signal: controller.signal,
    });
    const waiting = stream.next();
    await Promise.resolve();

    await Promise.all([fixture_.backend.close(), fixture_.backend.close()]);

    await expect(waiting).resolves.toMatchObject({ done: true });
    expect(fixture_.changes.cleanupCount).toBe(1);
    expect(fixture_.changes.closeCount).toBe(1);
    await expect(fixture_.backend.close()).resolves.toBeUndefined();
    expect(fixture_.changes.closeCount).toBe(1);
  });
});
