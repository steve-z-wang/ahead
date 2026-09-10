import type { LocalSyncHost } from 'local-sync-backend';
import { InMemoryLocalSyncPersistence } from '../../src/support/in-memory-persistence';
import type { InMemoryTx } from '../../src/support/in-memory-transactions';
import {
  conformanceBookAId,
  conformanceBookBId,
  conformanceSpaceId,
  conformanceUserId,
  drive,
  servedHost,
  viewer,
} from '../../src/support/wire-harness';

/**
 * The whole chain, end to end: generated definitions through a real host, real
 * bytes over a loopback socket, the strict Model decoder, the apply path, and
 * SQLite — asserted by reading the client's own database back out.
 *
 * Every protocol scenario stops at the envelope, and the envelope codec
 * renames keys without judging them. The Model decoder — the strict one, the
 * one the app runs — only speaks when a page is applied, so a `state` the two
 * languages spell differently reaches a database here and nowhere else
 * (CAP-428).
 */

const client = 'end-to-end-sync/dart/journeys_client.dart';

// The scenario spawns a real Dart process, which costs seconds before a byte
// moves. The default 5s budget is about a unit test, not about this.
jest.setTimeout(60_000);

describe('the framework promises, from the client database out', () => {
  let host: LocalSyncHost<InMemoryTx>;
  let persistence: InMemoryLocalSyncPersistence;
  let port: number;

  beforeEach(async () => {
    persistence = new InMemoryLocalSyncPersistence();
    host = servedHost({ persistence });
    port = await host.listen(0, '127.0.0.1');
  });

  afterEach(async () => host.close());

  it('settles a mixed legacy-v1 and v2 frozen batch after a lost response and reopen', async () => {
    expect(await drive(client, port, 'mutation-version-restart')).toMatchObject({
      versions: [null, 2],
      name: 'new queued name',
      records: 0,
      batches: 0,
      beforeImages: 0,
      rejections: [],
    });
  });

  it('applies a pulled page into the client database', async () => {
    const result = await drive(client, port, 'apply');

    expect(result.failures).toEqual([]);
    // The three shapes a page can spell wrong, read back out of SQLite: a
    // list, a nullable field actually holding null, and an enum.
    expect(result).toMatchObject({
      spaceOrder: JSON.stringify(['f0e1d2c3-b4a5-4968-8778-695a4b3c2d1e']),
      inboxSeenAtIsNull: true,
      kind: 'group',
    });
  });

  it('keeps scoped cursors and Uplink settlement independent', async () => {
    const result = await drive(client, port, 'scoped-streams');

    expect(result.failures).toEqual([]);
    expect(result.requiredScope).toBe(`User:${conformanceUserId}`);
    expect(result).toMatchObject({
      initialUserCursor: 3,
      initialSpaceCursor: 1,
      userCursorAfterSpace: 3,
      spaceCursorAfterSpace: 4,
      requiredSyncId: 4,
      batchesAfterSpace: 1,
      batchesAfterUser: 0,
      finalUserCursor: 4,
      spaceName: 'Renamed',
      sampleRank: 45,
    });
  });

  it('settles one optimistic batch only after all scoped cursors arrive', async () => {
    const result = await drive(client, port, 'multi-scope-settlement');

    expect(result.checkpoints).toEqual([
      `Book:${conformanceBookAId}:1`,
      `Book:${conformanceBookBId}:1`,
      `User:${conformanceUserId}:4`,
    ]);
    expect(result).toMatchObject({
      batchesAfterBookA: 1,
      batchesAfterUser: 1,
      batchesAfterBookB: 0,
      operationsAfterBookB: 0,
    });
  });

  it('opens the generated runtime with two live scopes', async () => {
    const result = await drive(client, port, 'scoped-runtime');

    expect(result).toMatchObject({
      initialUserCursor: 3,
      initialSpaceCursor: 1,
      finalUserCursor: 4,
      finalSpaceCursor: 1,
      spaceName: 'Runtime Renamed',
      sampleRank: 42,
      pendingOperations: 0,
      batches: 0,
    });
  });

  it('lands a create, an explicit null and a delete in order', async () => {
    const result = await drive(client, port, 'typed-lifecycle');

    expect(result.failures).toEqual([]);
    // Read through the generated typed API, which is the only reader the app
    // has: the row the create made, the same row with its nullable field
    // actually holding null, and then no row at all.
    expect(result).toMatchObject({
      createdCaption: 'first',
      updatedCaptionIsNull: true,
      updatedRowPresent: true,
      deletedRowAbsent: true,
    });
    // Each applied page moves the client's own place in the stream forward.
    const cursors = result.cursors as number[];
    expect(cursors).toHaveLength(3);
    expect(cursors[0]).toBeGreaterThan(0);
    expect(cursors[1]).toBeGreaterThan(cursors[0]);
    expect(cursors[2]).toBeGreaterThan(cursors[1]);
  });

  it('carries one named act whole, from mutate to settlement', async () => {
    const result = await drive(client, port, 'named-mutation');

    expect(result).toMatchObject({
      // 42 operations applied at once, in one SQLite transaction, and every
      // row readable before a byte moved.
      moments: 1,
      tags: 40,
      stars: 1,
      // One record, however many operations spell it.
      records: 1,
      operations: 42,
      // Readiness is the act's, not the operation's: one unmarked key held
      // all 42 at home.
      heldRecords: 1,
      // Settlement leaves nothing: no record, no operation, no batch, and no
      // twin holding a before-image for a row nothing is pending on.
      settledRecords: 0,
      settledOperations: 0,
      uplinkBatches: 0,
      momentBefore: 0,
      tagBefore: 0,
      // The resolver wrote a row no operation in the request named, and a
      // flat Downlink pull brought it down.
      sideEffectLinks: 1,
      sideEffectLinkId: 'e7c9a1b2-3d4e-4f50-8617-2839a4b5c6d7',
    });
  });

  it('rolls a refused act back whole, leaving its neighbour alone', async () => {
    const result = await drive(client, port, 'named-mutation-rejection');

    expect(result).toMatchObject({
      // The host refused the act, so the whole of it is gone — client-side
      // too, rebuilt away rather than left half-applied.
      moments: 0,
      tags: 0,
      stars: 0,
      // The unrelated act in the same batch was never in question.
      spaceName: 'Renamed',
      // And nothing of the refusal is left behind.
      records: 0,
      operations: 0,
      uplinkBatches: 0,
    });
  });

  it('schedules exact lifecycle and product-order dependencies', async () => {
    const result = await drive(client, port, 'uplink-scheduling');

    expect(result).toMatchObject({
      // A1, B1-after-A1, A2 freezes only the two earlier-ordinal facts the
      // schema and same-row rule actually name. Readiness-blocked B1 neither
      // acquires A2 nor holds unrelated work, including through restart.
      explicitEdge: true,
      selfEdge: true,
      noImplicitJoin: true,
      restartPreserved: true,
      unrelatedOvertook: true,
      blockedMomentCaption: 'blocked',
      spaceNameAfterOvertake: 'A2',
      // Product order may share a request. A lifecycle create dependency may
      // not, but Backend acceptance is enough; Downlink settlement may follow.
      businessSameBatch: true,
      lifecycleEdgeFrozen: true,
      lifecycleSeparateRequests: true,
      acceptedBeforeSettlement: true,
      // Lifecycle refusal cascades. Product-order refusal merely releases the
      // surviving successor after its own readiness gate opens.
      lifecycleCascade: true,
      sequenceOnlyEdgeFrozen: true,
      sequenceReleased: true,
      // An unknown outcome retries the already-frozen bytes before the
      // controller schedules work queued while that request was in flight.
      retryIdentical: true,
      retryBeforeNewWork: true,
      newWorkFollowedRetry: true,
      records: 0,
      operations: 0,
      batches: 0,
    });
  });

  it('carries a mixed act whole, keeping the local slot off the wire', async () => {
    const result = await drive(client, port, 'mixed-act');

    expect(result).toMatchObject({
      // One record, BOTH operations in it — the local one rides the queue
      // for rollback's sake. The resolver's argument type has no `note`
      // slot, so a settled queue is itself the proof the wire carried the
      // synced operation alone.
      records: 1,
      operations: 2,
      notes: 1,
      // Acceptance finalizes the local row: present, and holding nothing.
      settledOperations: 0,
      settledNotes: 1,
      settledNoteBefore: 0,
      caption: 'captioned',
    });
  });

  it('rolls a refused mixed act back whole, local slot included', async () => {
    const result = await drive(client, port, 'mixed-act-rejection');

    expect(result).toMatchObject({
      // The note was there while the act was in flight…
      optimisticNotes: 1,
      // …and went with it: one fate, the device-local row included.
      notes: 0,
      noteBefore: 0,
      caption: null,
      // The accepted neighbour was never in question.
      spaceName: 'Renamed',
      records: 0,
      operations: 0,
    });
  });

  it('keeps a direct-lane edit beneath a refused mixed act', async () => {
    const result = await drive(client, port, 'mixed-act-direct-lane');

    expect(result).toMatchObject({
      // The refusal took the provisional restyle and only it: the all-local
      // EditNote was final, so it advanced the held truth and the rebuild
      // lands on it.
      noteText: 'final',
      noteBefore: 0,
      caption: null,
      spaceName: 'Renamed',
      operations: 0,
    });
  });

  it('refuses a binding violation at the write boundary, then lands the corrected act', async () => {
    const result = await drive(client, port, 'slot-binding-mismatch');

    expect(result).toMatchObject({
      // A bound row naming a different parent than the act carries dies
      // inside mutate(), before anything is written or queued (spec
      // 2026-08-16-slot-bindings)…
      refused: true,
      records: 0,
      operations: 0,
      moments: 0,
      stars: 0,
      // …and the corrected act crosses both checks — the client verifier and
      // the server's bound-create precheck — and lands end to end.
      settledMoments: 1,
      settledStars: 1,
      settledTags: 1,
    });
  });

  it('rebuilds typed state around an edit the host refuses', async () => {
    const result = await drive(client, port, 'rejection-rebuild');

    expect(result).toMatchObject({
      // The refused edit is gone from the row the user is looking at, which
      // reads the server's own caption again.
      caption: 'first',
      // Its neighbour in the same batch was never in question.
      neighbourCaption: 'kept',
      // And nothing of the refusal is left behind: not the mutation, and not
      // the batch it rode in.
      pendingMutations: 0,
      uplinkBatches: 0,
    });
    expect(result.cursor).toBeGreaterThan(result.seededCursor as number);
  });

  it('chooses synchronization per write, on one Model', async () => {
    const result = await drive(client, port, 'write-path');

    expect(result).toMatchObject({
      // `write` committed the row and nothing became sendable — no record, no
      // queued operation, no batch (CAP-488).
      writtenText: 'device only',
      writeRecords: 0,
      writeOperations: 0,
      writeBatches: 0,
      // The same Model, sent by an act that names it.
      queuedOperations: 1,
      publishedText: 'shared',
      // The device-only row is untouched by any of it.
      writtenTextAfterPublish: 'device only',
      // And the act whose callback proved itself a no-op left nothing at all.
      records: 0,
      operations: 0,
    });
  });

  it('applies a change stream that does not fit one page', async () => {
    const result = await drive(client, port, 'multipage-apply');

    expect(result.failures).toEqual([]);
    // The server's page ceiling is 50, so 51 rows is the smallest stream that
    // cannot arrive at once.
    expect(result.pageChanges).toEqual([50, 1]);
    // Every row landed, once: 49 Moments under the Space and User they hang
    // off, read back through the generated query API.
    expect(result).toMatchObject({ syncedRows: 51, distinctMoments: 49 });

    // Each page begins where the one before it ended, and the client's stored
    // cursor ends where the last one did — no gap, no page applied twice.
    const from = result.pageFrom as number[];
    const through = result.pageThrough as number[];
    expect(from[0]).toBe(0);
    expect(from[1]).toBe(through[0]);
    expect(result.cursor).toBe(through[through.length - 1]);
  });

  it('catches up on what it missed while it was away', async () => {
    const result = await drive(client, port, 'reconnect-catch-up');

    expect(result.failures).toEqual([]);
    expect(result).toMatchObject({
      // One channel, closed; a write while nobody was listening; one channel
      // again. Two connections, and the second one is not a retry loop.
      connects: 2,
      connectsAfterCatchUp: 2,
      // The write nobody was there for, read out of the client's database.
      caption: 'first',
      cursorBefore: 0,
    });
    expect(result.cursor).toBeGreaterThan(0);
  });

  it('moves the row and the cursor together, or neither', async () => {
    const result = await drive(client, port, 'atomic-local-failure');

    // The cursor could not be written, so the apply failed out loud and took
    // its own rows with it: a client that kept the row but not the cursor
    // would apply the same change twice, and the reverse would lose it.
    expect(typeof result.failure).toBe('string');
    expect(result).toMatchObject({
      blockedRows: 0,
      blockedCursor: 0,
      // The same page, with the block gone, lands whole.
      retriedFailures: [],
      retriedCaption: 'first',
      retriedRows: 3,
    });
    expect(result.retriedCursor).toBe(result.pageThrough);
  });
});
