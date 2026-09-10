import {
  LocalSyncProtocolError,
  decodeLiveSubscribeEnvelope,
  decodeDownlinkRequestEnvelope,
  decodeUplinkRequestEnvelope,
  encodeDownlinkPageEnvelope,
  encodeLiveSubscribedEnvelope,
  encodeUplinkResponseEnvelope,
} from '../src';

const clientId = 'f2b1c7d4-8e3a-4b16-9c25-0d7e6a1b3c48';
const spaceId = '550e8400-e29b-41d4-a716-446655440000';
const scope = `User:${spaceId}`;

function bytes(value: unknown): Uint8Array {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

function read(value: Uint8Array): unknown {
  return JSON.parse(Buffer.from(value).toString('utf8'));
}

function uplink(overrides: Record<string, unknown> = {}): Uint8Array {
  return bytes({
    clientId,
    batchSequence: 7,
    mutations: [
      {
        ordinal: 41,
        model: 'Moment',
        op: 'create',
        identity: { id: spaceId },
        values: { text: 'hello', spaceId },
      },
    ],
    ...overrides,
  });
}

describe('decodeUplinkRequestEnvelope', () => {
  it('reads the approved envelope', () => {
    const request = decodeUplinkRequestEnvelope(uplink());

    expect(request.clientId).toBe(clientId);
    expect(request.batchSequence).toBe(7n);
    expect(request.mutations).toHaveLength(1);
    const mutation = request.mutations[0];
    expect(mutation.ordinal).toBe(41n);
    // Structure only: what the mutation SAYS is the executor's to validate,
    // one at a time, so a malformed neighbour cannot refuse the batch.
    expect(mutation.raw).toMatchObject({
      model: 'Moment',
      op: 'create',
      identity: { id: spaceId },
      values: { text: 'hello', spaceId },
    });
  });

  it('carries an update patch with an explicit clear', () => {
    const request = decodeUplinkRequestEnvelope(
      uplink({
        mutations: [
          {
            ordinal: 1,
            model: 'Moment',
            op: 'update',
            identity: { id: spaceId },
            values: { text: null },
          },
        ],
      }),
    );

    expect(request.mutations[0].raw).toMatchObject({
      op: 'update',
      values: { text: null },
    });
  });

  it('leaves a delete with no values', () => {
    const request = decodeUplinkRequestEnvelope(
      uplink({
        mutations: [
          {
            ordinal: 1,
            model: 'Moment',
            op: 'delete',
            identity: { id: spaceId },
          },
        ],
      }),
    );

    expect(request.mutations[0].raw).toMatchObject({ op: 'delete' });
    expect(request.mutations[0].raw.values).toBeUndefined();
  });

  it('ignores unknown fields on read', () => {
    const request = decodeUplinkRequestEnvelope(
      bytes({
        clientId,
        batchSequence: 7,
        clientBuild: 'ignored',
        mutations: [
          {
            ordinal: 41,
            model: 'Moment',
            op: 'create',
            identity: { id: spaceId },
            values: { text: 'hello' },
            writtenAt: 'ignored',
          },
        ],
      }),
    );

    expect(request.mutations[0].ordinal).toBe(41n);
  });

  it('hashes the same meaning to the same semantic value', () => {
    const first = decodeUplinkRequestEnvelope(uplink());
    const second = decodeUplinkRequestEnvelope(uplink());

    expect(first.semanticValue).toEqual(second.semanticValue);
  });

  it.each([
    ['bytes that are not JSON', Buffer.from([0x00, 0x01])],
    ['a blank clientId', uplink({ clientId: '  ' })],
    ['a zero batchSequence', uplink({ batchSequence: 0 })],
    ['a fractional batchSequence', uplink({ batchSequence: 1.5 })],
    ['an empty batch', uplink({ mutations: [] })],
    [
      'an oversized batch',
      uplink({
        mutations: Array.from({ length: 21 }, (_unused, index) => ({
          ordinal: index + 1,
          model: 'Moment',
          op: 'delete',
          identity: { id: spaceId },
        })),
      }),
    ],
    [
      'duplicate ordinals',
      uplink({
        mutations: [
          {
            ordinal: 1,
            model: 'Moment',
            op: 'delete',
            identity: { id: spaceId },
          },
          {
            ordinal: 1,
            model: 'Moment',
            op: 'delete',
            identity: { id: spaceId },
          },
        ],
      }),
    ],
  ])('rejects %s', (_label, input) => {
    expect(() => decodeUplinkRequestEnvelope(input)).toThrow(
      LocalSyncProtocolError,
    );
  });

  // What a mutation says is not the envelope's business: an unreadable one is
  // carried through and settled positionally by the executor.
  it('carries a mutation it cannot make sense of', () => {
    const request = decodeUplinkRequestEnvelope(
      uplink({ mutations: [{ ordinal: 1, op: 'nonsense' }] }),
    );

    expect(request.mutations[0].ordinal).toBe(1n);
    expect(request.mutations[0].raw).toMatchObject({ op: 'nonsense' });
  });
});

describe('encodeUplinkResponseEnvelope', () => {
  it('writes an accepted batch', () => {
    const encoded = encodeUplinkResponseEnvelope({
      requiredScope: scope,
      requiredSyncId: 118n,
      requiredCheckpoints: [{ scope, syncId: 118n }],
      rejections: [],
    });

    expect(read(encoded)).toEqual({
      requiredCheckpoints: [
        { scope, syncId: 118 },
      ],
      requiredScope: scope,
      requiredSyncId: 118,
      rejections: [],
    });
  });

  it('writes positional rejections with their codes', () => {
    const encoded = encodeUplinkResponseEnvelope({
      requiredScope: scope,
      requiredSyncId: 9n,
      requiredCheckpoints: [{ scope, syncId: 9n }],
      rejections: [{ ordinal: 41n, code: 'mutation.invalid' }],
    });

    expect(read(encoded)).toEqual({
      requiredCheckpoints: [
        { scope, syncId: 9 },
      ],
      requiredSyncId: 9,
      requiredScope: scope,
      rejections: [{ ordinal: 41, code: 'mutation.invalid' }],
    });
  });

  it('is byte-stable, so a replayed batch returns identical bytes', () => {
    const encode = (): Uint8Array =>
      encodeUplinkResponseEnvelope({
        requiredScope: scope,
        requiredSyncId: 9n,
        requiredCheckpoints: [{ scope, syncId: 9n }],
        rejections: [{ ordinal: 41n, code: 'space.locked' }],
      });

    expect(Buffer.from(encode()).toString('utf8')).toBe(
      Buffer.from(encode()).toString('utf8'),
    );
  });

  it('refuses a position no client could read back', () => {
    expect(() =>
      encodeUplinkResponseEnvelope({
        requiredScope: scope,
        requiredSyncId: BigInt(Number.MAX_SAFE_INTEGER) + 1n,
        requiredCheckpoints: [{ scope, syncId: 0n }],
        rejections: [],
      }),
    ).toThrow(LocalSyncProtocolError);
  });

  it('writes every scope checkpoint', () => {
    const bookScope = `Book:${clientId}`;

    const encoded = encodeUplinkResponseEnvelope({
      requiredScope: scope,
      requiredSyncId: 9n,
      requiredCheckpoints: [
        { scope, syncId: 9n },
        { scope: bookScope, syncId: 41n },
      ],
      rejections: [],
    });

    expect(read(encoded)).toEqual({
      requiredCheckpoints: [
        { scope, syncId: 9 },
        { scope: bookScope, syncId: 41 },
      ],
      requiredScope: scope,
      requiredSyncId: 9,
      rejections: [],
    });
  });
});

describe('decodeDownlinkRequestEnvelope', () => {
  it('reads one opaque text scope and its cursor', () => {
    const request = decodeDownlinkRequestEnvelope(
      bytes({
        clientId,
        scope,
        fromCursor: 118,
      }),
    );

    expect(request.clientId).toBe(clientId);
    expect(request.scope).toBe(scope);
    expect(request.afterSyncId).toBe(118n);
    expect(request).not.toHaveProperty('limit');
  });

  it('accepts a zero cursor', () => {
    expect(
      decodeDownlinkRequestEnvelope(
        bytes({ clientId, scope, fromCursor: 0 }),
      )
        .afterSyncId,
    ).toBe(0n);
  });

  it('ignores the removed limit field', () => {
    const request = decodeDownlinkRequestEnvelope(
      bytes({
        clientId,
        scope,
        fromCursor: 0,
        limit: 1,
      }),
    );
    expect(request).not.toHaveProperty('limit');
  });

  it.each([
    [
      'a negative cursor',
      bytes({ clientId, scope, fromCursor: -1 }),
    ],
    [
      'a missing cursor',
      bytes({ clientId, scope }),
    ],
    [
      'a blank clientId',
      bytes({ clientId: '', scope, fromCursor: 0 }),
    ],
    [
      'the retired structured scope shape',
      bytes({
        clientId,
        scope: { model: 'User', id: spaceId },
        fromCursor: 0,
      }),
    ],
  ])('rejects %s', (_label, input) => {
    expect(() => decodeDownlinkRequestEnvelope(input)).toThrow(
      LocalSyncProtocolError,
    );
  });
});

describe('live scope handshake envelopes', () => {
  it('canonicalizes the subscribe set and writes the exact subscribed ack', () => {
    const subscribed = decodeLiveSubscribeEnvelope(
      bytes({
        type: 'subscribe',
        scopes: [scope, `Book:${clientId}`, scope],
      }),
    );

    expect(subscribed.scopes).toEqual([
      `Book:${clientId}`,
      scope,
    ]);
    const encoded = encodeLiveSubscribedEnvelope({
      scopes: subscribed.scopes,
      rejections: [],
    });
    expect(read(encoded)).toEqual({
      type: 'subscribed',
      scopes: [`Book:${clientId}`, scope],
      rejections: [],
    });
    expect(Buffer.from(encoded).toString('utf8')).toBe(
      `{"rejections":[],"scopes":["Book:${clientId}","User:${spaceId}"],"type":"subscribed"}`,
    );
  });

  it('writes rejected and all-rejected acknowledgements', () => {
    const rejected = {
      scope: `Book:${clientId}`,
      code: 'scope.forbidden',
    };

    expect(
      read(
        encodeLiveSubscribedEnvelope({
          scopes: [scope],
          rejections: [rejected],
        }),
      ),
    ).toEqual({
      type: 'subscribed',
      scopes: [scope],
      rejections: [
        {
          scope: `Book:${clientId}`,
          code: 'scope.forbidden',
        },
      ],
    });
    expect(
      read(
        encodeLiveSubscribedEnvelope({
          scopes: [],
          rejections: [rejected],
        }),
      ),
    ).toEqual({
      type: 'subscribed',
      scopes: [],
      rejections: [
        {
          scope: `Book:${clientId}`,
          code: 'scope.forbidden',
        },
      ],
    });
  });

  it.each([
    ['invalid JSON', Buffer.from('{')],
    ['wrong type', bytes({ type: 'setScopes', scopes: [] })],
    ['empty set', bytes({ type: 'subscribe', scopes: [] })],
    [
      'retired structured scope',
      bytes({
        type: 'subscribe',
        scopes: [{ model: 'User', id: spaceId }],
      }),
    ],
  ])('rejects %s', (_label, input) => {
    expect(() => decodeLiveSubscribeEnvelope(input)).toThrow(
      LocalSyncProtocolError,
    );
  });
});

describe('encodeDownlinkPageEnvelope', () => {
  it('writes a present state as the state itself', () => {
    const encoded = encodeDownlinkPageEnvelope({
      scope,
      fromSyncId: 118n,
      throughSyncId: 123n,
      changes: [
        {
          syncId: 119n,
          model: 'FeedEntry',
          identity: { userId: spaceId, momentId: spaceId },
          state: { arrivedAt: '2026-08-03T19:00:00.000Z' },
        },
      ],
    });

    expect(read(encoded)).toEqual({
      fromCursor: 118,
      scope,
      toCursor: 123,
      changes: [
        {
          syncId: 119,
          model: 'FeedEntry',
          identity: { userId: spaceId, momentId: spaceId },
          state: { arrivedAt: '2026-08-03T19:00:00.000Z' },
        },
      ],
    });
  });

  it('writes absence as a null state', () => {
    const encoded = encodeDownlinkPageEnvelope({
      scope,
      fromSyncId: 118n,
      throughSyncId: 119n,
      changes: [
        {
          syncId: 119n,
          model: 'FeedEntry',
          identity: { userId: spaceId, momentId: spaceId },
          state: null,
        },
      ],
    });

    expect((read(encoded) as { changes: { state: unknown }[] }).changes[0].state).toBeNull();
  });

  it('writes an empty page', () => {
    const encoded = encodeDownlinkPageEnvelope({
      scope,
      fromSyncId: 118n,
      throughSyncId: 118n,
      changes: [],
    });

    expect(read(encoded)).toEqual({
      fromCursor: 118,
      scope,
      toCursor: 118,
      changes: [],
    });
  });
});
