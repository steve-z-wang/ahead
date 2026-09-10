import { canonicalJsonUtf8 } from '../canonical-json';
import { LocalSyncProtocolError } from './errors';
import { normalizeScopes } from './scopes';

/**
 * The wire, and the only place that knows its spelling.
 *
 * The envelope names cursors and positions the way the protocol declares them
 * (`fromCursor`, `toCursor`, `ordinal`, `identity`, `state`); the pipe behind
 * this file keeps the names it has always used. The translation is one-way
 * traffic through here, so renaming a wire field never reaches the executor and
 * renaming an internal one never reaches a client.
 *
 * Two rules the wire carries: unknown fields are ignored on read, so the server
 * may gain a field without older clients refusing the page, and a `state` of
 * null is absence — the row was deleted or the viewer may no longer read it.
 */

const maximumSignedInt64 = (1n << 63n) - 1n;
const maximumBatchMutations = 20;

export type UplinkOperation = 'create' | 'update' | 'delete';

/**
 * One addressed mutation, structure only.
 *
 * The envelope proves just enough to answer positionally: that this is an
 * object and which ordinal it speaks for. What it SAYS — the Model, the
 * operation, the identity, the values — is the executor's to validate, one
 * mutation at a time, so a single malformed entry is rejected in place instead
 * of refusing the batch its neighbours are in.
 */
export interface UplinkMutationEnvelope {
  readonly ordinal: bigint;
  readonly raw: Readonly<Record<string, unknown>>;
}

export interface UplinkRequestEnvelope {
  readonly clientId: string;
  readonly batchSequence: bigint;
  readonly mutations: readonly UplinkMutationEnvelope[];
  /** What the receipt hashes, so a replayed batch is recognised by meaning. */
  readonly semanticValue: unknown;
}

export interface UplinkRejectionEnvelope {
  readonly ordinal: bigint;
  readonly code: string;
}

export interface UplinkRequiredCheckpointEnvelope {
  readonly scope: string;
  readonly syncId: bigint;
}

export interface UplinkResponseEnvelope {
  readonly requiredCheckpoints: readonly UplinkRequiredCheckpointEnvelope[];
  /** Legacy principal checkpoint retained while older clients are supported. */
  readonly requiredScope: string;
  /** Legacy principal checkpoint retained while older clients are supported. */
  readonly requiredSyncId: bigint;
  readonly rejections: readonly UplinkRejectionEnvelope[];
}

export interface DownlinkRequestEnvelope {
  readonly clientId: string;
  readonly scope: string;
  readonly afterSyncId: bigint;
}

export interface DownlinkChangeEnvelope {
  readonly syncId: bigint;
  readonly model: string;
  readonly identity: object;
  readonly state: object | null;
}

export interface DownlinkPageEnvelope {
  readonly scope: string;
  readonly fromSyncId: bigint;
  readonly throughSyncId: bigint;
  readonly changes: readonly DownlinkChangeEnvelope[];
}

export interface LiveSubscribeEnvelope {
  readonly scopes: readonly string[];
}

export interface LiveScopeRejectionEnvelope {
  readonly scope: string;
  readonly code: string;
}

export interface LiveSubscribedEnvelope {
  readonly scopes: readonly string[];
  readonly rejections: readonly LiveScopeRejectionEnvelope[];
}

export function decodeUplinkRequestEnvelope(
  bytes: Uint8Array,
): UplinkRequestEnvelope {
  const request = readObject(bytes);
  const clientId = nonblankString(request.clientId, 'clientId');
  const batchSequence = positiveInt64(request.batchSequence, 'batchSequence');
  const rawMutations = request.mutations;
  if (
    !Array.isArray(rawMutations) ||
    rawMutations.length === 0 ||
    rawMutations.length > maximumBatchMutations
  ) {
    throw new LocalSyncProtocolError(
      'Uplink must contain 1 through 20 mutations',
    );
  }
  const ordinals = new Set<bigint>();
  const mutations = rawMutations.map((value, index) => {
    const mutation = record(value, `mutations[${index}]`);
    const ordinal = positiveInt64(
      mutation.ordinal,
      `mutations[${index}].ordinal`,
    );
    if (ordinals.has(ordinal)) {
      throw new LocalSyncProtocolError('mutation ordinals must be unique');
    }
    ordinals.add(ordinal);
    return Object.freeze({ ordinal, raw: mutation });
  });
  return Object.freeze({
    clientId,
    batchSequence,
    mutations: Object.freeze(mutations),
    semanticValue: request,
  });
}

