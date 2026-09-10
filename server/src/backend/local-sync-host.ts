import {
  IncomingMessage,
  Server,
  ServerResponse,
  createServer,
} from 'node:http';
import { Duplex } from 'node:stream';
import { WebSocket, WebSocketServer } from 'ws';
import type { RawData } from 'ws';

import {
  LocalSyncBackendOptions,
  validateBackendOptions,
} from './backend-options';
import { AuthenticatedPrincipal, ScopeAuthorizer } from './context';
import { createLocalSyncBackend } from './create-local-sync-backend';
import { validateSyncId } from './downlink-cursor';
import {
  LocalSyncMutationRejected,
  LocalSyncMutationVersionUnsupported,
  LocalSyncOwnerMismatchError,
  LocalSyncProtocolError,
  LocalSyncScopeForbiddenError,
  LocalSyncSequenceError,
} from './errors';
import {
  decodeLiveSubscribeEnvelope,
  encodeDownlinkRequestEnvelope,
  encodeLiveSubscribedEnvelope,
} from './json-envelope';
import {
  DownlinkPage,
  LocalSyncBackend,
  ScopeLedger,
} from './local-sync-backend';

/**
 * How the host learns who is calling. The product owns credentials; the
 * framework only asks, and only ever gets a user id back.
 */
export interface LocalSyncCredentials {
  /** The bearer token, or undefined when the caller sent none. */
  readonly token: string | undefined;
  /** The client build, when it declared one — the min-build gate reads this. */
  readonly build: number | undefined;
}

export interface LocalSyncAuthentication {
  authenticate(
    credentials: LocalSyncCredentials,
  ): Promise<AuthenticatedPrincipal | null>;
}

/**
 * Told when a live channel opens and closes, once per socket.
 *
 * The host knows one thing — a named socket exists, and now it doesn't — and
 * says only that. What "online" means, and how a person holding two sockets
 * counts, belong to the product that implements this.
 */
export interface LocalSyncPresence {
  onConnected(userId: string): void;
  onDisconnected(userId: string): void;
}

export type LocalSyncHostRoute = 'pull' | 'mutations' | 'live';

export interface LocalSyncHostFailure {
  readonly error: unknown;
  readonly route: LocalSyncHostRoute;
  readonly principal?: AuthenticatedPrincipal;
}

export interface LocalSyncFailureObserver {
  onUnexpectedFailure(failure: LocalSyncHostFailure): void;
}

export interface LocalSyncHostOptions<
  TTx,
> extends LocalSyncBackendOptions<TTx> {
  readonly authentication: LocalSyncAuthentication;
  /**
   * Builds below this may not hold a live channel (CAP-157). Absent or
   * malformed on the wire passes: only release builds declare one, and the
   * REST 426 is the user-visible signal — this only stops deliveries.
   */
  readonly minBuild?: number;
  /** Optional: the product's presence map, if it keeps one. */
  readonly presence?: LocalSyncPresence;
  /** Optional product-owned sink for failures the host consumes as server errors. */
  readonly failureObserver?: LocalSyncFailureObserver;

  /**
   * How often the host pings each live socket (CAP-447). Proxies cut a
   * connection that carries no frames for their idle window (~100s on the
   * observed Cloudflare + Railway chain), and the CLIENT'S own ping stops
   * the moment the phone suspends the app — so longevity must come from the
   * side that never sleeps. A socket that misses one full interval's pong
   * is reaped rather than left half-open; the client's redial remains the
   * fallback it always was. Default 30s: comfortably inside every proxy
   * window on the chain.
   */
  readonly heartbeatMillis?: number;
}

const maximumRequestBytes = 1024 * 1024;

/**
 * The framework's own server: three fixed routes, no router, and `ws` as its
 * only dependency beyond node itself.
 *
 * The product hands it the generated contract, its bindings, its storage and
 * its credential, and gets back the whole of its contact surface. What the
 * host adds over the pipe below it is exactly what a transport owes: read the
 * caller, read the body, hand back the answer — and for the live channel, keep
 * one negotiated scope set per socket and stop it when the socket goes.
 */
export class LocalSyncHost<TTx> {
  private readonly backend: LocalSyncBackend<TTx>;
  private readonly persistence: LocalSyncHostOptions<TTx>['persistence'];
  private readonly scopeAuthorizer: ScopeAuthorizer<TTx>;
  private readonly authentication: LocalSyncAuthentication;
  private readonly minBuild: number | undefined;
  private readonly presence: LocalSyncPresence | undefined;
  private readonly failureObserver: LocalSyncFailureObserver | undefined;
  private readonly server: Server;
  private readonly sockets = new WebSocketServer({
    noServer: true,
    maxPayload: maximumRequestBytes,
  });
  private readonly live = new Set<AbortController>();
  private readonly heartbeatMillis: number;
  /** Sockets that have answered since the last sweep — see [sweep]. */
  private readonly answered = new WeakSet<WebSocket>();
  private heartbeat: NodeJS.Timeout | null = null;
  private closing = false;

