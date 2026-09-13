import { createRequire } from "node:module";
import type { IncomingMessage, RequestListener, Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, WebSocket } from "ws";
export { WebSocket } from "ws";
const require = createRequire(import.meta.url);
export type Native = {
  validateConfig(config: string): void;
  processPush(
    config: string,
    owner: string,
    channel: string,
    request: string,
    callback: (request: string) => Promise<string>,
  ): Promise<string>;
  processPull(
    config: string,
    owner: string,
    request: string,
    callback: (request: string) => Promise<string>,
  ): Promise<string>;
  publish(
    config: string,
    changes: string,
    channels: string,
    callback: (request: string) => Promise<string>,
  ): Promise<string>;
  negotiateLive(
    owner: string,
    request: string,
    callback: (request: string) => Promise<string>,
  ): Promise<string>;
  pullLive(
    config: string,
    owner: string,
    scope: string,
    fromCursor: number,
    callback: (request: string) => Promise<string>,
  ): Promise<string>;
};
export interface Persistence {
  call(request: Record<string, any>): Promise<unknown>;
}
export class MutationRejected extends Error {
  readonly code: string;
  constructor(code: string) {
    if (!/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/.test(code))
      throw new Error("rejection code must be a stable machine code");
    super(code);
    this.code = code;
  }
}
export type Changes = readonly { model: string; identity: object }[];
export interface WriteContext<T> {
  transaction: T;
  actorUserId: string;
  publish(changes: Changes, channels: readonly string[]): Promise<unknown>;
}
export interface ReadContext<T> {
  transaction: T;
  viewerUserId: string;
  channel: string;
}
export type Handler<T, Input = Record<string, any>> = (
  context: WriteContext<T>,
  args: Input,
) => Promise<void | { channel: string }>;
export interface Loader<T> {
  load(
    context: ReadContext<T>,
    identities: readonly any[],
  ): Promise<readonly (object | null)[]>;
  prepareForViewer?(
    context: ReadContext<T>,
    identities: readonly any[],
  ): Promise<void>;
}
export interface BackendOptions<T> {
  config: object;
  /** Must provide a coherent snapshot and roll back rejected callbacks. Retry serialization failures. */
  transaction: <R>(body: (tx: T) => Promise<R>) => Promise<R>;
  persistence: (tx: T) => Persistence;
  principalChannel: (owner: string) => string;
  authorize: (context: ReadContext<T>) => Promise<boolean>;
  handlers: Record<string, Record<number, Handler<T, any>>>;
  loaders: Record<string, Loader<T>>;
  translateRejection?: (error: unknown) => string | null | undefined;
  native?: Native;
}
/** JSON cannot represent nonfinite values or undefined array items. Never turn either into null. */
function callbackJson(value: unknown): string {
  return JSON.stringify(value, (_key, item) => {
    if (typeof item === "bigint") {
      const number = Number(item);
      if (!Number.isSafeInteger(number))
        throw new Error("bigint outside safe integer range");
      return number;
    }
    if (typeof item === "number" && !Number.isFinite(item))
      throw new Error("nonfinite callback value");
    if (item === undefined) throw new Error("undefined callback value");
    return item;
  });
}
class WakeHub {
  private listeners = new Map<string, Set<() => void>>();
  subscribe(scope: string, wake: () => void): () => void {
    const listeners = this.listeners.get(scope) ?? new Set();
    listeners.add(wake);
    this.listeners.set(scope, listeners);
    return () => {
      listeners.delete(wake);
      if (!listeners.size) this.listeners.delete(scope);
    };
  }
  notify(scopes: Iterable<string>): void {
    for (const scope of new Set(scopes))
      for (const wake of [...(this.listeners.get(scope) ?? [])])
        queueMicrotask(wake);
  }
  clear(): void {
    this.listeners.clear();
  }
}
class Session {
  failed: unknown;
  closed = false;
  pending = new Set<Promise<unknown>>();
  touched = new Set<string>();
  savepoints = new Map<number, Set<string>>();
  track<R>(body: () => Promise<R>): Promise<R> {
    if (this.closed)
      return Promise.reject(new Error("transaction session closed"));
    const result = Promise.resolve()
      .then(body)
      .catch((error) => {
        this.failed ??= error;
        throw error;
      });
    this.pending.add(result);
    void result.then(
      () => this.pending.delete(result),
      () => this.pending.delete(result),
    );
    return result;
  }
  savepoint(ordinal: number): void {
    this.savepoints.set(ordinal, new Set(this.touched));
  }
  rollback(ordinal: number): void {
    this.touched = new Set(this.savepoints.get(ordinal) ?? []);
  }
  release(ordinal: number): void {
    this.savepoints.delete(ordinal);
  }
  async assertCommittable(): Promise<void> {
    const unawaited = this.pending.size > 0;
    while (this.pending.size) await Promise.allSettled([...this.pending]);
    if (this.failed !== undefined) throw this.failed;
    if (unawaited) throw new Error("unawaited transaction operations");
    if (this.closed) throw new Error("transaction session closed");
  }
}
export function createBackend<T>(options: BackendOptions<T>) {
  const native =
    options.native ?? (require("../../bindings/node/otter-node.node") as Native);
  const config = JSON.stringify({
    ...options.config,
    loaders: Object.keys(options.loaders),
  });
  native.validateConfig(config);
  const descriptor = options.config as {
    schema?: { models?: { name?: unknown }[] };
    mutations?: { name?: unknown; version?: unknown }[];
  };
  for (const mutation of descriptor.mutations ?? []) {
    if (
      typeof mutation.name === "string" &&
      typeof mutation.version === "number" &&
      typeof options.handlers[mutation.name]?.[mutation.version] !== "function"
    )
      throw new Error(`Missing handler ${mutation.name} v${mutation.version}`);
  }
  for (const model of descriptor.schema?.models ?? []) {
    if (
      typeof model.name === "string" &&
      typeof options.loaders[model.name]?.load !== "function"
    )
      throw new Error(`Missing loader ${model.name}`);
  }
  const sessions = new Map<T, Session>();
  const wakes = new WakeHub();
  const host = (
    tx: T,
    session: Session,
  ): ((request: string) => Promise<string>) => {
    const storage = options.persistence(tx);
    return (raw) =>
      session.track(async () => {
        const req = JSON.parse(raw);
        let result: unknown;
        if (req.op === "savepoint") session.savepoint(req.ordinal);
        if (req.op === "rollback") session.rollback(req.ordinal);
        if (req.op === "release") session.release(req.ordinal);
        if (req.op === "handle") {
          const handler = options.handlers[req.name]?.[req.version];
          if (!handler)
            throw new Error(`Missing handler ${req.name} v${req.version}`);
          try {
            result = await handler(
              {
                transaction: tx,
                actorUserId: req.owner,
                publish: (changes, channels) => publish(tx, changes, channels),
              },
              req.arguments,
            );
          } catch (error) {
            const code =
              error instanceof MutationRejected
                ? error.code
                : options.translateRejection?.(error);
            if (code == null) throw error;
            result = { rejection: new MutationRejected(code).code };
          }
          if (result === undefined) result = null;
        } else if (req.op === "authorize") {
          result = await options.authorize({
            transaction: tx,
            viewerUserId: req.owner,
            channel: req.channel,
          });
        } else if (req.op === "load") {
          const loader = options.loaders[req.model];
          if (!loader) throw new Error(`Missing loader ${req.model}`);
          const context = {
            transaction: tx,
            viewerUserId: req.owner,
            channel: req.channel,
          };
          await loader.prepareForViewer?.(context, req.identities);
          result = await loader.load(context, req.identities);
          if (
            !Array.isArray(result) ||
            result.some((value) => value === undefined)
          )
            throw new Error("invalid loader: undefined or non-array result");
        } else result = await storage.call(req);
        return callbackJson(result);
      });
  };
  const publish = (
    tx: T,
    changes: Changes,
    channels: readonly string[],
  ): Promise<unknown> => {
    const session = sessions.get(tx) ?? new Session();
    return session.track(async () => {
      const result = JSON.parse(
        await native.publish(
          config,
          JSON.stringify(changes),
          JSON.stringify(channels),
          host(tx, session),
        ),
      );
      for (const channel of channels) session.touched.add(channel);
      return result;
    });
  };
  const bindTransaction = (tx: T) => {
    if (sessions.has(tx)) throw new Error("transaction already bound");
    const session = new Session();
    sessions.set(tx, session);
    return {
      publish: (changes: Changes, channels: readonly string[]) =>
        publish(tx, changes, channels),
      assertCommittable: () => session.assertCommittable(),
      afterCommit: () => {
        const scopes = [...session.touched];
        return () => wakes.notify(scopes);
      },
      close: () => {
        session.closed = true;
        sessions.delete(tx);
      },
    };
  };
  const run = async <R,>(
    operation: (tx: T, session: Session) => Promise<R>,
  ) => {
    let committed: string[] = [];
    const result = await options.transaction(async (tx) => {
      const bound = bindTransaction(tx);
      const session = sessions.get(tx)!;
      try {
        const result = await operation(tx, session);
        await bound.assertCommittable();
        committed = [...session.touched];
        return result;
      } catch (error) {
        // Preserve the original database error so the caller can retry serialization failures.
        while (session.pending.size)
          await Promise.allSettled([...session.pending]);
        throw session.failed ?? error;
      } finally {
        bound.close();
      }
    });
    wakes.notify(committed);
    return result;
  };
  const text = (request: Uint8Array | string) =>
    typeof request === "string"
      ? request
      : new TextDecoder("utf-8", { fatal: true }).decode(request);
  return {
    push: (owner: string, request: Uint8Array | string) =>
      run((tx, session) =>
        native.processPush(
          config,
          owner,
          options.principalChannel(owner),
          text(request),
          host(tx, session),
        ),
      ),
    pull: (owner: string, request: Uint8Array | string) =>
      run((tx, session) =>
        native.processPull(config, owner, text(request), host(tx, session)),
      ),
    negotiateLive: (owner: string, request: Uint8Array | string) =>
      run((tx, session) =>
        native.negotiateLive(owner, text(request), host(tx, session)),
      ).then(JSON.parse),
    pullLive: (owner: string, scope: string, fromCursor: number) =>
      run((tx, session) =>
        native.pullLive(config, owner, scope, fromCursor, host(tx, session)),
      ).then(JSON.parse),
    onCommitted: (scope: string, wake: () => void) =>
      wakes.subscribe(scope, wake),
    notifyCommitted: (scopes: readonly string[]) => wakes.notify(scopes),
    closeLive: () => wakes.clear(),
    publish,
    bindTransaction,
  };
}
export interface HttpBackend {
  push(owner: string, request: Uint8Array | string): Promise<string>;
  pull(owner: string, request: Uint8Array | string): Promise<string>;
}
export function createHttpHandler(options: {
  backend: HttpBackend;
  authenticate: (request: IncomingMessage) => Promise<string | null>;
  maxBodyBytes?: number;
  onError?: (error: unknown) => void;
}): RequestListener {
  return async (request, response) => {
    const send = (status: number, value: unknown) => {
      response.writeHead(status, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
      });
      response.end(typeof value === "string" ? value : JSON.stringify(value));
    };
    const path = request.url?.split("?")[0];
    if (path !== "/sync/mutations" && path !== "/sync/pull") {
      send(404, { code: "not_found" });
      return;
    }
    if (request.method !== "POST") {
      response.setHeader("allow", "POST");
      send(405, { code: "method_not_allowed" });
      return;
    }
    try {
      const owner = await options.authenticate(request);
      if (!owner?.trim()) {
        send(401, { code: "unauthenticated" });
        return;
      }
      const chunks: Buffer[] = [];
      let size = 0;
      for await (const chunk of request) {
        const buffer = Buffer.from(chunk);
        size += buffer.length;
        if (size > (options.maxBodyBytes ?? 1_048_576)) {
          send(413, { code: "request_too_large" });
          return;
        }
        chunks.push(buffer);
      }
      const bytes = Buffer.concat(chunks);
      let body: unknown;
      try {
        body = JSON.parse(
          new TextDecoder("utf-8", { fatal: true }).decode(bytes),
        );
      } catch {
        send(400, { code: "request.invalid" });
        return;
      }
      if (body === null || typeof body !== "object" || Array.isArray(body)) {
        send(400, { code: "request.invalid" });
        return;
      }
      const result = await (path === "/sync/mutations"
        ? options.backend.push(owner, bytes)
        : options.backend.pull(owner, bytes));
      send(200, result);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (/^(owner_mismatch|channel_forbidden)$/.test(message)) {
        send(403, {
          code:
            message === "owner_mismatch"
              ? "client.owner_mismatch"
              : "scope.forbidden",
        });
        return;
      }
      if (/^(gap|overlap)$/.test(message)) {
        send(409, { code: message });
        return;
      }
      if (message.startsWith("mutation_version_unsupported:")) {
        const parts = message.split(":");
        send(409, {
          code: "mutation_version_unsupported",
          ordinal: Number(parts[1]),
          name: parts.slice(2, -1).join(":"),
          version: Number(parts.at(-1)),
        });
        return;
      }
      if (message.startsWith("request.invalid:")) {
        send(400, { code: "request.invalid" });
        return;
      }
      options.onError?.(error);
      send(500, { code: "server" });
    }
  };
}

