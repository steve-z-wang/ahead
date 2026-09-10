import {
  decodeUplinkRequestEnvelope,
  encodeDownlinkPageEnvelope,
} from '../src';

/**
 * What the wire says now that neither version exists (CAP-481).
 *
 * The fields are not deprecated, tolerated or defaulted — they are gone, in
 * both directions, and this holds the shape so nobody restores one by
 * accident. There is no compatibility window because there is nothing to be
 * compatible with: nothing is installed, and the wire has no readers but the
 * two runtimes in this repository.
 *
 * The client's half lives beside the client, in
 * `local-sync/client/local_sync/test/transport/wire_contract_test.dart`.
 */
describe('the wire carries no version', () => {
  const spaceId = '550e8400-e29b-41d4-a716-446655440000';

  const read = (bytes: Uint8Array): Record<string, unknown> =>
    JSON.parse(Buffer.from(bytes).toString('utf8')) as Record<string, unknown>;

  const encode = (value: unknown): Uint8Array =>
    Buffer.from(JSON.stringify(value), 'utf8');

  it('a Downlink change states its Model and nothing about its shape', () => {
    const page = read(
      encodeDownlinkPageEnvelope({
        scope: `User:${spaceId}`,
        fromSyncId: 0n,
        throughSyncId: 1n,
        changes: [
          {
            syncId: 1n,
            model: 'Space',
            identity: { id: spaceId },
            state: { title: 'Family' },
          },
        ],
      }),
    );

    expect((page.changes as Record<string, unknown>[])[0]).toEqual({
      syncId: 1,
      model: 'Space',
      identity: { id: spaceId },
      state: { title: 'Family' },
    });
  });

  it('an Uplink body is accepted with no version anywhere in it', () => {
    const request = decodeUplinkRequestEnvelope(
      encode({
        clientId: 'client',
        batchSequence: 1,
        mutations: [
          {
            ordinal: 1,
            name: 'CreateSpace',
            operations: [
              {
                model: 'Space',
                op: 'create',
                identity: { id: spaceId },
                values: { title: 'Family' },
              },
            ],
          },
        ],
      }),
    );

    expect(request.mutations).toHaveLength(1);
    expect(request.batchSequence).toBe(1n);
  });
});