export function encodeUplinkResponseEnvelope(
  response: UplinkResponseEnvelope,
): Uint8Array {
  return canonicalJsonUtf8({
    requiredCheckpoints: response.requiredCheckpoints.map((checkpoint) => ({
      scope: checkpoint.scope,
      syncId: safeNumber(checkpoint.syncId, 'required checkpoint syncId'),
    })),
    requiredScope: response.requiredScope,
    requiredSyncId: safeNumber(response.requiredSyncId, 'requiredSyncId'),
    rejections: response.rejections.map((rejection) => ({
      ordinal: safeNumber(rejection.ordinal, 'rejection ordinal'),
      code: rejection.code,
    })),
  });
}

export function decodeDownlinkRequestEnvelope(
  bytes: Uint8Array,
): DownlinkRequestEnvelope {
  const request = readObject(bytes);
  const clientId = nonblankString(request.clientId, 'clientId');
  const scope = decodeScope(request.scope);
  const afterSyncId = nonNegativeInt64(request.fromCursor, 'fromCursor');
  return Object.freeze({ clientId, scope, afterSyncId });
}

export function decodeLiveSubscribeEnvelope(
  bytes: Uint8Array,
): LiveSubscribeEnvelope {
  const request = readObject(bytes);
  if (request.type !== 'subscribe') {
    throw new LocalSyncProtocolError('live handshake must be subscribe');
  }
  if (!Array.isArray(request.scopes) || request.scopes.length === 0) {
    throw new LocalSyncProtocolError('live handshake scopes must be nonempty');
  }
  return Object.freeze({
    scopes: normalizeScopes(request.scopes.map(decodeScope)),
  });
}

function decodeScope(value: unknown): string {
  if (typeof value !== 'string') {
    throw new LocalSyncProtocolError('scope must be a string');
  }
  return value;
}

export function encodeLiveSubscribedEnvelope(
  response: LiveSubscribedEnvelope,
): Uint8Array {
  return canonicalJsonUtf8({
    type: 'subscribed',
    scopes: response.scopes,
    rejections: response.rejections.map((rejection) => ({
      scope: rejection.scope,
      code: rejection.code,
    })),
  });
}

/// The subscription re-asks the materializer for a page on the viewer's
/// behalf, so it speaks the same request the client would have sent.
export function encodeDownlinkRequestEnvelope(
  request: DownlinkRequestEnvelope,
): Uint8Array {
  return canonicalJsonUtf8({
    clientId: request.clientId,
    scope: request.scope,
    fromCursor: safeNumber(request.afterSyncId, 'fromCursor'),
  });
}

export function encodeDownlinkPageEnvelope(
  page: DownlinkPageEnvelope,
): Uint8Array {
  return canonicalJsonUtf8({
    scope: page.scope,
    fromCursor: safeNumber(page.fromSyncId, 'fromCursor'),
    toCursor: safeNumber(page.throughSyncId, 'toCursor'),
    changes: page.changes.map((change) => ({
      syncId: safeNumber(change.syncId, 'change syncId'),
      model: change.model,
      identity: change.identity,
      state: change.state,
    })),
  });
}

function readObject(bytes: Uint8Array): Readonly<Record<string, unknown>> {
  if (!(bytes instanceof Uint8Array)) {
    throw new LocalSyncProtocolError('envelope must be bytes');
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch (error) {
    throw new LocalSyncProtocolError(
      `envelope is not JSON: ${error instanceof Error ? error.message : 'parse failed'}`,
    );
  }
  return record(parsed, 'envelope');
}

function record(
  value: unknown,
  description: string,
): Readonly<Record<string, unknown>> {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    (Object.getPrototypeOf(value) !== Object.prototype &&
      Object.getPrototypeOf(value) !== null)
  ) {
    throw new LocalSyncProtocolError(`${description} must be an object`);
  }
  return value as Readonly<Record<string, unknown>>;
}

function nonblankString(value: unknown, description: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new LocalSyncProtocolError(`${description} must be a nonblank string`);
  }
  return value;
}

function nonNegativeInt64(value: unknown, description: string): bigint {
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < 0
  ) {
    throw new LocalSyncProtocolError(
      `${description} must be a non-negative safe integer`,
    );
  }
  return BigInt(value as number);
}

function positiveInt64(value: unknown, description: string): bigint {
  const result = nonNegativeInt64(value, description);
  if (result === 0n) {
    throw new LocalSyncProtocolError(`${description} must be positive`);
  }
  return result;
}

/**
 * Positions are int64 inside the pipe but JSON numbers on the wire, so a value
 * this client could not read back is a fault here rather than a silent
 * truncation on the far side.
 */
function safeNumber(value: bigint, description: string): number {
  if (
    typeof value !== 'bigint' ||
    value < 0n ||
    value > BigInt(Number.MAX_SAFE_INTEGER) ||
    value > maximumSignedInt64
  ) {
    throw new LocalSyncProtocolError(
      `${description} must be a non-negative safe integer`,
    );
  }
  return Number(value);
}
