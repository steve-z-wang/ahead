const machineCode = /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/;

/**
 * A mutation key spelled the way a rejection code is spelled: one word per
 * part, joined by `_` — `createMoment` becomes `create_moment`.
 *
 * The ONE speller of the `<mutation>.<reason>` namespace. The framework's own
 * precheck and a product's rejection translator must produce byte-identical
 * codes for the same act — a precheck refusal and a resolver refusal are
 * indistinguishable on the wire, and only a single producer keeps that true.
 */
export function machineName(mutationKey: string): string {
  return mutationKey.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);
}

export class LocalSyncMutationRejected extends Error {
  override readonly name = 'LocalSyncMutationRejected';

  constructor(
    readonly code: string,
    message = code,
  ) {
    if (!machineCode.test(code)) {
      throw new RangeError(
        'rejection code must be a stable nonblank machine code',
      );
    }
    super(message);
  }
}

export class LocalSyncBackendOptionsError extends Error {
  override readonly name = 'LocalSyncBackendOptionsError';
}

export class LocalSyncIdentityError extends TypeError {
  override readonly name = 'LocalSyncIdentityError';
}

export class LocalSyncProtocolError extends Error {
  override readonly name = 'LocalSyncProtocolError';
}

/** A deployment cannot execute this contract. Never settle it as a rejected act. */
export class LocalSyncMutationVersionUnsupported extends Error {
  override readonly name = 'LocalSyncMutationVersionUnsupported';
  readonly code = 'mutation_version_unsupported';

  constructor(
    readonly ordinal: bigint,
    readonly mutationName: string,
    readonly version: number,
  ) {
    super(`Unsupported ${mutationName} version ${version}`);
  }
}

export class LocalSyncScopeForbiddenError extends Error {
  override readonly name = 'LocalSyncScopeForbiddenError';
  readonly code = 'scope.forbidden';
}

export class LocalSyncOwnerMismatchError extends Error {
  override readonly name = 'LocalSyncOwnerMismatchError';
}

export type LocalSyncSequenceFailureReason =
  | 'gap'
  | 'overlap'
  | 'request_conflict';

export class LocalSyncSequenceError extends Error {
  override readonly name = 'LocalSyncSequenceError';

  constructor(readonly reason: LocalSyncSequenceFailureReason) {
    super(`LocalSync Uplink sequence ${reason}`);
  }
}
