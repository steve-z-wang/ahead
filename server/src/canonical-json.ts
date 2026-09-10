import { createHash } from 'node:crypto';

export function canonicalJson(input: unknown): string {
  return encode(input, new WeakSet<object>());
}

export function canonicalJsonUtf8(input: unknown): Buffer {
  return Buffer.from(canonicalJson(input), 'utf8');
}

export function canonicalJsonSha256(input: unknown): string {
  return createHash('sha256').update(canonicalJsonUtf8(input)).digest('hex');
}

function encode(input: unknown, ancestors: WeakSet<object>): string {
  if (input === null || typeof input === 'boolean' || typeof input === 'string') {
    return JSON.stringify(input);
  }
  if (typeof input === 'number') {
    if (!Number.isFinite(input)) throw invalidJson();
    return JSON.stringify(input);
  }
  if (typeof input !== 'object') throw invalidJson();
  if (ancestors.has(input)) throw new TypeError('canonical JSON cannot be cyclic');

  ancestors.add(input);
  try {
    if (Array.isArray(input)) {
      return `[${input.map((value) => encode(value, ancestors)).join(',')}]`;
    }

    const prototype = Object.getPrototypeOf(input);
    if (prototype !== Object.prototype && prototype !== null) {
      throw invalidJson();
    }
    if (Object.getOwnPropertySymbols(input).length !== 0) throw invalidJson();
    const record = input as Record<string, unknown>;
    const entries = Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${encode(record[key], ancestors)}`);
    return `{${entries.join(',')}}`;
  } finally {
    ancestors.delete(input);
  }
}

function invalidJson(): TypeError {
  return new TypeError('value is not canonical JSON data');
}