  constructor(options: LocalSyncHostOptions<TTx>) {
    this.backend = createLocalSyncBackend(options);
    const components = validateBackendOptions(options);
    this.persistence = components.persistence;
    this.scopeAuthorizer = components.scopeAuthorizer;
    this.authentication = options.authentication;
    this.minBuild = options.minBuild;
    this.presence = options.presence;
    this.failureObserver = options.failureObserver;
    this.heartbeatMillis = options.heartbeatMillis ?? 30_000;
    this.server = createServer((request, response) => {
      void this.route(request, response);
    });
    this.server.on('upgrade', (request, socket, head) => {
      void this.upgrade(request, socket, head);
    });
  }

  /** The one thing the product reaches past the wire for: its Scope Ledgers. */
  get scopeLedger(): ScopeLedger<TTx> {
    return this.backend.scopeLedger;
  }

  /** Resolves with the port actually bound — port 0 means "any free one". */
  listen(port: number, host = '0.0.0.0'): Promise<number> {
    this.heartbeat ??= setInterval(() => this.sweep(), this.heartbeatMillis);
    return new Promise((resolve, reject) => {
      const failed = (error: Error): void => reject(error);
      this.server.once('error', failed);
      this.server.listen(port, host, () => {
        this.server.off('error', failed);
        const address = this.server.address();
        resolve(
          typeof address === 'object' && address !== null ? address.port : port,
        );
      });
    });
  }

  async close(): Promise<void> {
    if (this.closing) return;
    this.closing = true;
    if (this.heartbeat !== null) clearInterval(this.heartbeat);
    this.heartbeat = null;
    for (const controller of this.live) controller.abort();
    for (const socket of this.sockets.clients) socket.close(1001, 'closing');
    await new Promise<void>((resolve) => this.sockets.close(() => resolve()));
    // A keep-alive connection nobody is using still holds the server open.
    this.server.closeIdleConnections();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
    await this.backend.close();
  }

  /**
   * One heartbeat pass (CAP-447): a socket that answered since the last pass
   * is pinged again; one that did not is dead to the proxy chain anyway and
   * is terminated, which runs the connection's ordinary teardown (presence
   * retraction included). Reap-then-ping means a silent peer lives at most
   * two intervals.
   */
  private sweep(): void {
    for (const socket of this.sockets.clients) {
      if (!this.answered.has(socket)) {
        socket.terminate();
        continue;
      }
      this.answered.delete(socket);
      if (socket.readyState === socket.OPEN) socket.ping();
    }
  }

  private async route(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    const path = (request.url ?? '').split('?')[0];
    if (request.method !== 'POST') return send(response, 405, 'method');
    if (path !== '/sync/mutations' && path !== '/sync/pull') {
      return send(response, 404, 'route');
    }

    let principal: AuthenticatedPrincipal | null;
    try {
      principal = await this.authentication.authenticate(credentials(request));
    } catch (error) {
      this.observeUnexpected(
        error,
        path === '/sync/pull' ? 'pull' : 'mutations',
      );
      return send(response, 500, 'server');
    }
    if (principal === null) return send(response, 401, 'unauthorized');

    let body: Uint8Array;
    try {
      body = await read(request);
    } catch (error) {
      // A caller that hung up is not a caller that sent too much.
      if (error instanceof RequestTooLarge) return send(response, 413, 'body');
      return;
    }

    try {
      if (path === '/sync/mutations') {
        const answer = await this.backend.upload({
          principal,
          requestBytes: body,
        });
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end(Buffer.from(answer));
        return;
      }
      const page = await this.backend.pullDownlink({
        principal,
        requestBytes: body,
      });
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(Buffer.from(page.bytes));
    } catch (error) {
      const classification = classify(error);
      if (classification.kind === 'unexpected') {
        this.observeUnexpected(
          error,
          path === '/sync/pull' ? 'pull' : 'mutations',
          principal,
        );
      }
      if (error instanceof LocalSyncMutationVersionUnsupported) {
        response.writeHead(409, { 'content-type': 'application/json' });
        response.end(
          JSON.stringify({
            code: error.code,
            ordinal: Number(error.ordinal),
            name: error.mutationName,
            version: error.version,
          }),
        );
      } else {
        send(response, classification.status, classification.code);
      }
    }
  }

