import { normalizeModelState, type SyncModelDescriptor } from '../src';

const model = {
  name: 'Moment',
  identityFields: ['id'],
  fields: [
    { name: 'id', nullable: false, identity: true, type: { kind: 'scalar', name: 'uuid' } },
    { name: 'caption', nullable: true, identity: false, type: { kind: 'scalar', name: 'string' } },
    { name: 'tags', nullable: false, identity: false, type: { kind: 'list', element: 'string' } },
    { name: 'position', nullable: false, identity: false, type: { kind: 'scalar', name: 'int' } },
    { name: 'width', nullable: true, identity: false, type: { kind: 'scalar', name: 'int' } },
    { name: 'sizes', nullable: false, identity: false, type: { kind: 'list', element: 'int' } },
  ],
} as unknown as SyncModelDescriptor;

function base(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { id: 'a', tags: [], position: 0, sizes: [], ...overrides };
}

describe('visible state normalization', () => {
  // The set the client's decoder demands exactly: every non-identity field,
  // present, with null spelled as null. Both rules read the other way while
  // this served the protobuf encoder, and no test crossed the two languages
  // deeply enough to notice (CAP-428).
  it('carries every non-identity field, and spells null null', () => {
    expect(normalizeModelState(model, base({ caption: null }))).toEqual({
      caption: null,
      tags: [],
      position: 0,
      width: null,
      sizes: [],
    });
  });

  it('keeps a nullable field that holds a value', () => {
    expect(normalizeModelState(model, base({ caption: 'hello' }))).toEqual({
      caption: 'hello',
      tags: [],
      position: 0,
      width: null,
      sizes: [],
    });
  });

  // A change carries `identity` beside `state`; repeating it inside would make
  // the client choose between two copies of the same fact.
  it('drops identity fields, which travel beside the state', () => {
    expect(normalizeModelState(model, base())).not.toHaveProperty('id');
  });

  // Which is why a binding that never mentions identity in its state is fine:
  // the identity the change carries is the authority, not this object.
  it('does not require an identity field it is going to drop', () => {
    const { id: _id, ...withoutId } = base();
    expect(() => normalizeModelState(model, withoutId)).not.toThrow();
  });

  it('keeps an empty list, which is a complete value', () => {
    expect(normalizeModelState(model, base()).tags).toEqual([]);
  });

  it('refuses a missing non-nullable field', () => {
    const { position: _position, ...withoutPosition } = base();
    expect(() => normalizeModelState(model, withoutPosition)).toThrow(
      'is missing "position"',
    );
  });

  it('refuses a list field that is not a list', () => {
    expect(() => normalizeModelState(model, base({ tags: 'no' }))).toThrow(
      'must be a list',
    );
  });

  it('refuses a field the Model does not declare', () => {
    expect(() =>
      normalizeModelState(model, base({ nope: 1 })),
    ).toThrow('unknown field "nope"');
  });

  // An Int rides the wire as a plain JSON number. Canonical JSON cannot encode
  // a bigint, so widening one here would make every page carrying an Int fail
  // to serialize — and the client would loop on that page forever.
  it('carries an Int as a plain number', () => {
    const normalized = normalizeModelState(model, base({ position: 7 }));
    expect(normalized.position).toBe(7);
  });

  it('carries the elements of an Int list as numbers too', () => {
    expect(normalizeModelState(model, base({ sizes: [1, 2] })).sizes).toEqual([
      1, 2,
    ]);
  });

  it('narrows a bigint a binding happened to hand over', () => {
    expect(normalizeModelState(model, base({ position: 7n })).position).toBe(7);
  });

  it('refuses an Int no client could read back', () => {
    expect(() =>
      normalizeModelState(
        model,
        base({ position: BigInt(Number.MAX_SAFE_INTEGER) + 1n }),
      ),
    ).toThrow('must be a safe integer');
  });

  it('carries a nullable Int holding null as null rather than widening it', () => {
    expect(normalizeModelState(model, base({ width: null })).width).toBeNull();
  });

  it('refuses an Int that is not a safe integer', () => {
    expect(() => normalizeModelState(model, base({ position: 1.5 }))).toThrow(
      'must be a safe integer',
    );
  });
});
