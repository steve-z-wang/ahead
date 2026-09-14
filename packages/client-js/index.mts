import {
  startConnection,
  type Connection,
  type ConnectionOptions,
  type Transport,
} from "./connection.mts";
export type {
  Connection,
  ConnectionOptions,
  Transport,
} from "./connection.mts";
import { Transaction, strictJson, type QuerySpec } from "./transaction.mts";
export { Transaction, type QuerySpec } from "./transaction.mts";
export { httpTransport } from "./transport.mts";
import { createRequire } from "node:module";
import { EventEmitter } from "node:events";
const native = createRequire(import.meta.url)(
  "../../bindings/node/ahead-node.node",
) as { clientCall(request: string): Promise<string> };
export type RecordValue = Record<string, unknown>;
export class Client {
  #syncing: Promise<void> | undefined;
  #tasks: Promise<void> | undefined;
  #connection: Connection | undefined;
  #connecting = false;
  #started: Promise<void> | undefined;
  #closing: Promise<void> | undefined;
  #handle: number;
  #closed = false;
  #tail: Promise<unknown> = Promise.resolve();
  #events = new EventEmitter();
  readonly clientId: string;
  private constructor(handle: number, id: string) {
    this.#handle = handle;
    this.clientId = id;
  }
  static async open(options: {
    path: string;
    schema: object;
    migration?: { defaults?: RecordValue; replayPull?: boolean };
  }) {
    const result = JSON.parse(
      await native.clientCall(strictJson({ op: "open", ...options })),
    ).value;
    return new Client(result.handle, result.clientId);
  }
  #exclusive<T>(body: () => Promise<T>): Promise<T> {
    const work = this.#tail.then(body);
    this.#tail = work.catch(() => {});
    return work;
  }
  async #send(request: RecordValue): Promise<any> {
    if (this.#closed) throw Error("client_closed");
    const result = JSON.parse(
      await native.clientCall(strictJson({ ...request, handle: this.#handle })),
    );
    if (result.changed) this.#events.emit("change");
    return result.value;
  }
  transaction<T>(body: (tx: Transaction) => Promise<T>) {
    return this.#exclusive(async () => {
      await this.#send({ op: "begin" });
      const tx = new Transaction((request) => this.#send(request));
      try {
        const result = await body(tx);
        await tx.finish();
        await this.#send({ op: "commit" });
        this.#events.emit("work");
        return result;
      } catch (error) {
        await tx.finish().catch(() => {});
        await this.#send({ op: "rollback" }).catch(() => {});
        throw error;
      }
    });
  }
  read(model: string, identity: object): Promise<RecordValue | null> {
    return this.#exclusive(() =>
      this.#send({ op: "read", key: { model, identity } }),
    );
  }
  query(model: string, where: RecordValue = {}): Promise<RecordValue[]> {
    return this.#exclusive(() =>
      this.#send({ op: "query", model, filter: where }),
    );
  }
  readSql(sql: string, parameters: unknown[] = []): Promise<RecordValue[]> {
    return this.#exclusive(() => this.#send({ op: "sql", sql, parameters }));
  }
  querySpec(model: string, query: QuerySpec = {}): Promise<RecordValue[]> {
    return this.#exclusive(() => this.#send({ op: "querySpec", model, query }));
  }
  related(
    model: string,
    identity: object,
    relation: string,
  ): Promise<RecordValue | null> {
    return this.#exclusive(() =>
      this.#send({ op: "related", key: { model, identity }, relation }),
    );
  }
  referencing(
    model: string,
    identity: object,
    source: string,
    relation: string,
  ): Promise<RecordValue[]> {
    return this.#exclusive(() =>
      this.#send({
        op: "referencing",
        key: { model, identity },
        source,
        relation,
      }),
    );
  }
  mutate(mutation: object): Promise<number> {
    return this.transaction((tx) => tx.mutate(mutation));
  }
  subscribe(channel: string) {
    return this.#exclusive(() =>
      this.#send({ op: "channel", channel, subscribed: true }).then((value) => {
        this.#events.emit("work");
        return value;
      }),
    );
  }
  unsubscribe(channel: string) {
    return this.#exclusive(() =>
      this.#send({ op: "channel", channel, subscribed: false }).then(
        (value) => {
          this.#events.emit("work");
          return value;
        },
      ),
    );
  }
  async connect(
    transport: Transport,
    options: ConnectionOptions = {},
  ): Promise<Connection> {
    if (this.#closed || this.#closing) throw Error("client_closed");
    if (this.#connecting || this.#connection)
      throw Error("connection already active");
    this.#connecting = true;
    let finished!: () => void;
    this.#started = new Promise<void>((resolve) => {
      finished = resolve;
    });
    try {
      const connection = await startConnection(
        (event) =>
          this.#exclusive(() =>
            this.#send({
              op: "connection",
              event,
              now: Date.now(),
              entropy: Math.floor(Math.random() * 0x100000000),
            }),
          ),
        (t) => this.sync(t),
        transport,
        options,
      );
      const wake = () => {
        void connection.wake().catch(options.onError ?? (() => {}));
      };
      this.#events.on("work", wake);
      const result = {
        ...connection,
        close: async () => {
          this.#events.off("work", wake);
          await connection.close();
          if (this.#connection === result) this.#connection = undefined;
        },
      };
      this.#connection = result;
      return result;
    } finally {
      this.#connecting = false;
      finished();
    }
  }
  sync(
    transport: (kind: string, body: string) => Promise<string>,
  ): Promise<void> {
    if (this.#syncing) return this.#syncing;
    const run = async () => {
      await this.#exclusive(() => this.#send({ op: "startSync" }));
      for (;;) {
        const action = await this.#exclusive(() => this.#send({ op: "next" }));
        if (action === null) return;
        const response = await transport(action.kind, action.body);
        await this.#exclusive(() =>
          this.#send({ op: "complete", response: JSON.parse(response) }),
        );
      }
    };
    this.#syncing = run().finally(() => {
      this.#syncing = undefined;
    });
    return this.#syncing;
  }
  runPrerequisites(
    handlers: Record<string, (arguments_: RecordValue) => Promise<void>>,
  ): Promise<void> {
    if (this.#tasks) return this.#tasks;
    const run = async () => {
      for (;;) {
        const task = (await this.pendingTasks()).find(
          (task) => task.state === "pending",
        );
        if (!task) return;
        const handler = handlers[String(task.name)];
        if (!handler) throw Error(`Missing prerequisite handler: ${task.name}`);
        try {
          await handler(task.arguments as RecordValue);
          await this.setReadiness(String(task.key), "ready");
        } catch (error) {
          await this.setReadiness(String(task.key), "failed");
        }
      }
    };
    this.#tasks = run().finally(() => {
      this.#tasks = undefined;
    });
    return this.#tasks;
  }
  freeze(): Promise<string | null> {
    return this.#exclusive(() => this.#send({ op: "freeze" }));
  }
  acknowledge(sequence: number, receipt: object) {
    return this.#exclusive(() => this.#send({ op: "ack", sequence, receipt }));
  }
  applyPull(page: object) {
    return this.#exclusive(() => this.#send({ op: "pull", page }));
  }
  recordStatus(model: string, identity: object) {
    return this.#exclusive(() =>
      this.#send({ op: "recordStatus", key: { model, identity } }),
    );
  }
  status() {
    return this.#exclusive(() => this.#send({ op: "status" }));
  }
  pendingTasks(): Promise<RecordValue[]> {
    return this.#exclusive(() => this.#send({ op: "tasks" }));
  }
  setReadiness(key: string, state: "ready" | "pending" | "failed") {
    return this.#exclusive(() =>
      this.#send({ op: "readiness", key, state }).then((value) => {
        this.#events.emit("work");
        return value;
      }),
    );
  }
  drop(ordinal: number) {
    return this.#exclusive(() =>
      this.#send({ op: "drop", ordinal }).then((value) => {
        this.#events.emit("work");
        return value;
      }),
    );
  }
  dismissRejection(ordinal: number) {
    return this.#exclusive(() => this.#send({ op: "dismiss", ordinal }));
  }
  watch(
    model: string,
    where: RecordValue = {},
    listener: (rows: RecordValue[]) => void,
    onError: (error: unknown) => void = () => {},
  ) {
    let previous: string | undefined;
    let closed = false;
    const refresh = () => {
      this.query(model, where)
        .then((rows) => {
          const value = strictJson(rows);
          if (!closed && value !== previous) {
            previous = value;
            listener(rows);
          }
        })
        .catch(onError);
    };
    this.#events.on("change", refresh);
    refresh();
    return () => {
      closed = true;
      this.#events.off("change", refresh);
    };
  }
  close(): Promise<void> {
    return (this.#closing ??= this.#finishClose());
  }
  async #finishClose(): Promise<void> {
    await this.#started;
    await this.#connection?.close();
    await this.#exclusive(async () => {
      if (this.#closed) return;
      try {
        await this.#send({ op: "close" });
      } finally {
        this.#closed = true;
        this.#events.removeAllListeners();
      }
    });
  }
}
