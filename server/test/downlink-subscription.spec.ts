import {
  CommittedChanges,
  DownlinkMaterializer,
  DownlinkPage,
  GeneratedBackendContract,
  createDownlinkSubscriptions,
} from '../src';

const viewer = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function encodeWire(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

function decodeWire(bytes: Uint8Array): unknown {
  return JSON.parse(Buffer.from(bytes).toString('utf8'));
}

function contract(): GeneratedBackendContract {
  return {
    enumValues: {},
    models: {},
  };
}

class Changes implements CommittedChanges {
  readonly events: string[] = [];
  closeCount = 0;
  cleanupCount = 0;
  failSubscribe: Error | null = null;
  onSubscribe: (() => void) | null = null;
  private readonly listeners = new Map<
    string,
    Set<{ wake: () => void; signal: AbortSignal }>
  >();

  subscribe(scope: string, wake: () => void, signal: AbortSignal): void {
    const viewerId = scope;
    this.events.push(`subscribe:${viewerId}`);
    if (this.failSubscribe !== null) throw this.failSubscribe;
    const entry = { wake, signal };
    const listeners = this.listeners.get(viewerId) ?? new Set();
    listeners.add(entry);
    this.listeners.set(viewerId, listeners);
    let cleaned = false;
    signal.addEventListener(
      'abort',
      () => {
        if (cleaned) return;
        cleaned = true;
        this.cleanupCount += 1;
        listeners.delete(entry);
      },
      { once: true },
    );
    this.onSubscribe?.();
  }

  hint(viewerId: string): void {
    for (const listener of this.listeners.get(viewerId) ?? []) listener.wake();
  }

  reconnect(): void {
    for (const listeners of this.listeners.values()) {
      for (const listener of listeners) listener.wake();
    }
  }

  async close(): Promise<void> {
    this.closeCount += 1;
  }
}

class DurableMaterializer implements DownlinkMaterializer {
  head = 0n;
  pullCount = 0;
  failure: Error | null = null;
  onPull: ((after: bigint) => void) | null = null;
  readonly events: string[];

  constructor(events: string[]) {
    this.events = events;
  }

  async pull(input: { principal: { userId: string }; requestBytes: Uint8Array }) {
    this.pullCount += 1;
    const request = decodeWire(input.requestBytes) as {
      clientId: string;
      scope: string;
      fromCursor: number;
    };
    const afterSyncId = BigInt(request.fromCursor);
    this.events.push(`pull:${input.principal.userId}:${afterSyncId}`);
    if (this.failure !== null) throw this.failure;
    const observedHead = this.head;
    this.onPull?.(afterSyncId);
    const identity = { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' };
    const carried =
      observedHead > afterSyncId
        ? [
            {
              syncId: Number(observedHead),
              model: 'Space',
              identity,
              state: null,
            },
          ]
        : [];
    return {
      bytes: encodeWire({
        scope: request.scope,
        fromCursor: Number(afterSyncId),
        toCursor: Number(observedHead),
        changes: carried,
      }),
    };
  }
}

function fixture() {
  const changes = new Changes();
  const materializer = new DurableMaterializer(changes.events);
  const subscriptions = createDownlinkSubscriptions({
    contract: contract(),
    materializer,
    committedChanges: changes,
  });
  return { changes, materializer, subscriptions };
}

function subscribe(
  fixture_: ReturnType<typeof fixture>,
  signal: AbortSignal,
  afterSyncId = 0n,
  viewerId = viewer,
) {
  return fixture_.subscriptions.subscribe({
    principal: { userId: viewerId },
    requestBytes: encodeWire({
      clientId: 'client',
      scope: viewerId,
      fromCursor: Number(afterSyncId),
    }),
    signal,
  });
}

function page(result: IteratorResult<DownlinkPage>) {
  expect(result.done).toBe(false);
  return decodeWire(result.value!.bytes) as {
    fromCursor: number;
    toCursor: number;
    changes: readonly unknown[];
  };
}

async function turn(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

describe('Downlink subscription race repair', () => {
  it('can register the live listener without pulling before the handshake ack', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    let listening = false;
    const generator = fixture_.subscriptions.subscribe({
      principal: { userId: viewer },
      requestBytes: encodeWire({
        clientId: 'live',
        scope: viewer,
        fromCursor: 0,
      }),
      signal: controller.signal,
      onListening: () => {
        listening = true;
      },
      waitForCommit: true,
    });
    const next = generator.next();
    await turn();

    expect(listening).toBe(true);
    expect(fixture_.materializer.pullCount).toBe(0);
    fixture_.materializer.head = 1n;
    fixture_.changes.hint(viewer);
    await expect(next).resolves.toMatchObject({ done: false });
    controller.abort();
  });

  it('registers first and catches a commit between registration and durable read', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    fixture_.changes.onSubscribe = () => {
      fixture_.materializer.head = 1n;
    };

    const generator = subscribe(fixture_, controller.signal);
    const first = page(await generator.next());

    expect(first.toCursor).toBe(1);
    expect(fixture_.changes.events).toEqual([
      `subscribe:${viewer}`,
      `pull:${viewer}:0`,
    ]);
    controller.abort();
    await expect(generator.next()).resolves.toMatchObject({ done: true });
  });

  it('does a durable reread when a commit happens during materialization', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    fixture_.materializer.head = 1n;
    fixture_.materializer.onPull = () => {
      fixture_.materializer.onPull = null;
      fixture_.materializer.head = 2n;
      fixture_.changes.hint(viewer);
    };

    const generator = subscribe(fixture_, controller.signal);
    expect(page(await generator.next()).toCursor).toBe(1);
    expect(page(await generator.next()).toCursor).toBe(2);
    expect(fixture_.materializer.pullCount).toBe(2);
    controller.abort();
  });

  it('coalesces duplicate hints while the consumer is paused', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    fixture_.materializer.head = 1n;
    const generator = subscribe(fixture_, controller.signal);
    await generator.next();

    fixture_.materializer.head = 2n;
    fixture_.changes.hint(viewer);
    fixture_.changes.hint(viewer);
    fixture_.changes.hint(viewer);
    expect(fixture_.materializer.pullCount).toBe(1);

    expect(page(await generator.next()).toCursor).toBe(2);
    expect(fixture_.materializer.pullCount).toBe(2);
    controller.abort();
  });

  it('repairs a lost hint on the next viewer hint or source reconnect epoch', async () => {
    for (const wake of ['hint', 'reconnect'] as const) {
      const fixture_ = fixture();
      const controller = new AbortController();
      fixture_.materializer.head = 1n;
      const generator = subscribe(fixture_, controller.signal);
      await generator.next();
      const waiting = generator.next();
      await turn();

      fixture_.materializer.head = 2n;
      fixture_.changes.hint('other');
      await turn();
      expect(fixture_.materializer.pullCount).toBe(1);

      fixture_.materializer.head = 3n;
      if (wake === 'hint') fixture_.changes.hint(viewer);
      else fixture_.changes.reconnect();
      expect(page(await waiting).toCursor).toBe(3);
      controller.abort();
    }
  });

  it('a direct pull repairs the same durable gap after a client reconnect', async () => {
    const fixture_ = fixture();
    fixture_.materializer.head = 4n;

    const repaired = await fixture_.materializer.pull({
      principal: { userId: viewer },
      requestBytes: encodeWire({
        clientId: 'client',
        scope: viewer,
        fromCursor: 1,
      }),
    });

    expect((decodeWire(repaired.bytes) as { toCursor: number }).toCursor).toBe(
      4,
    );
  });
});