  private observeUnexpected(
    error: unknown,
    route: LocalSyncHostRoute,
    principal?: AuthenticatedPrincipal,
  ): void {
    try {
      this.failureObserver?.onUnexpectedFailure(
        principal === undefined
          ? { error, route }
          : { error, route, principal },
      );
    } catch {
      // Reporting is best effort; it must never replace the safe wire outcome.
    }
  }

  /**
   * One socket, one partitioned scope subscription. Every live page carries
   * its own scope and cursor interval; a rejected member cannot starve the
   * accepted members, which still owe one HTTP catch-up after the listener
   * boundary.
   */
  private async upgrade(
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer,
  ): Promise<void> {
    const path = (request.url ?? '').split('?')[0];
    if (path !== '/sync/live' || this.closing) return refuse(socket, 404);

    const declared = credentials(request);
    if (
      this.minBuild !== undefined &&
      declared.build !== undefined &&
      declared.build < this.minBuild
    ) {
      return refuse(socket, 426);
    }

    let principal: AuthenticatedPrincipal | null;
    try {
      principal = await this.authentication.authenticate(declared);
    } catch (error) {
      this.observeUnexpected(error, 'live');
      return refuse(socket, 500);
    }
    if (principal === null) return refuse(socket, 401);
    if (this.closing) return refuse(socket, 503);

    this.sockets.handleUpgrade(request, socket, head, (connection) => {
      void this.serve(connection, principal);
    });
  }

  private async serve(
    connection: WebSocket,
    principal: AuthenticatedPrincipal,
  ): Promise<void> {
    const controller = new AbortController();
    this.live.add(controller);
    const stop = (): void => controller.abort();
    connection.on('close', stop);
    connection.on('error', stop);
    // Enters the sweep alive; each pong renews it (the peer answers the
    // protocol ping automatically — no client code is involved).
    this.answered.add(connection);
    connection.on('pong', () => this.answered.add(connection));
    // Announced here and retracted in the `finally` below, so the pair is
    // balanced whatever happens in between — including a subscription that
    // never starts.
    this.presence?.onConnected(principal.userId);

    const streams: Array<{
      readonly pages: AsyncGenerator<DownlinkPage>;
      next: Promise<IteratorResult<DownlinkPage>>;
    }> = [];
    const rejectFurtherFrames = (): void => {
      if (connection.readyState === connection.OPEN) {
        connection.close(1002, 'subscribe is the only client frame');
      }
    };
    try {
      const firstFrame = await receiveFirstFrame(connection, controller.signal);
      connection.on('message', rejectFurtherFrames);
      const handshake = decodeLiveSubscribeEnvelope(firstFrame);
      const negotiation = await this.persistence.transactions.readSnapshot(
        async (transaction) => {
          const accepted: Array<{ scope: string; afterSyncId: bigint }> = [];
          const rejections: Array<{ scope: string; code: string }> = [];
          for (const scope of handshake.scopes) {
            const canRead = await this.scopeAuthorizer.canRead(
              { transaction, viewerUserId: principal.userId },
              scope,
            );
            if (!canRead) {
              rejections.push({ scope, code: 'scope.forbidden' });
              continue;
            }
            accepted.push({
              scope,
              afterSyncId: validateSyncId(
                await this.persistence.storage.readDownlinkHead(
                  transaction,
                  scope,
                ),
                'Downlink head',
              ),
            });
          }
          return { accepted, rejections };
        },
      );
      if (controller.signal.aborted) return;
      const listening = negotiation.accepted.map(({ scope, afterSyncId }) => {
        let ready!: () => void;
        const registered = new Promise<void>((resolve) => {
          ready = resolve;
        });
        const pages = this.backend.subscribeDownlink({
          principal,
          requestBytes: encodeDownlinkRequestEnvelope({
            clientId: 'live',
            scope,
            afterSyncId,
          }),
          signal: controller.signal,
          onListening: ready,
          waitForCommit: true,
        });
        const next = pages.next();
        streams.push({ pages, next });
        return Promise.race([
          registered,
          next.then((result) => {
            if (result.done) {
              throw new Error('Downlink subscription ended before listening');
            }
          }),
        ]);
      });
      await Promise.all(listening);
      if (
        controller.signal.aborted ||
        connection.readyState !== connection.OPEN
      ) {
        return;
      }
      connection.send(
        Buffer.from(
          encodeLiveSubscribedEnvelope({
            scopes: negotiation.accepted.map(({ scope }) => scope),
            rejections: negotiation.rejections,
          }),
        ),
      );

      if (streams.length === 0) {
        await waitForAbort(controller.signal);
        return;
      }

      while (streams.length > 0) {
        const winner = await Promise.race(
          streams.map((stream, index) =>
            stream.next.then((result) => ({ index, result })),
          ),
        );
        const stream = streams[winner.index];
        if (winner.result.done) {
          streams.splice(winner.index, 1);
          continue;
        }
        const page = winner.result.value;
        if (controller.signal.aborted) break;
        if (connection.readyState !== connection.OPEN) break;
        connection.send(Buffer.from(page.bytes));
        stream.next = stream.pages.next();
      }
    } catch (error) {
      if (
        !controller.signal.aborted &&
        !(error instanceof LocalSyncProtocolError)
      ) {
        this.observeUnexpected(error, 'live', principal);
      }
      closeLive(connection, error);
    } finally {
      controller.abort();
      this.live.delete(controller);
      this.presence?.onDisconnected(principal.userId);
      connection.off('close', stop);
      connection.off('error', stop);
      connection.off('message', rejectFurtherFrames);
      await Promise.all(
        streams.map((stream) =>
          stream.pages.return(undefined as never).catch(() => undefined),
        ),
      );
      if (connection.readyState === connection.OPEN) connection.close();
    }
  }
}

