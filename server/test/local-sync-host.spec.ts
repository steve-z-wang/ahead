import { WebSocket } from 'ws';

import { LocalSyncHost } from '../src';
import {
  CreateSpaceResolver,
  PersistenceStorage,
  SpaceIdentity,
  SpaceState,
  Transactions,
  Tx,
  contract,
  createSpaceAct,
  decodeWire,
  descriptor,
  id,
  mutationContract,
} from './support/space-backend';
import type { BackendModelBinding, LocalSyncFailureObserver } from '../src';

const viewer = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const other = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const userScope = (id: string) => `User:${id}`;
const bookScope = (id: string) => `Book:${id}`;

function pullBody(scopeId = viewer) {
  return {
    clientId: 'client',
    scope: userScope(scopeId),
    fromCursor: 0,
  };
}

/// The real thing a live channel needs: a commit tells the viewer's waiters.
class Waking {
  private readonly waiters = new Map<string, Set<() => void>>();
  closeCount = 0;

  subscribe(scope: string, wake: () => void, signal: AbortSignal): void {
    const group = this.waiters.get(scope) ?? new Set<() => void>();
    group.add(wake);
    this.waiters.set(scope, group);
    signal.addEventListener('abort', () => group.delete(wake), { once: true });
  }

  commit(scope: string): void {
    for (const wake of this.waiters.get(scope) ?? []) wake();
  }

  get listenerCount(): number {
    return [...this.waiters.values()].reduce(
      (sum, group) => sum + group.size,
      0,
    );
  }

  async close(): Promise<void> {
    this.closeCount += 1;
  }
}

function batch(overrides: Record<string, unknown> = {}): unknown {
  return {
    clientId: 'client',
    batchSequence: 1,
    mutations: [createSpaceAct(1)],
    ...overrides,
  };
}

interface FixtureOptions {
  readonly heartbeatMillis?: number;
  readonly canRead?: (viewerUserId: string, scope: string) => Promise<boolean>;
  readonly pullFailure?: unknown;
  readonly mutationFailure?: unknown;
  readonly authenticationFailure?: unknown;
  readonly failureObserver?: LocalSyncFailureObserver;
}

function fixture(options: FixtureOptions = {}) {
  const storage = new PersistenceStorage();
  const transactions = new Transactions();
  const changes = new Waking();
  const calls: string[] = [];
  let host: LocalSyncHost<Tx>;
  const binding: BackendModelBinding<Tx, SpaceIdentity, SpaceState> = {
    read: {
      forViewer: async (_context, identities) => {
        if (options.pullFailure !== undefined) throw options.pullFailure;
        return identities.map((identity) => ({
          ...identity,
          title: 'visible',
          position: 7,
        }));
      },
    },
  };
  const createSpace: CreateSpaceResolver = async (context, arguments_) => {
    if (options.mutationFailure !== undefined) throw options.mutationFailure;
    calls.push('create');
    await host.scopeLedger.invalidate(context.transaction, {
      model: descriptor,
      identity: arguments_.space.identity,
      scopes: [userScope(context.actorUserId)],
    });
    // The storage adapter tells its waiters on commit; this fixture's
    // transaction is the call itself, so it says so here.
    changes.commit(userScope(context.actorUserId));
  };

  const tokens = new Map<string, string>([
    ['viewer-token', viewer],
    ['other-token', other],
  ]);
  const presence: ['connected' | 'disconnected', string][] = [];
  host = new LocalSyncHost<Tx>({
    heartbeatMillis: options.heartbeatMillis,
    contract: contract(),
    models: { space: binding },
    mutationContract: mutationContract(),
    mutations: { createSpace: { v1: createSpace } },
    persistence: { storage, transactions, committedChanges: changes },
    scopeAuthorizer: {
      canRead: async ({ viewerUserId }, scope) =>
        options.canRead?.(viewerUserId, scope) ??
        scope === userScope(viewerUserId),
    },
    principalScope: ({ userId }) => userScope(userId),
    authentication: {
      authenticate: async ({ token }) => {
        if (options.authenticationFailure !== undefined) {
          throw options.authenticationFailure;
        }
        const userId = token === undefined ? undefined : tokens.get(token);
        return userId === undefined ? null : { userId };
      },
    },
    minBuild: 100,
    failureObserver: options.failureObserver,
    presence: {
      onConnected: (userId) => presence.push(['connected', userId]),
      onDisconnected: (userId) => presence.push(['disconnected', userId]),
    },
  });
  return { host, storage, transactions, calls, changes, presence };
}