describe('Downlink subscription lifecycle and backpressure', () => {
  it('finishes without registering when already aborted', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    controller.abort();

    const generator = subscribe(fixture_, controller.signal);

    await expect(generator.next()).resolves.toEqual({ done: true, value: undefined });
    expect(fixture_.changes.events).toEqual([]);
    expect(fixture_.changes.cleanupCount).toBe(0);
  });

  it('aborts after a page and cleans its listener exactly once', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    fixture_.materializer.head = 1n;
    const generator = subscribe(fixture_, controller.signal);
    await generator.next();

    controller.abort();
    expect(fixture_.changes.cleanupCount).toBe(1);
    await expect(generator.next()).resolves.toMatchObject({ done: true });
    await generator.return(undefined);
    controller.abort();
    expect(fixture_.changes.cleanupCount).toBe(1);
  });

  it('keeps one pending wake while a consumer is paused', async () => {
    const fixture_ = fixture();
    const controller = new AbortController();
    fixture_.materializer.head = 1n;
    const generator = subscribe(fixture_, controller.signal);
    await generator.next();

    fixture_.materializer.head = 9n;
    for (let index = 0; index < 1_000; index += 1) {
      fixture_.changes.hint(viewer);
    }
    await turn();
    expect(fixture_.materializer.pullCount).toBe(1);
    expect(page(await generator.next()).toCursor).toBe(9);
    expect(fixture_.materializer.pullCount).toBe(2);
    controller.abort();
  });

  it('propagates source setup and materialization failures with cleanup', async () => {
    const sourceFailure = fixture();
    sourceFailure.changes.failSubscribe = new Error('source failed');
    const firstController = new AbortController();
    await expect(
      subscribe(sourceFailure, firstController.signal).next(),
    ).rejects.toThrow('source failed');

    const readFailure = fixture();
    readFailure.materializer.failure = new Error('materialization failed');
    const secondController = new AbortController();
    await expect(
      subscribe(readFailure, secondController.signal).next(),
    ).rejects.toThrow('materialization failed');
    expect(readFailure.changes.cleanupCount).toBe(1);
  });

  it('manager close aborts all waiting generators and is idempotent', async () => {
    const fixture_ = fixture();
    fixture_.materializer.head = 1n;
    const leftController = new AbortController();
    const rightController = new AbortController();
    const left = subscribe(fixture_, leftController.signal);
    const right = subscribe(
      fixture_,
      rightController.signal,
      0n,
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    );
    await left.next();
    await right.next();
    const leftWaiting = left.next();
    const rightWaiting = right.next();
    await turn();

    fixture_.subscriptions.close();
    fixture_.subscriptions.close();

    await expect(leftWaiting).resolves.toMatchObject({ done: true });
    await expect(rightWaiting).resolves.toMatchObject({ done: true });
    expect(fixture_.changes.cleanupCount).toBe(2);
    expect(() =>
      subscribe(fixture_, new AbortController().signal),
    ).toThrow('closed');
  });

  it('requires an AbortSignal before creating a generator', () => {
    const fixture_ = fixture();
    expect(() =>
      fixture_.subscriptions.subscribe({
        principal: { userId: viewer },
        requestBytes: encodeWire({
          clientId: 'client',
          scope: viewer,
          fromCursor: 0,
        }),
        signal: undefined as never,
      }),
    ).toThrow('AbortSignal');
  });
});
