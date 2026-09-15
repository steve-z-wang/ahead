import { createRequire } from "node:module";
import { createServer } from "node:http";
import type { IncomingMessage, RequestListener, Server } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, WebSocket } from "ws";
import type { HostRequest } from "./host-contract.mts";
export { WebSocket } from "ws";
const require = createRequire(import.meta.url);
export type Native = {
  validateConfig(config: string): void;
  processPush(
    config: string,
    owner: string,
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
  /** Negotiates and opens the socket's `Subscriptions`; answers `{handle, actions}` JSON. */
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
  /** Applies one `LiveEvent` JSON to the session and answers its `LiveAction[]` JSON. */
  liveEvent(handle: number, event: string): string;
  /** Forgets the session; idempotent. */
  liveClose(handle: number): void;
};
/** What the executor reports to the Rust `Subscriptions` controller. */
export type LiveEvent =
  | { type: "committed"; scope: string }
  | { type: "pulled"; scope: string; page: string }
  | { type: "closed" };
/** What the controller asks the executor to do, in order. */
export type LiveAction =
  | { type: "listen"; scope: string }
  | { type: "send"; frame: string }
  | { type: "pull"; scope: string; fromCursor: number };
export interface Persistence {
  call(request: Record<string, any>): Promise<unknown>;
}
export interface Database<T> {
  /** Must provide a coherent snapshot and roll back rejected callbacks. Retry serialization failures. */
  transaction: <R>(body: (tx: T) => Promise<R>) => Promise<R>;
  persistence: (tx: T) => Persistence;
}
export type Authenticate = (
  request: IncomingMessage,
) => Promise<string | null | undefined> | string | null | undefined;
/** Development only: the bearer token is used verbatim as the user id. Never use in production. */
export function devAuth(): Authenticate {
  return (request) => {
    const header = request.headers.authorization;
    if (typeof header !== "string" || !header.startsWith("Bearer "))
      return null;
    const id = header.slice("Bearer ".length).trim();
    return id === "" ? null : id;
  };
}
/**
 * A failure reported by the native engine. `code` is the stable machine name
 * transports and applications should branch on; `message` is for people and
 * may be reworded; `details` carries the fields a code promises (only
 * `mutation_version_unsupported` has any: `ordinal`, `name`, `version`).
 */
export class EngineError extends Error {
  readonly code: string;
  readonly details: Record<string, unknown> | undefined;
  constructor(
    code: string,
    message: string,
    details?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "EngineError";
    this.code = code;
    this.details = details;
  }
}
/** The native addon carries the engine error as JSON in the error message. */
function engineError(error: unknown): unknown {
  if (error instanceof EngineError) return error;
  const text =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : "";
  if (!text.startsWith("{")) return error;
  try {
    const parsed = JSON.parse(text);
    if (
      parsed &&
      typeof parsed === "object" &&
      typeof parsed.code === "string" &&
      typeof parsed.message === "string"
    ) {
      const details =
        parsed.details && typeof parsed.details === "object"
          ? (parsed.details as Record<string, unknown>)
          : undefined;
      return new EngineError(parsed.code, parsed.message, details);
    }
  } catch {
    // Not an engine error; leave it as received.
  }
  return error;
}
/** Wrap every native function so its failures surface as `EngineError`. */
function typedNative(native: Native): Native {
  type Async =
    "processPush" | "processPull" | "publish" | "negotiateLive" | "pullLive";
  type Sync = "validateConfig" | "liveEvent" | "liveClose";
  const wrap =
    <K extends Async>(key: K) =>
    (...args: Parameters<Native[K]>): ReturnType<Native[K]> =>
      (native[key] as (...a: Parameters<Native[K]>) => ReturnType<Native[K]>)(
        ...args,
      ).catch((error: unknown) => {
        throw engineError(error);
      }) as ReturnType<Native[K]>;
  const wrapSync =
    <K extends Sync>(key: K) =>
    (...args: Parameters<Native[K]>): ReturnType<Native[K]> => {
      try {
        return (
          native[key] as (...a: Parameters<Native[K]>) => ReturnType<Native[K]>
        )(...args);
      } catch (error) {
        throw engineError(error);
      }
    };
  return {
    validateConfig: wrapSync("validateConfig"),
    processPush: wrap("processPush"),
    processPull: wrap("processPull"),
    publish: wrap("publish"),
    negotiateLive: wrap("negotiateLive"),
    pullLive: wrap("pullLive"),
    liveEvent: wrapSync("liveEvent"),
    liveClose: wrapSync("liveClose"),
  };
}
/**
 * Engine codes with a client-visible HTTP status. Every other failure is a
 * server-side defect: reported to `onError` and answered `500 {code: "server"}`.
 */
const HTTP_STATUS_BY_CODE: Readonly<Record<string, number>> = {
  "request.invalid": 400,
  "client.owner_mismatch": 403,
  gap: 409,
  overlap: 409,
  mutation_version_unsupported: 409,
};
export class MutationRejected extends Error {
  readonly code: string;
  constructor(code: string) {
    if (!/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/.test(code))
      throw new Error("rejection code must be a stable machine code");
    super(code);
    this.code = code;
  }
}
export interface RecordRef {
  model: string;
  identity: object;
}
export type NotifyArgs = {
  channel: string;
  records: readonly (RecordRef | object)[];
};
export type Notify = (args: NotifyArgs) => void;
export interface HandlerCall<Tx, Input> {
  input: Input;
  tx: Tx;
  userId: string;
  notify: Notify;
}
export interface LoaderCall<Tx, Identity> {
  ids: readonly Identity[];
  tx: Tx;
  userId: string;
  /** The channel whose Pull requested these rows; loaders may scope visibility by it. */
  channel: string;
}
export type Handler<Tx, Input = any> = (
  call: HandlerCall<Tx, Input>,
) => Promise<void | { channel: string }>;
export type Loader<Tx, Identity = any, Row = object> = (
  call: LoaderCall<Tx, Identity>,
) => Promise<readonly (Row | null)[]>;
/** Every retained version of one mutation, or a bare function as shorthand for a v1-only contract. */
export type HandlerRegistration<Tx> =
  Handler<Tx> | { [version: `v${number}`]: Handler<Tx> };
/** Every retained version of one model's read contract, or a bare function as shorthand for a v1-only model. */
export type LoaderRegistration<Tx> =
  Loader<Tx> | { [version: `v${number}`]: Loader<Tx> };
/**
 * One registration holds every retained version under the mutation or model
 * name; a bare function is shorthand for a v1-only contract and never stands
 * for the latest version. Refused at startup, naming the key and version.
 */
function versioned<F>(
  kind: "handler" | "loader",
  name: string,
  key: string,
  versions: readonly number[],
  registration: unknown,
): Map<number, F> {
  const label = kind.charAt(0).toUpperCase() + kind.slice(1);
  const list = versions.map((version) => `v${version}`).join(", ");
  const table = new Map<number, F>();
  if (typeof registration === "function") {
    if (versions.length !== 1 || versions[0] !== 1)
      throw new Error(
        `${label} ${key} must register ${list} of ${name}; a function registers v1 only`,
      );
    table.set(1, registration as F);
    return table;
  }
  if (registration === null || typeof registration !== "object")
    throw new Error(`Missing ${kind} ${key} for ${name} ${list}`);
  for (const version of versions) {
    const found = (registration as Record<string, unknown>)[`v${version}`];
    if (found === undefined)
      throw new Error(
        `Missing ${kind} ${key}.v${version} for ${name} v${version}`,
      );
    if (typeof found !== "function")
      throw new Error(
        `${label} ${key}.v${version} for ${name} v${version} must be a function`,
      );
    table.set(version, found as F);
  }
  for (const found of Object.keys(registration))
    if (!/^v[1-9][0-9]*$/.test(found) || !table.has(Number(found.slice(1))))
      throw new Error(
        `Unknown ${kind} ${key}.${found} for ${name}: retained versions are ${list}`,
      );
  return table;
}
export const RECORD: unique symbol = Symbol("ahead.record");
function toRef(value: unknown): RecordRef {
  if (value !== null && typeof value === "object") {
    const tagged = (value as { [RECORD]?: RecordRef })[RECORD];
    if (tagged) return tagged;
    const { model, identity } = value as Partial<RecordRef>;
    if (typeof model === "string" && identity && typeof identity === "object")
      return { model, identity };
  }
  throw new Error(
    "notify: record must be a slot argument or { model, identity }",
  );
}
function tag<T extends object>(value: T, ref: RecordRef): T {
  Object.defineProperty(value, RECORD, { value: ref, enumerable: false });
  return value;
}
function lowerFirst(name: string): string {
  return name.charAt(0).toLowerCase() + name.slice(1);
}
/** A framework programming error (no/ambiguous checkpoint), never a per-mutation rejection: must abort the batch and never reach `translateRejection`. */
class CheckpointError extends Error {}
export interface BackendOptions<T> {
  config: object;
  database: Database<T>;
  authenticate: Authenticate;
  handlers: Record<string, HandlerRegistration<T>>;
  loaders: Record<string, LoaderRegistration<T>>;
  loaderHooks?: Record<
    string,
    { prepareForViewer(call: LoaderCall<T, any>): Promise<void> }
  >;
  translateRejection?: (error: unknown) => string | null | undefined;
  native?: Native;
  /** Called for server-side failures that clients only see as `{ code: "server" }`: authenticate throws, persistence faults, checkpoint errors, live drain failures. */
  onError?: (error: unknown) => void;
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
type MutationSlot = {
  name: string;
  operation: string;
  cardinality: string;
  model: string;
};
type MutationDescriptor = {
  name: string;
  version: number;
  slots?: MutationSlot[];
};
export function createBackend<T>(options: BackendOptions<T>) {
  const native = typedNative(
    options.native ??
      (require("../../bindings/node/ahead-node.node") as Native),
  );
  const descriptor = options.config as {
    schema?: { models?: { name: string; version?: number }[] };
    mutations?: MutationDescriptor[];
    models?: { name: string; version: number }[];
  };
  const retained = new Map<string, number[]>();
  for (const m of descriptor.mutations ?? [])
    retained.set(
      m.name,
      [...(retained.get(m.name) ?? []), m.version].sort((a, b) => a - b),
    );
  const schemaModels = descriptor.schema?.models ?? [];
  const modelNames = schemaModels.map((model) => model.name);
  const config = JSON.stringify({
    ...options.config,
    loaders: modelNames,
  });
  native.validateConfig(config);
  // Every retained model read contract; a config without `models` retains each
  // model at the schema's own version, as the engine does.
  const retainedModels = new Map<string, number[]>();
  for (const m of descriptor.models?.length
    ? descriptor.models
    : schemaModels.map((model) => ({
        name: model.name,
        version: model.version ?? 1,
      })))
    retainedModels.set(
      m.name,
      [...(retainedModels.get(m.name) ?? []), m.version].sort((a, b) => a - b),
    );
  const loaderTable = new Map<string, Loader<T>>();
  for (const name of modelNames) {
    const key = lowerFirst(name);
    const table = versioned<Loader<T>>(
      "loader",
      name,
      key,
      retainedModels.get(name) ?? [],
      options.loaders[key],
    );
    for (const [version, loader] of table)
      loaderTable.set(`${name}:${version}`, loader);
  }
  const registered = new Map<string, Map<number, Handler<T>>>();
  for (const [name, versions] of retained) {
    const key = lowerFirst(name);
    registered.set(
      name,
      versioned<Handler<T>>(
        "handler",
        name,
        key,
        versions,
        options.handlers[key],
      ),
    );
  }
  const handlerTable = new Map<
    string,
    { handler: Handler<T>; slots: MutationSlot[] }
  >();
  for (const m of descriptor.mutations ?? [])
    handlerTable.set(`${m.name}:${m.version}`, {
      handler: registered.get(m.name)!.get(m.version)!,
      slots: m.slots ?? [],
    });
  const sessions = new Map<T, Session>();
  const wakes = new WakeHub();
  const host = (
    tx: T,
    session: Session,
  ): ((request: string) => Promise<string>) => {
    const storage = options.database.persistence(tx);
    return (raw) =>
      session.track(async () => {
        const req = JSON.parse(raw) as HostRequest;
        let result: unknown;
        // `savepoint`, `rollback` and `release` are answered by the persistence
        // and also bookkept here, so each one does both.
        if (req.op === "savepoint") session.savepoint(req.ordinal);
        if (req.op === "rollback") session.rollback(req.ordinal);
        if (req.op === "release") session.release(req.ordinal);
        if (req.op === "handle") {
          const entry = handlerTable.get(`${req.name}:${req.version}`);
          if (!entry)
            throw new Error(`Missing handler ${req.name} v${req.version}`);
          const shape = (slot: MutationSlot, raw: any) => {
            if (raw === null || raw === undefined) return null;
            const ref: RecordRef = {
              model: slot.model,
              identity: raw.identity,
            };
            if (slot.operation === "create")
              return tag({ ...raw.identity, ...raw.data }, ref);
            if (slot.operation === "update")
              return tag({ identity: raw.identity, patch: raw.patch }, ref);
            return tag({ identity: raw.identity }, ref);
          };
          const input: Record<string, unknown> = {};
          for (const slot of entry.slots) {
            const raw = req.arguments[slot.name] as any;
            input[slot.name] =
              slot.cardinality === "list"
                ? (raw as any[]).map((item) => shape(slot, item))
                : shape(slot, raw);
          }
          const notified = new Set<string>();
          const pending: { channel: string; refs: RecordRef[] }[] = [];
          const notify: Notify = ({ channel, records }) => {
            if (typeof channel !== "string" || channel === "")
              throw new Error("notify: channel must be a non-empty string");
            if (!Array.isArray(records))
              throw new Error("notify: records must be an array");
            const refs = records.map(toRef);
            notified.add(channel);
            pending.push({ channel, refs });
          };
          try {
            const returned = await entry.handler({
              input,
              tx,
              userId: req.owner,
              notify,
            });
            for (const item of pending)
              await publish(tx, item.refs, [item.channel]);
            if (
              returned &&
              typeof returned === "object" &&
              typeof (returned as { channel?: unknown }).channel === "string"
            ) {
              const channel = (returned as { channel: string }).channel;
              if (channel === "")
                throw new CheckpointError(
                  `handler.invalid_checkpoint:${req.name}`,
                );
              if (!notified.has(channel))
                throw new CheckpointError(
                  `handler.unnotified_checkpoint:${req.name}`,
                );
              result = { channel };
            } else if (notified.size === 1)
              result = { channel: [...notified][0] };
            else if (notified.size === 0)
              throw new CheckpointError(`handler.no_channel:${req.name}`);
            else
              throw new CheckpointError(
                `handler.ambiguous_checkpoint:${req.name}`,
              );
          } catch (error) {
            if (error instanceof CheckpointError) throw error;
            const code =
              error instanceof MutationRejected
                ? error.code
                : options.translateRejection?.(error);
            if (code == null) throw error;
            result = { rejection: new MutationRejected(code).code };
          }
        } else if (req.op === "load") {
          // Dispatch is by model name and contract version; a version that
          // was not registered is a defect, never another version's loader.
          const loader = loaderTable.get(`${req.model}:${req.version}`);
          if (!loader)
            throw new Error(`Missing loader ${req.model} v${req.version}`);
          const call = {
            ids: req.identities as any[],
            tx,
            userId: req.owner,
            channel: req.channel,
          };
          await options.loaderHooks?.[lowerFirst(req.model)]?.prepareForViewer(
            call,
          );
          result = await loader(call);
          if (
            !Array.isArray(result) ||
            result.some((value) => value === undefined)
          )
            throw new Error("invalid loader: undefined or non-array result");
        } else {
          // Everything the persistence owns, plus anything this build does not
          // know: an operation added to the contract without an arm here is a
          // compile error, not a silent forward.
          switch (req.op) {
            case "claim":
            case "saveReceipt":
            case "head":
            case "scan":
            case "savepoint":
            case "rollback":
            case "release":
            case "publish":
              break;
            default: {
              const unreachable: never = req;
              void unreachable;
            }
          }
          result = await storage.call(req);
        }
        return callbackJson(result);
      });
  };
  const publish = (
    tx: T,
    changes: readonly RecordRef[],
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
      /** Unlike the handler's `notify`, this returns a promise the caller must await before the transaction commits. */
      notify: ({ channel, records }: NotifyArgs) =>
        publish(tx, records.map(toRef), [channel]),
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
    const result = await options.database.transaction(async (tx) => {
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
  /** @internal Raw protocol seams used by the framework's own tests; not part of the supported surface. */
  const api = {
    push: (owner: string, request: Uint8Array | string) =>
      run((tx, session) =>
        native.processPush(config, owner, text(request), host(tx, session)),
      ),
    pull: (owner: string, request: Uint8Array | string) =>
      run((tx, session) =>
        native.processPull(config, owner, text(request), host(tx, session)),
      ),
    negotiateLive: (
      owner: string,
      request: Uint8Array | string,
    ): Promise<{ handle: number; actions: LiveAction[] }> =>
      run((tx, session) =>
        native.negotiateLive(owner, text(request), host(tx, session)),
      ).then(JSON.parse),
    pullLive: (
      owner: string,
      scope: string,
      fromCursor: number,
    ): Promise<{ page: string; toCursor: number; continues: boolean }> =>
      run((tx, session) =>
        native.pullLive(config, owner, scope, fromCursor, host(tx, session)),
      ).then(JSON.parse),
    liveEvent: (handle: number, event: LiveEvent): LiveAction[] =>
      JSON.parse(native.liveEvent(handle, JSON.stringify(event))),
    liveClose: (handle: number): void => native.liveClose(handle),
    onCommitted: (scope: string, wake: () => void) =>
      wakes.subscribe(scope, wake),
    notifyCommitted: (scopes: readonly string[]) => wakes.notify(scopes),
    closeLive: () => wakes.clear(),
    /** Unlike the handler's `notify`, this returns a promise the caller must await before the transaction commits. */
    notify: (tx: T, args: NotifyArgs) =>
      publish(tx, args.records.map(toRef), [args.channel]),
    bindTransaction,
  };
  const authenticate = async (request: IncomingMessage) => {
    const id = await options.authenticate(request);
    if (typeof id !== "string") return null;
    const trimmed = id.trim();
    return trimmed === "" ? null : trimmed;
  };
  const listen = async ({
    port,
    host = "127.0.0.1",
  }: {
    port: number;
    host?: string;
  }) => {
    const server = createServer(
      createHttpHandler({
        backend: api,
        authenticate,
        ...(options.onError ? { onError: options.onError } : {}),
      }),
    );
    const live = attachLive(server, {
      backend: api,
      authenticate,
      ...(options.onError ? { onError: options.onError } : {}),
    });
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => reject(error);
      server.once("error", onError);
      server.listen(port, host, () => {
        server.off("error", onError);
        resolve();
      });
    });
    const address = server.address();
    const actual = typeof address === "object" && address ? address.port : port;
    const urlHost =
      host === "0.0.0.0"
        ? "127.0.0.1"
        : host === "::"
          ? "localhost"
          : host.includes(":")
            ? `[${host}]`
            : host;
    let closed = false;
    return {
      url: `http://${urlHost}:${actual}`,
      close: async () => {
        if (closed) return;
        closed = true;
        await live.close();
        server.closeIdleConnections();
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        );
      },
    };
  };
  return { ...api, listen };
}
interface HttpBackend {
  push(owner: string, request: Uint8Array | string): Promise<string>;
  pull(owner: string, request: Uint8Array | string): Promise<string>;
}
function createHttpHandler(options: {
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
      const status =
        error instanceof EngineError
          ? HTTP_STATUS_BY_CODE[error.code]
          : undefined;
      if (error instanceof EngineError && status !== undefined) {
        send(status, { code: error.code, ...(error.details ?? {}) });
        return;
      }
      options.onError?.(error);
      send(500, { code: "server" });
    }
  };
}

/**
 * The live executor's seams: the Rust `Subscriptions` controller behind
 * `negotiateLive`, `liveEvent` and `liveClose`, plus the database pull and the
 * commit hub it asks the executor to use.
 */
interface LiveBackend {
  negotiateLive(
    owner: string,
    request: Uint8Array | string,
  ): Promise<{ handle: number; actions: LiveAction[] }>;
  pullLive(
    owner: string,
    scope: string,
    fromCursor: number,
  ): Promise<{ page: string; toCursor: number; continues: boolean }>;
  liveEvent(handle: number, event: LiveEvent): LiveAction[];
  liveClose(handle: number): void;
  onCommitted(scope: string, wake: () => void): () => void;
}

function attachLive(
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

/**
 * Executes the Rust controller's actions for one socket. Every sync decision
 * (what to pull, when, what to send) is the controller's; this only carries
 * events in and performs actions out. Pulls for different scopes may run
 * concurrently; the controller keeps at most one outstanding per scope.
 */
async function serveLive(
  connection: WebSocket,
  owner: string,
  backend: LiveBackend,
  onError?: (error: unknown) => void,
): Promise<void> {
  const cleanups: (() => void)[] = [];
  let settled = false;
  let handshakeReject: ((error: Error) => void) | undefined;
  const transportError = (error: Error) => {
    handshakeReject?.(error);
  };
  connection.on("error", transportError);
  cleanups.push(() => connection.off("error", transportError));
  let handle: number | undefined;
  let released = false;
  const open = () => connection.readyState === WebSocket.OPEN;
  const fail = (error: unknown) => {
    onError?.(error);
    if (open()) connection.close(1011, "server");
  };
  const dispatch = (event: LiveEvent) => {
    if (handle === undefined || released) return;
    let actions: LiveAction[];
    try {
      actions = backend.liveEvent(handle, event);
    } catch (error) {
      fail(error);
      return;
    }
    execute(actions);
  };
  const execute = (actions: LiveAction[]) => {
    for (const action of actions) {
      if (action.type === "listen") {
        const { scope } = action;
        cleanups.push(
          backend.onCommitted(scope, () =>
            dispatch({ type: "committed", scope }),
          ),
        );
      } else if (action.type === "send") {
        if (open()) connection.send(action.frame);
      } else {
        const { scope } = action;
        backend
          .pullLive(owner, scope, action.fromCursor)
          .then(
            (progress) =>
              dispatch({ type: "pulled", scope, page: progress.page }),
            fail,
          );
      }
    }
  };
  const closed = () => dispatch({ type: "closed" });
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
      const handshakeClosed = () => reject(new Error("live handshake closed"));
      handshakeReject = reject;
      connection.on("message", message);
      connection.once("close", handshakeClosed);
      cleanups.push(
        () => connection.off("message", message),
        () => connection.off("close", handshakeClosed),
      );
    });
    const opened = await backend.negotiateLive(owner, first);
    handshakeReject = undefined;
    handle = opened.handle;
    connection.once("close", closed);
    connection.once("error", closed);
    cleanups.push(
      () => connection.off("close", closed),
      () => connection.off("error", closed),
    );
    if (!open()) return;
    execute(opened.actions);
    await new Promise<void>((resolve) => {
      connection.once("close", () => resolve());
      connection.once("error", () => resolve());
    });
  } catch (error) {
    const invalid =
      error instanceof EngineError && error.code === "request.invalid";
    if (open()) connection.close(invalid ? 1002 : 1011, "request.invalid");
    if (!invalid) onError?.(error);
  } finally {
    if (handle !== undefined) {
      closed();
      released = true;
      backend.liveClose(handle);
    }
    for (const cleanup of cleanups) cleanup();
  }
}