/** The socket's own lifecycle events land before the host's bookkeeping does. */
async function waitFor(done: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100 && !done(); attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe('LocalSyncHost', () => {
  let world: ReturnType<typeof fixture>;
  let base: string;

  beforeEach(async () => {
    world = fixture();
    const port = await world.host.listen(0, '127.0.0.1');
    base = `http://127.0.0.1:${port}`;
  });

  afterEach(async () => world.host.close());

  async function post(
    path: string,
    body: unknown,
    token: string | null = 'viewer-token',
  ): Promise<{ status: number; body: unknown }> {
    const response = await fetch(`${base}${path}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(token === null ? {} : { authorization: `Bearer ${token}` }),
      },
      body: JSON.stringify(body),
    });
    const text = await response.text();
    return {
      status: response.status,
      body: text.length === 0 ? undefined : JSON.parse(text),
    };
  }

  it('preserves the whole batch when a mutation version is unsupported', async () => {
    const answer = await post(
      '/sync/mutations',
      batch({
        mutations: [
          createSpaceAct(1),
          { ...(createSpaceAct(2) as Record<string, unknown>), version: 2 },
        ],
      }),
    );
    expect(answer).toEqual({
      status: 409,
      body: {
        code: 'mutation_version_unsupported',
        ordinal: 2,
        name: 'CreateSpace',
        version: 2,
      },
    });
    expect(world.calls).toEqual([]);
    // The failed attempt consumed neither the sequence nor a receipt.
    expect((await post('/sync/mutations', batch())).status).toBe(200);
    expect(world.calls).toEqual(['create']);
  });

  async function restart(options: FixtureOptions): Promise<void> {
    await world.host.close();
    world = fixture(options);
    const port = await world.host.listen(0, '127.0.0.1');
    base = `http://127.0.0.1:${port}`;
  }

  describe('the two request routes', () => {
    it('applies a batch and answers positionally', async () => {
      const answer = await post('/sync/mutations', batch());

      expect(answer.status).toBe(200);
      expect(answer.body).toMatchObject({ requiredSyncId: 1, rejections: [] });
      expect(world.calls).toEqual(['create']);
    });

    it('answers a rejection in place rather than failing the batch', async () => {
      await post('/sync/mutations', batch());
      const conflicting = await post(
        '/sync/mutations',
        // A required field the envelope never carried.
        batch({ batchSequence: 2, mutations: [createSpaceAct(1, { id }, {})] }),
      );

      expect(conflicting.status).toBe(200);
      expect(conflicting.body).toMatchObject({
        rejections: [{ ordinal: 1, code: 'mutation.invalid' }],
      });
    });

    it('serves a page from the pull route', async () => {
      await post('/sync/mutations', batch());

      const page = await post('/sync/pull', pullBody());

      expect(page.status).toBe(200);
      expect(page.body).toMatchObject({ fromCursor: 0, toCursor: 1 });
      const changes = (page.body as { changes: { state: unknown }[] }).changes;
      expect(changes).toHaveLength(1);
      // An Int rides as a JSON number. A bigint here would fail to serialize
      // and the client would loop on this page forever.
      expect(changes[0].state).toMatchObject({ position: 7 });
    });

    it('observes an unexpected pull failure once before returning a safe 500', async () => {
      const failure = new Error('loader exposed private detail');
      const onUnexpectedFailure = jest.fn();
      await restart({
        pullFailure: failure,
        failureObserver: { onUnexpectedFailure },
      });
      await post('/sync/mutations', batch());
      expect(onUnexpectedFailure).not.toHaveBeenCalled();

      const answer = await post('/sync/pull', pullBody());

      expect(answer).toEqual({ status: 500, body: { code: 'server' } });
      expect(JSON.stringify(answer)).not.toContain('private detail');
      expect(onUnexpectedFailure).toHaveBeenCalledTimes(1);
      expect(onUnexpectedFailure).toHaveBeenCalledWith({
        error: failure,
        route: 'pull',
        principal: { userId: viewer },
      });
    });

    it('observes an unexpected mutation failure once before returning a safe 500', async () => {
      const failure = new Error('database constraint detail');
      const onUnexpectedFailure = jest.fn();
      await restart({
        mutationFailure: failure,
        failureObserver: { onUnexpectedFailure },
      });

      const answer = await post('/sync/mutations', batch());

      expect(answer).toEqual({ status: 500, body: { code: 'server' } });
      expect(JSON.stringify(answer)).not.toContain('constraint detail');
      expect(onUnexpectedFailure).toHaveBeenCalledTimes(1);
      expect(onUnexpectedFailure).toHaveBeenCalledWith({
        error: failure,
        route: 'mutations',
        principal: { userId: viewer },
      });
    });

    it('does not observe protocol or domain refusals', async () => {
      const onUnexpectedFailure = jest.fn();
      await restart({ failureObserver: { onUnexpectedFailure } });

      const malformed = await post('/sync/mutations', { nonsense: true });
      const gap = await post('/sync/mutations', batch({ batchSequence: 5 }));
      const forbidden = await post('/sync/pull', pullBody(other));

      expect(malformed.status).toBe(400);
      expect(gap.status).toBe(409);
      expect(forbidden.status).toBe(403);
      expect(onUnexpectedFailure).not.toHaveBeenCalled();
    });

    it('keeps the safe 500 when the failure observer itself throws', async () => {
      await restart({
        mutationFailure: new Error('database unavailable'),
        failureObserver: {
          onUnexpectedFailure: () => {
            throw new Error('reporting unavailable');
          },
        },
      });

      await expect(post('/sync/mutations', batch())).resolves.toEqual({
        status: 500,
        body: { code: 'server' },
      });
    });

    it('distinguishes malformed scopes from scopes the principal cannot read', async () => {
      const malformed = await post('/sync/pull', {
        clientId: 'client',
        scope: { model: 'Book', id: viewer },
        fromCursor: 0,
      });
      const forbidden = await post('/sync/pull', pullBody(other));

      expect(malformed).toMatchObject({ status: 400 });
      expect(forbidden).toMatchObject({
        status: 403,
        body: { code: 'scope.forbidden' },
      });
    });

    it('refuses a caller it cannot name, before anything is applied', async () => {
      const answer = await post('/sync/mutations', batch(), null);

      expect(answer.status).toBe(401);
      expect(world.calls).toEqual([]);
    });

    it('does not observe an authentication rejection', async () => {
      const onUnexpectedFailure = jest.fn();
      await restart({ failureObserver: { onUnexpectedFailure } });

      const answer = await post('/sync/pull', pullBody(), null);

      expect(answer).toEqual({ status: 401, body: { code: 'unauthorized' } });
      expect(onUnexpectedFailure).not.toHaveBeenCalled();
    });

    it('observes an authentication failure once before returning a safe 500', async () => {
      const failure = new Error('Firebase service account detail');
      const onUnexpectedFailure = jest.fn();
      await restart({
        authenticationFailure: failure,
        failureObserver: { onUnexpectedFailure },
      });

      const answer = await post('/sync/pull', pullBody());

      expect(answer).toEqual({ status: 500, body: { code: 'server' } });
      expect(JSON.stringify(answer)).not.toContain('service account');
      expect(onUnexpectedFailure).toHaveBeenCalledTimes(1);
      expect(onUnexpectedFailure).toHaveBeenCalledWith({
        error: failure,
        route: 'pull',
      });
    });

    // A malformed neighbour must not take the batch down with it: the Dart
    // side reads 400 as terminal, so a poisoned frozen batch would wedge the
    // worker on every restart forever.
    it('rejects one bad mutation in place and lands the rest', async () => {
      const answer = await post(
        '/sync/mutations',
        batch({
          mutations: [
            createSpaceAct(1, { id }, { title: 'first', position: 1 }),
            { ordinal: 2, name: 'Nonsense', operations: [] },
            createSpaceAct(
              3,
              { id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
              { title: 'third', position: 3 },
            ),
          ],
        }),
      );

      expect(answer.status).toBe(200);
      expect(answer.body).toMatchObject({
        rejections: [{ ordinal: 2, code: 'mutation.invalid' }],
      });
      expect(world.calls).toEqual(['create', 'create']);
    });

    // JSON spells absence two ways and both mean the same thing about the row.
    it('reads an explicit null for a nullable field on create', async () => {
      const answer = await post(
        '/sync/mutations',
        batch({
          mutations: [
            createSpaceAct(
              1,
              { id },
              {
                title: 'new',
                position: 3,
                nickname: null,
              },
            ),
          ],
        }),
      );

      expect(answer.body).toMatchObject({ rejections: [] });
    });

    // §2 runs in both directions: a client one schema version ahead may name a
    // field this server has never heard of, and that is not a refusal.
    it('ignores a value key it does not know', async () => {
      const answer = await post(
        '/sync/mutations',
        batch({
          mutations: [
            createSpaceAct(
              1,
              { id },
              {
                title: 'new',
                position: 3,
                tomorrowsField: 'ignored',
              },
            ),
          ],
        }),
      );

      expect(answer.status).toBe(200);
      expect(answer.body).toMatchObject({ rejections: [] });
      expect(world.calls).toEqual(['create']);
    });

    // Handing "Basic …" to Firebase would ask it about a credential this
    // protocol never accepts.
    it.each(['Basic dXNlcjpwYXNz', 'viewer-token', 'Bearer   '])(
      'refuses a non-Bearer authorization: %s',
      async (header) => {
        const response = await fetch(`${base}/sync/pull`, {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            authorization: header,
          },
          body: JSON.stringify(pullBody()),
        });

        expect(response.status).toBe(401);
      },
    );

    it('refuses a body that is not the envelope, and applies nothing', async () => {
      const answer = await post('/sync/mutations', { nonsense: true });

      expect(answer.status).toBe(400);
      expect(world.calls).toEqual([]);
    });

    it('names a sequence gap as a conflict', async () => {
      const answer = await post('/sync/mutations', batch({ batchSequence: 5 }));

      expect(answer.status).toBe(409);
      expect(answer.body).toMatchObject({ code: 'gap' });
    });

    it('serves nothing but its three routes', async () => {
      const wrongPath = await fetch(`${base}/anything`, { method: 'POST' });
      const wrongMethod = await fetch(`${base}/sync/pull`);

      expect(wrongPath.status).toBe(404);
      expect(wrongMethod.status).toBe(405);
    });
  });

  // The channel's death in production (CAP-447): proxies cut a connection
  // that carries no frames for ~2 minutes, and the phone's own ping stops
  // the moment iOS suspends the app — so longevity must not depend on the
  // client being awake. The HOST pings; a socket that stops answering is
  // reaped rather than left half-open.
  describe('the heartbeat', () => {
    let fast: ReturnType<typeof fixture>;
    let fastBase: string;

    beforeEach(async () => {
      fast = fixture({ heartbeatMillis: 25 });
      const port = await fast.host.listen(0, '127.0.0.1');
      fastBase = `ws://127.0.0.1:${port}/sync/live`;
    });

    afterEach(async () => {
      await fast.host.close();
    });

    function openFast(
      options: { autoPong?: boolean } = {},
    ): Promise<WebSocket> {
      // `autoPong` exists at runtime since ws 8.17; the bundled typings lag.
      const socket = new WebSocket(fastBase, {
        headers: { authorization: 'Bearer viewer-token' },
        autoPong: options.autoPong ?? true,
      } as import('ws').ClientOptions);
      return new Promise((resolve, reject) => {
        socket.once('open', () => resolve(socket));
        socket.once('error', reject);
      });
    }

    it('pings an idle socket on the interval; an answering socket lives on', async () => {
      const socket = await openFast();
      let pings = 0;
      socket.on('ping', () => (pings += 1));

      await waitFor(() => pings >= 3);

      expect(pings).toBeGreaterThanOrEqual(3);
      expect(socket.readyState).toBe(socket.OPEN);
      socket.close();
    });

    it('reaps a socket whose pongs stop coming', async () => {
      const socket = await openFast({ autoPong: false });
      let closed = false;
      socket.on('close', () => (closed = true));

      await waitFor(() => closed);

      expect(closed).toBe(true);
    });

    it('a reaped socket releases its presence', async () => {
      const socket = await openFast({ autoPong: false });
      let closed = false;
      socket.on('close', () => (closed = true));
      await waitFor(() => closed);

      await waitFor(() =>
        fast.presence.some(([kind]) => kind === 'disconnected'),
      );
      expect(fast.presence).toContainEqual(['disconnected', viewer]);
    });
  });

  describe('the live channel', () => {
    function openRaw(token = 'viewer-token', query = ''): Promise<WebSocket> {
      const socket = new WebSocket(
        `ws://127.0.0.1:${new URL(base).port}/sync/live${query}`,
        {
          headers: { authorization: `Bearer ${token}` },
        },
      );
      return new Promise((resolve, reject) => {
        socket.once('open', () => resolve(socket));
        socket.once('error', reject);
        socket.once('unexpected-response', (_request, response) =>
          reject(new Error(String(response.statusCode))),
        );
      });
    }

    async function subscribe(
      socket: WebSocket,
      scopes: readonly string[],
    ): Promise<unknown> {
      const answer = nextPage(socket);
      socket.send(JSON.stringify({ type: 'subscribe', scopes }));
      return answer;
    }

    async function open(
      token = 'viewer-token',
      query = '',
    ): Promise<WebSocket> {
      const socket = await openRaw(token, query);
      const scopeId = token === 'other-token' ? other : viewer;
      await subscribe(socket, [userScope(scopeId)]);
      return socket;
    }

    function nextPage(socket: WebSocket): Promise<unknown> {
      return new Promise((resolve) => {
        socket.once('message', (data: Buffer) =>
          resolve(decodeWire(Uint8Array.from(data))),
        );
      });
    }

    it('waits for one opaque subscribe set and acknowledges it before pages', async () => {
      await post('/sync/mutations', batch());
      const socket = await openRaw();
      const heard: unknown[] = [];
      socket.on('message', (data: Buffer) =>
        heard.push(decodeWire(Uint8Array.from(data))),
      );
      await new Promise((resolve) => setTimeout(resolve, 30));
      expect(heard).toEqual([]);

      const ack = await subscribe(socket, [
        userScope(viewer),
        userScope(viewer),
      ]);
      expect(ack).toEqual({
        type: 'subscribed',
        scopes: [userScope(viewer)],
        rejections: [],
      });
      await new Promise((resolve) => setTimeout(resolve, 30));
      expect(heard).toEqual([ack]);
      socket.close();
    });

    it.each([
      ['malformed', '{'],
      [
        'retired structured scope',
        JSON.stringify({
          type: 'subscribe',
          scopes: [{ model: 'Book', id: viewer }],
        }),
      ],
    ])(
      'closes a %s handshake without acknowledging it',
      async (_label, frame) => {
        const socket = await openRaw();
        let acknowledged = false;
        socket.on('message', () => (acknowledged = true));
        const closed = new Promise<number>((resolve) =>
          socket.once('close', (code) => resolve(code)),
        );
        socket.send(frame);

        await expect(closed).resolves.toBeGreaterThan(0);
        expect(acknowledged).toBe(false);
      },
    );

    it('isolates a rejected scope while the accepted scope stays live', async () => {
      await world.host.close();
      world = fixture({
        canRead: async (_viewerUserId, scope) => scope.startsWith('User:'),
      });
      const port = await world.host.listen(0, '127.0.0.1');
      base = `http://127.0.0.1:${port}`;
      const socket = await openRaw();
      const ack = await subscribe(socket, [
        userScope(viewer),
        bookScope(other),
      ]);

      expect(ack).toEqual({
        type: 'subscribed',
        scopes: [userScope(viewer)],
        rejections: [
          {
            scope: bookScope(other),
            code: 'scope.forbidden',
          },
        ],
      });
      expect(socket.readyState).toBe(socket.OPEN);
      expect(world.storage.headReads).toEqual([userScope(viewer)]);
      expect(world.changes.listenerCount).toBe(1);

      await world.host.scopeLedger.invalidate(world.transactions.tx, {
        model: descriptor,
        identity: { id },
        scopes: [userScope(viewer)],
      });
      const page = nextPage(socket);
      world.changes.commit(userScope(viewer));
      await expect(page).resolves.toMatchObject({
        scope: userScope(viewer),
      });

      const closed = new Promise<number>((resolve) =>
        socket.once('close', (code) => resolve(code)),
      );
      socket.send(JSON.stringify({ type: 'subscribe', scopes: [] }));
      await expect(closed).resolves.toBe(1002);
    });

    it('observes an unexpected live failure once before closing 1011', async () => {
      const failure = new Error('authorization storage unavailable');
      const onUnexpectedFailure = jest.fn();
      await restart({
        canRead: async () => {
          throw failure;
        },
        failureObserver: { onUnexpectedFailure },
      });
      const socket = await openRaw();
      const closed = new Promise<number>((resolve) =>
        socket.once('close', (code) => resolve(code)),
      );

      socket.send(
        JSON.stringify({ type: 'subscribe', scopes: [userScope(viewer)] }),
      );

      await expect(closed).resolves.toBe(1011);
      expect(onUnexpectedFailure).toHaveBeenCalledTimes(1);
      expect(onUnexpectedFailure).toHaveBeenCalledWith({
        error: failure,
        route: 'live',
        principal: { userId: viewer },
      });
    });

    it('does not observe a malformed live handshake or normal close', async () => {
      const onUnexpectedFailure = jest.fn();
      await restart({ failureObserver: { onUnexpectedFailure } });
      const malformed = await openRaw();
      const malformedClosed = new Promise<number>((resolve) =>
        malformed.once('close', (code) => resolve(code)),
      );

      malformed.send('{');

      await expect(malformedClosed).resolves.toBe(1002);
      const normal = await open();
      const normalClosed = new Promise<void>((resolve) =>
        normal.once('close', () => resolve()),
      );
      normal.close();
      await normalClosed;
      expect(onUnexpectedFailure).not.toHaveBeenCalled();
    });

    it('acknowledges an all-rejected set and keeps the socket idle', async () => {
      await world.host.close();
      world = fixture({
        canRead: async () => false,
      });
      const port = await world.host.listen(0, '127.0.0.1');
      base = `http://127.0.0.1:${port}`;
      const socket = await openRaw();

      const ack = await subscribe(socket, [bookScope(other)]);

      expect(ack).toEqual({
        type: 'subscribed',
        scopes: [],
        rejections: [
          {
            scope: bookScope(other),
            code: 'scope.forbidden',
          },
        ],
      });
      await new Promise((resolve) => setTimeout(resolve, 30));
      expect(socket.readyState).toBe(socket.OPEN);
      expect(world.storage.headReads).toEqual([]);
      expect(world.changes.listenerCount).toBe(0);
      socket.close();
    });

    it('multiplexes independent scope pages and removes every listener on close', async () => {
      await world.host.close();
      world = fixture({
        canRead: async () => true,
      });
      const port = await world.host.listen(0, '127.0.0.1');
      base = `http://127.0.0.1:${port}`;
      const socket = await openRaw();
      const bookId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      await subscribe(socket, [userScope(viewer), bookScope(bookId)]);
      expect(world.changes.listenerCount).toBe(2);

      await world.host.scopeLedger.invalidate(world.transactions.tx, {
        model: descriptor,
        identity: { id },
        scopes: [userScope(viewer), bookScope(bookId)],
      });
      const delivered: unknown[] = [];
      socket.on('message', (data: Buffer) =>
        delivered.push(decodeWire(Uint8Array.from(data))),
      );
      world.changes.commit(userScope(viewer));
      world.changes.commit(bookScope(bookId));
      await waitFor(() => delivered.length === 2);
      expect(
        delivered.map((page) => (page as { scope: unknown }).scope),
      ).toEqual(expect.arrayContaining([userScope(viewer), bookScope(bookId)]));

      const closed = new Promise((resolve) => socket.once('close', resolve));
      socket.close();
      await closed;
      await waitFor(() => world.changes.listenerCount === 0);
      expect(world.changes.listenerCount).toBe(0);
    });

    it('pushes a committed page to the viewer, on every socket they hold', async () => {
      const first = await open();
      const second = await open();
      const pages = Promise.all([nextPage(first), nextPage(second)]);

      await post('/sync/mutations', batch());
      const [left, right] = await pages;

      expect(left).toMatchObject({ toCursor: 1 });
      expect(right).toMatchObject({ toCursor: 1 });
      first.close();
      second.close();
    });

    // A socket subscribing from zero would replay everything the viewer has
    // ever seen, and the client would drop all of it on the cursor check.
    it('pushes nothing that predates the connection', async () => {
      await post('/sync/mutations', batch());

      const socket = await open();
      let heard = false;
      socket.on('message', () => {
        heard = true;
      });
      await new Promise((resolve) => setTimeout(resolve, 150));

      expect(heard).toBe(false);
      socket.close();
    });

    it('pushes exactly one page for a change made after connecting', async () => {
      await post('/sync/mutations', batch());
      const socket = await open();
      const pages: unknown[] = [];
      socket.on('message', (data: Buffer) =>
        pages.push(decodeWire(Uint8Array.from(data))),
      );

      await post(
        '/sync/mutations',
        batch({
          batchSequence: 2,
          mutations: [
            createSpaceAct(
              1,
              { id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
              { title: 'later', position: 9 },
            ),
          ],
        }),
      );
      await new Promise((resolve) => setTimeout(resolve, 150));

      expect(pages).toHaveLength(1);
      socket.close();
    });

    it('says nothing to anyone else', async () => {
      const stranger = await open('other-token');
      let heard = false;
      stranger.on('message', () => {
        heard = true;
      });

      await post('/sync/mutations', batch());
      await new Promise((resolve) => setTimeout(resolve, 100));

      expect(heard).toBe(false);
      stranger.close();
    });

    it('refuses a socket it cannot name', async () => {
      await expect(open('nonsense')).rejects.toThrow('401');
    });

    it('does not observe a rejected live credential', async () => {
      const onUnexpectedFailure = jest.fn();
      await restart({ failureObserver: { onUnexpectedFailure } });

      await expect(open('nonsense')).rejects.toThrow('401');
      expect(onUnexpectedFailure).not.toHaveBeenCalled();
    });

    it('observes a live authentication failure once before refusing 500', async () => {
      const failure = new Error('Firebase public-key fetch failed');
      const onUnexpectedFailure = jest.fn();
      await restart({
        authenticationFailure: failure,
        failureObserver: { onUnexpectedFailure },
      });

      await expect(openRaw()).rejects.toThrow('500');
      expect(onUnexpectedFailure).toHaveBeenCalledTimes(1);
      expect(onUnexpectedFailure).toHaveBeenCalledWith({
        error: failure,
        route: 'live',
      });
    });

    it('refuses a build below the floor', async () => {
      await expect(open('viewer-token', '?build=50')).rejects.toThrow('426');
    });

    it('lets a build at or above the floor through', async () => {
      const socket = await open('viewer-token', '?build=100');

      expect(socket.readyState).toBe(socket.OPEN);
      socket.close();
    });

    it('names the viewer to presence for as long as the socket is open', async () => {
      const socket = await open();
      await waitFor(() => world.presence.length === 1);

      expect(world.presence).toEqual([['connected', viewer]]);

      const closed = new Promise((resolve) => socket.once('close', resolve));
      socket.close();
      await closed;
      await waitFor(() => world.presence.length === 2);

      expect(world.presence).toEqual([
        ['connected', viewer],
        ['disconnected', viewer],
      ]);
    });

    // Two sockets are two announcements: the host counts sockets, and what a
    // second one means to a person is the product's to decide.
    it('names one arrival and one departure per socket', async () => {
      const first = await open();
      const second = await open();
      await waitFor(() => world.presence.length === 2);

      const closed = new Promise((resolve) => first.once('close', resolve));
      first.close();
      await closed;
      await waitFor(() => world.presence.length === 3);

      expect(world.presence).toEqual([
        ['connected', viewer],
        ['connected', viewer],
        ['disconnected', viewer],
      ]);
      second.close();
    });

    it('says a refused socket never arrived', async () => {
      await expect(open('nonsense')).rejects.toThrow('401');
      await new Promise((resolve) => setTimeout(resolve, 100));

      expect(world.presence).toEqual([]);
    });

    it('closes every live socket when the host does', async () => {
      const socket = await open();
      const closed = new Promise((resolve) => socket.once('close', resolve));

      await world.host.close();

      await expect(closed).resolves.toBeDefined();
    });
  });
});
