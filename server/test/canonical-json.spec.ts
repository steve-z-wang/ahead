import {
  canonicalJson,
  canonicalJsonSha256,
  canonicalJsonUtf8,
} from '../src';

describe('canonical JSON', () => {
  it('sorts object keys recursively and preserves array order', () => {
    expect(
      canonicalJson({
        z: [{ b: 2, a: 1 }, { d: 4, c: 3 }],
        a: { beta: true, alpha: null },
      }),
    ).toBe(
      '{"a":{"alpha":null,"beta":true},"z":[{"a":1,"b":2},{"c":3,"d":4}]}',
    );
  });

  it('encodes stable UTF-8 bytes', () => {
    expect(canonicalJsonUtf8({ label: '家庭' })).toEqual(
      Buffer.from('{"label":"家庭"}', 'utf8'),
    );
  });

  it('hashes the canonical UTF-8 representation', () => {
    expect(canonicalJsonSha256({ b: 2, a: 1 })).toBe(
      canonicalJsonSha256({ a: 1, b: 2 }),
    );
    expect(canonicalJsonSha256({ a: 2, b: 1 })).not.toBe(
      canonicalJsonSha256({ a: 1, b: 2 }),
    );
  });

  it.each([
    ['undefined', undefined],
    ['a function', () => undefined],
    ['a symbol', Symbol('value')],
    ['a bigint', 1n],
    ['NaN', Number.NaN],
    ['Infinity', Number.POSITIVE_INFINITY],
    ['undefined nested in an object', { value: undefined }],
    ['undefined nested in an array', [undefined]],
    ['a non-plain object', new Date('2026-08-03T00:00:00Z')],
  ])('rejects %s', (_name, input) => {
    expect(() => canonicalJson(input)).toThrow(TypeError);
  });

  it('rejects cyclic objects', () => {
    const input: Record<string, unknown> = {};
    input.self = input;

    expect(() => canonicalJson(input)).toThrow(TypeError);
  });
});