function receiveFirstFrame(
  connection: WebSocket,
  signal: AbortSignal,
): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const cleanup = (): void => {
      connection.off('message', message);
      connection.off('close', closed);
      connection.off('error', failed);
      signal.removeEventListener('abort', aborted);
    };
    const message = (data: RawData): void => {
      cleanup();
      const buffer = Array.isArray(data)
        ? Buffer.concat(data)
        : Buffer.from(data as ArrayBuffer);
      resolve(Uint8Array.from(buffer));
    };
    const closed = (): void => {
      cleanup();
      reject(
        new LocalSyncProtocolError('live handshake closed before subscribe'),
      );
    };
    const failed = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const aborted = (): void => {
      cleanup();
      reject(new Error('live handshake aborted'));
    };
    connection.once('message', message);
    connection.once('close', closed);
    connection.once('error', failed);
    signal.addEventListener('abort', aborted, { once: true });
    if (signal.aborted) aborted();
  });
}

function waitForAbort(signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    signal.addEventListener('abort', () => resolve(), { once: true });
  });
}

function closeLive(connection: WebSocket, error: unknown): void {
  if (connection.readyState !== connection.OPEN) return;
  if (error instanceof LocalSyncProtocolError) {
    connection.close(1002, 'request.invalid');
    return;
  }
  connection.close(1011, 'server');
}

function credentials(request: IncomingMessage): LocalSyncCredentials {
  // Bearer or nothing. Handing a "Basic …" string to Firebase would ask it
  // about a credential this protocol never accepts.
  const header = request.headers.authorization;
  const bearer =
    typeof header === 'string' ? /^Bearer\s+(.+)$/i.exec(header.trim()) : null;
  const token = bearer === null ? undefined : bearer[1].trim() || undefined;
  const declared = Number(
    new URL(request.url ?? '/', 'http://localhost').searchParams.get('build'),
  );
  return {
    token,
    build: Number.isInteger(declared) && declared > 0 ? declared : undefined,
  };
}

class RequestTooLarge extends Error {
  override readonly name = 'RequestTooLarge';
}

function read(request: IncomingMessage): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > maximumRequestBytes) {
        reject(new RequestTooLarge('body too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Uint8Array.from(Buffer.concat(chunks))));
    request.on('error', reject);
  });
}

/**
 * The status table, and the only place a failure becomes one. It mirrors the
 * client's: a refusal the server decided from the request is terminal, and
 * everything else is the server's own trouble, which retrying can outlive.
 */
type FailureClassification =
  | {
      readonly kind: 'expected';
      readonly status: number;
      readonly code: string;
    }
  | {
      readonly kind: 'unexpected';
      readonly status: 500;
      readonly code: 'server';
    };

function classify(error: unknown): FailureClassification {
  if (error instanceof LocalSyncMutationVersionUnsupported) {
    return { kind: 'expected', status: 409, code: error.code };
  }
  if (error instanceof LocalSyncSequenceError) {
    return { kind: 'expected', status: 409, code: error.reason };
  }
  if (error instanceof LocalSyncOwnerMismatchError) {
    return {
      kind: 'expected',
      status: 403,
      code: 'client.owner_mismatch',
    };
  }
  if (error instanceof LocalSyncScopeForbiddenError) {
    return { kind: 'expected', status: 403, code: error.code };
  }
  if (error instanceof LocalSyncProtocolError) {
    return { kind: 'expected', status: 400, code: 'request.invalid' };
  }
  if (error instanceof LocalSyncMutationRejected) {
    return { kind: 'expected', status: 400, code: error.code };
  }
  return { kind: 'unexpected', status: 500, code: 'server' };
}

function send(response: ServerResponse, status: number, code: string): void {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ code }));
}

function refuse(socket: Duplex, status: number): void {
  socket.write(`HTTP/1.1 ${status} \r\n\r\n`);
  socket.destroy();
}
