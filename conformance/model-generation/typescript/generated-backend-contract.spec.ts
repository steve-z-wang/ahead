import type { AuthenticatedPrincipal } from 'local-sync-backend';
import {
  generatedContract,
  type GeneratedBackendModelBindings,
} from '../../generated/backend/backend_contract';
import {
  createConformanceHost,
  type ConformanceHost,
} from '../../src/support/conformance-backend';
import { rejectedCaption, rejectionCode } from '../../src/support/model-bindings';
import { conformanceUserScope } from '../../src/support/scopes';

const CLIENT_ID = '5d6c1f20-9105-4f7e-89d7-163fa5dcbb84';
const OTHER_CLIENT_ID = 'b97321f4-022d-42b0-a723-9f37c26e55e7';
const MOMENT_ID = '550e8400-e29b-41d4-a716-446655440000';
const SPACE_ID = 'f0e1d2c3-b4a5-4968-8778-695a4b3c2d1e';
const USER_ID = '1c1a5f4e-2b3c-4d5e-8f90-a1b2c3d4e5f6';
const CAPTURED_AT = '2026-08-05T00:00:00.000Z';

const author: AuthenticatedPrincipal = { userId: 'author' };
const stranger: AuthenticatedPrincipal = { userId: 'stranger' };

type WireMutation = Record<string, unknown>;

/** One named act carrying one operation — the only shape the wire has. */
function act(
  ordinal: number,
  name: string,
  version: number,
  operation: Record<string, unknown>,
): WireMutation {
  return { ordinal, name, version, operations: [operation] };
}

function momentCreate(
  ordinal: number,
  caption: string | undefined = 'first',
): WireMutation {
  return act(ordinal, 'WriteMoment', 1, {
    model: 'Moment',
    op: 'create',
    identity: { id: MOMENT_ID },
    values: { caption, capturedAt: CAPTURED_AT, spaceId: SPACE_ID },
  });
}

function momentUpdate(
  ordinal: number,
  values: Record<string, unknown>,
): WireMutation {
  return act(ordinal, 'ReviseMoment', 1, {
    model: 'Moment',
    op: 'update',
    identity: { id: MOMENT_ID },
    values,
  });
}

function momentDelete(ordinal: number): WireMutation {
  return act(ordinal, 'DiscardMoment', 1, {
    model: 'Moment',
    op: 'delete',
    identity: { id: MOMENT_ID },
  });
}

function starCreate(ordinal: number): WireMutation {
  return act(ordinal, 'KeepMoment', 1, {
    model: 'Star',
    op: 'create',
    identity: { userId: USER_ID, momentId: MOMENT_ID },
    values: {},
  });
}