export interface LiveBackend {
  negotiateLive(
    owner: string,
    request: Uint8Array | string,
  ): Promise<{
    response: string;
    subscriptions: { scope: string; fromCursor: number }[];
  }>;
  pullLive(
    owner: string,
    scope: string,
    fromCursor: number,
  ): Promise<{ page: string; toCursor: number; continues: boolean }>;
  onCommitted(scope: string, wake: () => void): () => void;
}

export function attachLive(
  server: Server,
  options: {
    backend: LiveBackend;
    authenticate: (request: IncomingMessage) => Promise<string | null>;
    maxPayloadBytes?: number;
    onError?: (error: unknown) => void;
  },
) {
  const sockets = new WebSocketServer({
    noServer: true,
    maxPayload: options.maxPayloadBytes ?? 1_048_576,
  });
  let closing = false;
  const refuse = (socket: Duplex, status: number) => {
    socket.end(
      `HTTP/1.1 ${status} ${status === 401 ? "Unauthorized" : "Error"}\r\nConnection: close\r\n\r\n`,
    );
  };
  const upgrade = (request: IncomingMessage, socket: Duplex, head: Buffer) => {
    void (async () => {
      if (request.url?.split("?")[0] !== "/sync/live") return;
      if (closing) {
        refuse(socket, 503);
        return;
      }
      let owner: string | null;
      try {
        owner = await options.authenticate(request);
      } catch (error) {
        options.onError?.(error);
        refuse(socket, 500);
        return;
      }
      if (closing || socket.destroyed) {
        refuse(socket, 503);
        return;
      }
      if (!owner?.trim()) {
        refuse(socket, 401);
        return;
      }
      sockets.handleUpgrade(request, socket, head, (connection) => {
        void serveLive(connection, owner!, options.backend, options.onError);
      });
    })();
  };
  server.on("upgrade", upgrade);
  return {
    close: async () => {
      if (closing) return;
      closing = true;
      server.off("upgrade", upgrade);
      for (const socket of sockets.clients) socket.close(1001, "closing");
      await new Promise<void>((resolve) => sockets.close(() => resolve()));
    },
  };
}

