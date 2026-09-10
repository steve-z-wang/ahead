import { LocalSyncProtocolError } from './errors';

export const downlinkPageSize = 50;

const maximumSignedInt64 = (1n << 63n) - 1n;

export interface DownlinkCursor {
  readonly clientId: string;
  readonly afterSyncId: bigint;
}

export function decodeDownlinkCursor(value: unknown): DownlinkCursor {
  const request = record(value, 'Downlink request');
  exactKeys(request, ['clientId', 'afterSyncId'], 'Downlink request');
  if (typeof request.clientId !== 'string' || request.clientId.trim().length === 0) {
    throw new LocalSyncProtocolError('clientId must be nonblank');
  }
  if (
    typeof request.afterSyncId !== 'bigint' ||
    request.afterSyncId < 0n ||
    request.afterSyncId > maximumSignedInt64
  ) {
    throw new LocalSyncProtocolError('afterSyncId must be a nonnegative int64');
  }
  return Object.freeze({
    clientId: request.clientId,
    afterSyncId: request.afterSyncId,
  });
}

export function validateSyncId(value: unknown, description: string): bigint {
  if (typeof value !== 'bigint' || value < 0n || value > maximumSignedInt64) {
    throw new Error(`LocalSync storage returned an invalid ${description}`);
  }
  return value;
}

function record(value: unknown, description: string): Record<string, unknown> {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    (Object.getPrototypeOf(value) !== Object.prototype &&
      Object.getPrototypeOf(value) !== null)
  ) {
    throw new LocalSyncProtocolError(`${description} must be an object`);
  }
  return value as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
  description: string,
): void {
  const actual = Object.keys(value).filter((key) => value[key] !== undefined).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new LocalSyncProtocolError(`${description} has invalid fields`);
  }
}
