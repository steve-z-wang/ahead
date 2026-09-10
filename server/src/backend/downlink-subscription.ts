import { CommittedChanges } from './committed-changes';
import { PrincipalSubscription } from './context';
import { validateSyncId } from './downlink-cursor';
import {
  decodeDownlinkRequestEnvelope,
  encodeDownlinkRequestEnvelope,
} from './json-envelope';
import { DownlinkMaterializer } from './downlink-materializer';
import { LocalSyncProtocolError } from './errors';
import { DownlinkPage } from './local-sync-backend';
import { GeneratedBackendContract } from './model-binding';

export interface DownlinkSubscriptionInput extends PrincipalSubscription {
  readonly signal: AbortSignal;
  /** Called synchronously after the durable wake listener is installed. */
  readonly onListening?: () => void;
  /** Handshake mode: wait for a post-registration commit before the first Pull. */
  readonly waitForCommit?: boolean;
}

export interface DownlinkSubscriptions {
  subscribe(input: DownlinkSubscriptionInput): AsyncGenerator<DownlinkPage>;
  close(): void;
}

export function createDownlinkSubscriptions(options: {
  readonly contract: GeneratedBackendContract;
  readonly materializer: DownlinkMaterializer;
  readonly committedChanges: CommittedChanges;
}): DownlinkSubscriptions {
  return new DefaultDownlinkSubscriptions(
    options.contract,
    options.materializer,
    options.committedChanges,
  );
}

class DefaultDownlinkSubscriptions implements DownlinkSubscriptions {
  private readonly active = new Set<AbortController>();
  private closed = false;

  constructor(
    private readonly contract: GeneratedBackendContract,
    private readonly materializer: DownlinkMaterializer,
    private readonly committedChanges: CommittedChanges,
  ) {}

  subscribe(input: DownlinkSubscriptionInput): AsyncGenerator<DownlinkPage> {
    if (this.closed) throw new Error('LocalSync Downlink subscriptions are closed');
    if (!isAbortSignal(input.signal)) {
      throw new LocalSyncProtocolError('Downlink subscription requires an AbortSignal');
    }
    if (
      input.onListening !== undefined &&
      typeof input.onListening !== 'function'
    ) {
      throw new LocalSyncProtocolError('onListening must be a function');
    }
    if (
      input.waitForCommit !== undefined &&
      typeof input.waitForCommit !== 'boolean'
    ) {
      throw new LocalSyncProtocolError('waitForCommit must be a boolean');
    }
    if (
      typeof input.principal?.userId !== 'string' ||
      input.principal.userId.trim().length === 0 ||
      !(input.requestBytes instanceof Uint8Array)
    ) {
      throw new LocalSyncProtocolError('invalid authenticated Downlink subscription');
    }
    const request = decodeDownlinkRequestEnvelope(input.requestBytes);
    return this.run(input, request.clientId, request.scope, request.afterSyncId);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    for (const controller of this.active) controller.abort();
  }

  private async *run(
    input: DownlinkSubscriptionInput,
    clientId: string,
    scope: string,
    initialAfterSyncId: bigint,
  ): AsyncGenerator<DownlinkPage> {
    if (input.signal.aborted || this.closed) return;
    const controller = new AbortController();
    this.active.add(controller);
    const abort = () => controller.abort();
    input.signal.addEventListener('abort', abort, { once: true });
    let pending = input.waitForCommit !== true;
    let waiter:
      | { readonly resolve: () => void; readonly abort: () => void }
      | undefined;
    const finishWait = () => {
      const current = waiter;
      waiter = undefined;
      if (current === undefined) return;
      controller.signal.removeEventListener('abort', current.abort);
      current.resolve();
    };
    const wake = () => {
      pending = true;
      finishWait();
    };

    try {
      this.committedChanges.subscribe(
        scope,
        wake,
        controller.signal,
      );
      input.onListening?.();
      let afterSyncId = initialAfterSyncId;
      while (!controller.signal.aborted) {
        if (!pending) {
          await new Promise<void>((resolve) => {
            const abortWait = () => finishWait();
            waiter = { resolve, abort: abortWait };
            controller.signal.addEventListener('abort', abortWait, { once: true });
            if (controller.signal.aborted || pending) finishWait();
          });
          if (controller.signal.aborted) break;
        }
        pending = false;
        const materialized = await this.materializer.pull({
          principal: input.principal,
          requestBytes: encodeDownlinkRequestEnvelope({
            clientId,
            scope,
            afterSyncId,
          }),
        });
        const page = decodePage(materialized.bytes, afterSyncId);
        const shouldYield =
          page.throughSyncId > afterSyncId || page.changes.length > 0;
        if (!shouldYield) continue;
        yield Object.freeze({
          bytes: Uint8Array.from(materialized.bytes),
        });
        afterSyncId = page.throughSyncId;
        if (page.changes.length === 50) pending = true;
      }
    } finally {
      input.signal.removeEventListener('abort', abort);
      controller.abort();
      this.active.delete(controller);
      finishWait();
    }
  }
}

function decodePage(
  bytes: Uint8Array,
  expectedFromSyncId: bigint,
): {
  readonly throughSyncId: bigint;
  readonly changes: readonly unknown[];
} {
  let value: unknown;
  try {
    value = JSON.parse(Buffer.from(bytes).toString('utf8'));
  } catch {
    throw new Error('LocalSync Downlink materializer returned an invalid page');
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('LocalSync Downlink materializer returned an invalid page');
  }
  const page = value as Record<string, unknown>;
  const fromSyncId = validateSyncId(
    BigInt(page.fromCursor as number),
    'page start',
  );
  const throughSyncId = validateSyncId(
    BigInt(page.toCursor as number),
    'page end',
  );
  if (
    fromSyncId !== expectedFromSyncId ||
    throughSyncId < fromSyncId ||
    !Array.isArray(page.changes) ||
    page.changes.length > 50 ||
    (page.changes.length > 0 && throughSyncId === fromSyncId)
  ) {
    throw new Error('LocalSync Downlink materializer returned an invalid page');
  }
  return { throughSyncId, changes: page.changes };
}

function isAbortSignal(value: unknown): value is AbortSignal {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as AbortSignal).aborted === 'boolean' &&
    typeof (value as AbortSignal).addEventListener === 'function' &&
    typeof (value as AbortSignal).removeEventListener === 'function'
  );
}