async function serveLive(
  connection: WebSocket,
  owner: string,
  backend: LiveBackend,
  onError?: (error: unknown) => void,
): Promise<void> {
  const cleanups: (() => void)[] = [];
  let states: {
    scope: string;
    fromCursor: number;
    pending: boolean;
    running: boolean;
    closed: boolean;
  }[] = [];
  let settled = false;
  let handshakeReject: ((error: Error) => void) | undefined;
  const transportError = (error: Error) => {
    handshakeReject?.(error);
  };
  connection.on("error", transportError);
  cleanups.push(() => connection.off("error", transportError));
  try {
    const first = await new Promise<Buffer>((resolve, reject) => {
      const message = (data: Buffer) => {
        if (settled) {
          connection.close(1002, "subscribe is the only client frame");
          return;
        }
        settled = true;
        resolve(Buffer.from(data));
      };
      const closed = () => reject(new Error("live handshake closed"));
      handshakeReject = reject;
      connection.on("message", message);
      connection.once("close", closed);
      cleanups.push(
        () => connection.off("message", message),
        () => connection.off("close", closed),
      );
    });
    const negotiation = await backend.negotiateLive(owner, first);
    handshakeReject = undefined;
    states = negotiation.subscriptions.map((subscription) => ({
      ...subscription,
      pending: false,
      running: false,
      closed: false,
    }));
    const stop = () => {
      for (const state of states) {
        state.closed = true;
        state.pending = false;
      }
    };
    connection.once("close", stop);
    connection.once("error", stop);
    cleanups.push(
      () => connection.off("close", stop),
      () => connection.off("error", stop),
    );
    const drain = async (state: (typeof states)[number]) => {
      if (
        state.running ||
        state.closed ||
        connection.readyState !== WebSocket.OPEN
      )
        return;
      state.running = true;
      try {
        while (
          state.pending &&
          !state.closed &&
          connection.readyState === WebSocket.OPEN
        ) {
          state.pending = false;
          do {
            const progress = await backend.pullLive(
              owner,
              state.scope,
              state.fromCursor,
            );
            if (state.closed || connection.readyState !== WebSocket.OPEN)
              return;
            if (progress.toCursor > state.fromCursor)
              connection.send(progress.page);
            state.fromCursor = progress.toCursor;
            if (!progress.continues) break;
          } while (!state.closed);
        }
      } catch (error) {
        onError?.(error);
        if (connection.readyState === WebSocket.OPEN)
          connection.close(1011, "server");
      } finally {
        state.running = false;
        if (
          state.pending &&
          !state.closed &&
          connection.readyState === WebSocket.OPEN
        )
          void drain(state);
      }
    };
    for (const state of states)
      cleanups.push(
        backend.onCommitted(state.scope, () => {
          state.pending = true;
          void drain(state);
        }),
      );
    if (connection.readyState !== WebSocket.OPEN) {
      stop();
      return;
    }
    connection.send(negotiation.response);
    for (const state of states) {
      state.pending = true;
      void drain(state);
    }
    await new Promise<void>((resolve) => {
      connection.once("close", () => resolve());
      connection.once("error", () => resolve());
    });
    stop();
  } catch (error) {
    if (connection.readyState === WebSocket.OPEN)
      connection.close(
        String((error as Error)?.message).includes("request.invalid")
          ? 1002
          : 1011,
        "request.invalid",
      );
    if (!String((error as Error)?.message).includes("request.invalid"))
      onError?.(error);
  } finally {
    for (const state of states) {
      state.closed = true;
      state.pending = false;
    }
    for (const cleanup of cleanups) cleanup();
  }
}
