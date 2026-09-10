import { canonicalJsonSha256 } from '../canonical-json';
import { LocalSyncProtocolError } from './errors';

export function hashUplinkSemanticRequest(request: unknown): string {
  return canonicalJsonSha256(semanticValue(request, new WeakSet<object>()));
}

function semanticValue(value: unknown, ancestors: WeakSet<object>): unknown {
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'boolean'
  ) {
    return value;
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw invalidSemanticRequest();
    return Object.is(value, -0) ? 0 : value;
  }
  if (typeof value === 'bigint') {
    return { $localSyncInt64: value.toString() };
  }
  if (typeof value !== 'object' || value === undefined) {
    throw invalidSemanticRequest();
  }
  if (ancestors.has(value)) throw invalidSemanticRequest();
  ancestors.add(value);
  try {
    if (value instanceof Uint8Array) {
      return { $localSyncBytes: Buffer.from(value).toString('base64') };
    }
    if (Array.isArray(value)) {
      return value.map((item) => semanticValue(item, ancestors));
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw invalidSemanticRequest();
    }
    const record = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(record)
        .filter((key) => record[key] !== undefined)
        .sort()
        .map((key) => [key, semanticValue(record[key], ancestors)]),
    );
  } finally {
    ancestors.delete(value);
  }
}

function invalidSemanticRequest(): LocalSyncProtocolError {
  return new LocalSyncProtocolError('request is not canonical semantic data');
}
