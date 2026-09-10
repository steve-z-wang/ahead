import type { LocalSyncHost } from 'local-sync-backend';
import type { InMemoryTx } from '../../src/support/in-memory-transactions';
import { rejectionCode } from '../../src/support/model-bindings';
import {
  conformanceBookAId,
  conformanceBookBId,
  conformanceDeniedBookId,
  conformanceSpaceId,
  conformanceToken,
  conformanceUserId,
  drive,
  servedHost,
  staleToken,
} from '../../src/support/wire-harness';

/**
 * The wire, proven across the two languages that have to agree about it.
 *
 * A real Dart client — the shipped `RestWsTransport` and `LocalSyncJsonCodec`
 * — drives the real `LocalSyncHost` over a loopback socket. Neither side
 * stands in for the other, so a disagreement about the envelope fails here and
 * nowhere else. This is the suite the CAP-410 review found missing.
 */

const client = 'server-client-protocol/dart/protocol_client.dart';

// Every scenario spawns a real Dart process, which costs seconds before a
// byte moves. The default 5s budget is about a unit test, not about this.
jest.setTimeout(60_000);

describe('the wire, across languages', () => {
  let host: LocalSyncHost<InMemoryTx>;
  let port: number;

  beforeEach(async () => {
    host = servedHost();
    port = await host.listen(0, '127.0.0.1');
  });

  afterEach(async () => host.close());

  // Dart writes the bytes, TypeScript reads them, and the answer comes back
  // positionally. Three Models in one batch, because a page carries a family.
  it('carries an Uplink batch and answers it', async () => {
    const result = await drive(client, port, 'upload');

    expect(result).toMatchObject({
      requiredScope: `User:${conformanceUserId}`,
      requiredSyncId: 3,
      rejections: 0,
    });
  });

  it('mixes omitted v1, explicit v1 and v2, then replays the receipt', async () => {
    expect(await drive(client, port, 'mutation-versions')).toMatchObject({
      status: 200,
      rejections: [],
      replaySame: true,
      versions: [null, 1, 2],
    });
  });

  it('carries every selected Uplink checkpoint across languages', async () => {
    const result = await drive(client, port, 'multi-checkpoint');

    expect(result.requiredCheckpoints).toEqual([
      { scope: `Book:${conformanceBookAId}`, syncId: 1 },
      { scope: `Book:${conformanceBookBId}`, syncId: 1 },
      { scope: `User:${conformanceUserId}`, syncId: 1 },
    ]);
    expect(result.legacyPrincipal).toEqual({
      scope: `User:${conformanceUserId}`,
      syncId: 1,
    });
  });

  it('decodes a singleton-only legacy receipt as one checkpoint', async () => {
    const result = await drive(client, port, 'legacy-receipt');

    expect(result.checkpoints).toEqual([
      { scope: `User:${conformanceUserId}`, syncId: 7 },
    ]);
  });

  // The bug the review found: canonical JSON cannot encode a bigint, so an
  // Int widened for protobuf would fail to serialize on the way back down.
  it('carries an Int down as a number', async () => {
    const result = await drive(client, port, 'int');

    expect(result).toMatchObject({ rank: 42 });
  });

  it('states a refusal in place and lands its neighbours', async () => {
    const result = await drive(client, port, 'reject');

    expect(result.rejections).toEqual([{ ordinal: 4, code: rejectionCode }]);
  });

  it('pages the Downlink forward and stops when caught up', async () => {
    const result = await drive(client, port, 'pull');

    expect(result).toMatchObject({
      firstFrom: 0,
      firstThrough: 3,
      firstChanges: 3,
      secondChanges: 0,
      secondEmptyAtCursor: true,
    });
    expect(result.models).toEqual(
      expect.arrayContaining(['User', 'Space', 'Moment']),
    );
  });

  // Both sides declare the page size independently — 50 in the Dart codec, 50
  // in the Backend's cursor — and sharing one constant would hide the day they
  // disagree. So the agreement is proved by behavior: 51 changes must split
  // 50 + 1, and where the second page starts is where the first one ended.
  it('crosses exactly one page boundary', async () => {
    const result = await drive(client, port, 'multipage');

    expect(result).toMatchObject({
      firstCount: 50,
      secondCount: 1,
      firstFrom: 0,
      secondFrom: result.firstThrough,
    });
    const syncIds = result.syncIds as number[];
    // Nothing served twice, nothing skipped: the cursor handoff is the whole
    // claim, and a duplicate or a gap would satisfy the counts alone.
    expect(syncIds).toHaveLength(51);
    expect(new Set(syncIds).size).toBe(51);
    expect([...syncIds].sort((left, right) => left - right)).toEqual(syncIds);
    expect(result.secondThrough).toBe(syncIds[syncIds.length - 1]);
  });

  it('pushes a page over the live channel', async () => {
    const result = await drive(client, port, 'live');

    expect(result).toMatchObject({ pages: 1, beginsAtCursor: true });
    expect(result.changes).toBe(3);
  });

  // Two doors onto the same page. A client that trusted only one of them
  // would be right by accident, so the pushed page and the asked-for page are
  // decoded and compared whole.
  it('live and pull carry equivalent pages', async () => {
    const result = await drive(client, port, 'live-equivalent');

    const live = result.live as { readonly changes: readonly unknown[] };
    expect(live.changes).toHaveLength(3);
    expect(result.live).toEqual(result.pull);
  });

  it('opens the channel and catches up from the cursor', async () => {
    const result = await drive(client, port, 'reconnect');

    expect(result).toMatchObject({ connects: 1, caughtUpChanges: 3 });
  });

  it('keeps two namespace-distinct scope streams independent', async () => {
    const result = await drive(client, port, 'scoped');
    const user = result.userScope as {
      readonly scope: string;
      readonly changes: readonly { readonly model: string }[];
    };
    const space = result.spaceScope as {
      readonly scope: string;
      readonly from: number;
      readonly through: number;
      readonly changes: readonly {
        readonly syncId: number;
        readonly model: string;
      }[];
    };
    const spaceNext = result.spaceNext as {
      readonly scope: string;
      readonly from: number;
      readonly changes: readonly {
        readonly syncId: number;
        readonly model: string;
      }[];
    };

    expect(user.scope).toBe(`User:${conformanceUserId}`);
    expect(space.scope).toBe(`Space:${conformanceSpaceId}`);
    expect(spaceNext.scope).toEqual(space.scope);
    expect(user.changes.map((change) => change.model)).not.toContain(
      'ScalarSample',
    );
    expect(space.changes).toHaveLength(50);
    expect(spaceNext.changes).toHaveLength(1);
    expect(spaceNext.from).toBe(space.through);
    const syncIds = [...space.changes, ...spaceNext.changes].map(
      (change) => change.syncId,
    );
    expect(new Set(syncIds).size).toBe(51);
    expect([...syncIds].sort((left, right) => left - right)).toEqual(syncIds);
    expect(result.liveAcknowledgement).toEqual({
      accepted: [`Space:${conformanceSpaceId}`, `User:${conformanceUserId}`],
      rejections: [],
    });
  });

  it('keeps an authorized live scope when its neighbour is refused', async () => {
    const result = await drive(client, port, 'mixed-authorization');

    expect(result).toMatchObject({
      accepted: [`User:${conformanceUserId}`],
      rejected: [`Book:${conformanceDeniedBookId}:scope.forbidden`],
      userLiveChanges: 1,
    });
  });

  it('refuses a well-formed unauthorized scope', async () => {
    const result = await drive(client, port, 'denied-scope');

    expect(result).toMatchObject({
      failure: 'LocalSyncTerminalTransportFailure',
      status: 403,
    });
  });

  // The App's three-layer convention: refused once, refreshed once, landed.
  it('refreshes a refused credential exactly once and lands the call', async () => {
    const result = await drive(
      client,
      port,
      'refresh',
      `${staleToken},${conformanceToken}`,
    );

    expect(result).toMatchObject({ status: 200, requiredSyncId: 3 });
    expect(result.tokensIssued).toBe(2);
  });
});

/**
 * The build floor (CAP-157), across the two sides that have to agree about it:
 * the Dart transport writes `?build=` onto the live URI and the host reads it.
 * Each names the floor on its own — the agreement is what is under test.
 */
describe('the build floor', () => {
  let host: LocalSyncHost<InMemoryTx>;
  let port: number;

  beforeEach(async () => {
    host = servedHost({ minBuild: 100 });
    port = await host.listen(0, '127.0.0.1');
  });

  afterEach(async () => host.close());

  it('admits a client standing on the floor', async () => {
    const result = await drive(client, port, 'build-accepted');

    expect(result).toMatchObject({ connects: 1, caughtUpChanges: 3 });
  });

  // One refusal, said out loud and not retried: a build cannot upgrade itself
  // by asking again, so a reconnect loop here would be a loop forever.
  it('refuses a client below it, once and terminally', async () => {
    const result = await drive(client, port, 'build-refused');

    expect(result).toMatchObject({
      failure: 'LocalSyncTerminalTransportFailure',
      status: 426,
      connects: 0,
      tokensIssued: 1,
    });
  });
});