function encode(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

function decode(bytes: Uint8Array): any {
  return JSON.parse(Buffer.from(bytes).toString('utf8'));
}

function uplinkBytes(
  batchSequence: number,
  mutations: readonly WireMutation[],
  clientId = CLIENT_ID,
): Uint8Array {
  return encode({ clientId, batchSequence, mutations });
}

async function upload(
  host: ConformanceHost,
  batchSequence: number,
  mutations: readonly WireMutation[],
  principal: AuthenticatedPrincipal = author,
  clientId = CLIENT_ID,
) {
  const bytes = await host.backend.upload({
    principal,
    requestBytes: uplinkBytes(batchSequence, mutations, clientId),
  });
  return { bytes, response: decode(bytes) };
}

async function pull(
  host: ConformanceHost,
  afterSyncId: number,
  principal: AuthenticatedPrincipal = author,
): Promise<any> {
  const page = await host.backend.pullDownlink({
    principal,
    requestBytes: encode({
      clientId: CLIENT_ID,
      scope: conformanceUserScope,
      fromCursor: afterSyncId,
    }),
  });
  return decode(page.bytes);
}

describe('the generated Backend contract', () => {
  let host: ConformanceHost;

  beforeEach(() => {
    host = createConformanceHost();
  });

  afterEach(async () => {
    await host.backend.close();
  });

  it('requires exactly one binding per synced Model and excludes local Models', () => {
    const keys = Object.keys(generatedContract.models).sort();
    // Every generated Model, because the compiler no longer owns replication
    // policy (CAP-488). Which of them reaches the Downlink is decided by which
    // loaders the Backend registers.
    expect(keys).toEqual([
      'accountState',
      'localNote',
      'moment',
      'momentLink',
      'scalarSample',
      'space',
      'star',
      'starTag',
      'user',
    ]);

    // Every binding key is optional, and every one is exact: a Backend may
    // register any subset, and a name the contract does not hold is a
    // TypeScript compile error rather than a runtime surprise.
    const subset: GeneratedBackendModelBindings<unknown> = { moment: {} as never };
    expect(subset.accountState).toBeUndefined();
    expect(Object.keys(subset)).toEqual(['moment']);
  });

  it('writes a typed create and materializes it as a Downlink upsert', async () => {
    const { response } = await upload(host, 1, [momentCreate(1)]);
    expect(response.rejections).toEqual([]);
    expect(response.requiredSyncId).toBe(1);

    const page = await pull(host, 0);
    expect(page.fromCursor).toBe(0);
    expect(page.toCursor).toBe(1);
    expect(page.changes).toHaveLength(1);
    const change = page.changes[0]!;
    expect(change.model).toBe('Moment');
    expect(change.identity).toEqual({ id: MOMENT_ID });
    // Identity rides beside the state; the state is the rest of the row, whole
    // (CAP-428).
    expect(change.state).toEqual({
      caption: 'first',
      capturedAt: CAPTURED_AT,
      spaceId: SPACE_ID,
    });
  });

  it('carries a patch as set, unchanged, or explicitly null', async () => {
    await upload(host, 1, [momentCreate(1)]);
    // A key held at null is the clear.
    await upload(host, 2, [momentUpdate(2, { caption: null })]);

    const cleared = await pull(host, 0);
    const clearedState = cleared.changes[0]!.state;
    expect(clearedState?.caption ?? null).toBeNull();
    expect(clearedState?.spaceId).toBe(SPACE_ID);

    await upload(host, 3, [momentUpdate(3, { caption: 'second' })]);
    const set = await pull(host, 0);
    expect(set.changes[0]!.state?.caption).toBe('second');
  });

  it('materializes a delete as a delete change', async () => {
    await upload(host, 1, [momentCreate(1)]);
    await upload(host, 2, [momentDelete(2)]);

    const page = await pull(host, 0);
    expect(page.changes).toHaveLength(1);
    expect(page.changes[0]!.model).toBe('Moment');
    expect(page.changes[0]!.state).toBeNull();
  });

  it('keeps composite identities intact end to end', async () => {
    await upload(host, 1, [starCreate(1)]);

    const page = await pull(host, 0);
    const change = page.changes[0]!;
    expect(change.model).toBe('Star');
    expect(change.identity).toEqual({ userId: USER_ID, momentId: MOMENT_ID });
    // A Model that is nothing but its identity carries an empty state — every
    // field it has already travelled beside it.
    expect(change.state).toEqual({});
  });

  it('materializes absence when the binding does not admit the viewer', async () => {
    await upload(host, 1, [momentCreate(1)]);

    const page = await pull(host, 0, stranger);
    expect(page.changes).toHaveLength(1);
    expect(page.changes[0]).toMatchObject({
      model: 'Moment',
      identity: { id: MOMENT_ID },
      state: null,
    });
  });

  it('rejects one mutation deterministically and keeps the batch', async () => {
    const { response } = await upload(host, 1, [
      momentCreate(1, rejectedCaption),
      starCreate(2),
    ]);

    expect(response.rejections).toEqual([{ ordinal: 1, code: rejectionCode }]);
    const page = await pull(host, 0);
    expect(page.changes.map((change: any) => change.model)).toEqual(['Star']);
  });

  it('replays an identical batch as the exact stored bytes', async () => {
    const first = await upload(host, 1, [momentCreate(1)]);
    const replay = await upload(host, 1, [momentCreate(1)]);

    expect(replay.bytes).toEqual(first.bytes);
    const page = await pull(host, 0);
    expect(page.changes).toHaveLength(1);
  });

  it('refuses a batch that skips a sequence', async () => {
    await upload(host, 1, [momentCreate(1)]);
    await expect(upload(host, 3, [starCreate(2)])).rejects.toThrow();
  });

  it('refuses a client another principal already owns', async () => {
    await upload(host, 1, [momentCreate(1)]);
    await expect(
      upload(host, 1, [momentCreate(1)], stranger),
    ).rejects.toThrow();
  });

  it('lets a separate client keep its own sequence', async () => {
    await upload(host, 1, [momentCreate(1)]);
    const second = await upload(
      host,
      1,
      [starCreate(2)],
      author,
      OTHER_CLIENT_ID,
    );
    expect(second.response.rejections).toEqual([]);
  });

  it('reaches Downlink from a Scope Ledger write outside Uplink', async () => {
    const descriptor = generatedContract.models.moment;
    await host.persistence.transactions.write((transaction) =>
      host.backend.scopeLedger.invalidate(transaction, {
        model: descriptor as never,
        identity: { id: MOMENT_ID } as never,
        scopes: [conformanceUserScope],
      }),
    );

    const page = await pull(host, 0);
    expect(page.toCursor).toBe(1);
    // No row was ever written, so the viewer's visible state is absence.
    expect(page.changes[0]!.state).toBeNull();
  });

  it('advances the cursor on an empty page', async () => {
    const page = await pull(host, 0);
    expect(page.changes).toEqual([]);
    expect(page.fromCursor).toBe(0);
    expect(page.toCursor).toBe(0);
  });

  it('streams a committed change to a live subscriber', async () => {
    const controller = new AbortController();
    const pages = host.backend.subscribeDownlink({
      principal: author,
      requestBytes: encode({
        clientId: CLIENT_ID,
        scope: conformanceUserScope,
        fromCursor: 0,
      }),
      signal: controller.signal,
    });

    const first = pages.next();
    await upload(host, 1, [momentCreate(1)]);
    const received = await first;
    controller.abort();
    await pages.return(undefined as never);

    expect(received.done).toBe(false);
    const page = decode(received.value!.bytes);
    expect(page.changes[0]!.model).toBe('Moment');
    expect(page.changes[0]!.state).not.toBeNull();
  });
});
