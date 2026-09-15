import {
  startConnection,
  type Connection,
  type ConnectionOptions,
  type Transport,
} from "./connection.mts";
export type { Connection, ConnectionOptions } from "./connection.mts";
import { strictJson, type QuerySpec, type RecordValue } from "./values.mts";
import type { ServerOptions, ServerConnection } from "./live.mts";
import { Events } from "./events.mts";

/** Share the existing client orchestration; each host supplies only its carrier, scope and sockets. */
export function createClient<
  Tx extends {
    finish(): Promise<void>;
    mutate(mutation: object): Promise<number>;
  },
>(
  native: { clientCall(request: string): Promise<string> },
  Transaction: new (send: (request: RecordValue) => Promise<any>) => Tx,
  createServerConnection: (options: ServerOptions) => ServerConnection,
) {
  return class Client {
    #liveGeneration = 0;
    #invalidateDownlink: (() => void) | undefined;
    #syncing: Promise<void> | undefined;
    #tasks: Promise<void> | undefined;
    #connection: Connection | undefined;
    #connecting = false;
    #started: Promise<void> | undefined;
    #closing: Promise<void> | undefined;
    #handle: number;
    #closed = false;
    #tail: Promise<unknown> = Promise.resolve();
    #events = new Events();
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
        await native.clientCall(
          strictJson({ ...request, handle: this.#handle }),
        ),
      );
      if (result.changed) this.#events.emit("change");
      return result.value;
    }
    transaction<T>(body: (tx: Tx) => Promise<T>) {
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
      return this.#exclusive(() =>
        this.#send({ op: "querySpec", model, query }),
      );
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
      this.#liveGeneration++;
      this.#invalidateDownlink?.();
      return this.#exclusive(() =>
        this.#send({ op: "channel", channel, subscribed: true }).then(
          (value) => {
            this.#events.emit("channels");
            this.#events.emit("work");
            return value;
          },
        ),
      );
    }
    unsubscribe(channel: string) {
      this.#liveGeneration++;
      this.#invalidateDownlink?.();
      return this.#exclusive(() =>
        this.#send({ op: "channel", channel, subscribed: false }).then(
          (value) => {
            this.#events.emit("channels");
            this.#events.emit("work");
            return value;
          },
        ),
      );
    }
    async connect(
      server: ServerOptions,
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
        if (
          !server ||
          typeof server !== "object" ||
          typeof server.url !== "string" ||
          !(
            typeof server.token === "string" ||
            typeof server.token === "function"
          )
        )
          throw Error("connect requires server: {url, token}");
        const live = createServerConnection(server);
        let refreshing: Promise<void> | undefined;
        const driverOptions = {
          ...options,
          ...(options.refreshAuth
            ? {
                refreshAuth: () =>
                  (refreshing ??= Promise.resolve()
                    .then(() => options.refreshAuth!())
                    .finally(() => {
                      refreshing = undefined;
                    })),
              }
            : {}),
        };
        const control = (event: string, lane?: string) =>
          this.#exclusive(() =>
            this.#send({
              op: "connection",
              event,
              ...(lane ? { lane } : {}),
              now: Date.now(),
              entropy: Math.floor(Math.random() * 0x100000000),
            }),
          );
        const connection = await startConnection(
          (event) => control(event),
          (t) => this.#runSync(t),
          live.push,
          driverOptions,
        );
        let session: AbortController | undefined;
        let streamEpoch = 0;
        const invalidate = () => {
          streamEpoch++;
          session?.abort();
        };
        this.#invalidateDownlink = invalidate;
        const streaming = await startConnection(
          (event) => control(event, "live"),
          async (request) => {
            await request("live", "");
          },
          async (_kind, _body, signal) => {
            const epoch = ++streamEpoch;
            const current = new AbortController();
            session = current;
            const cancel = () => current.abort();
            signal?.addEventListener("abort", cancel, { once: true });
            if (signal?.aborted) cancel();
            try {
              const snapshot = await this.#exclusive(async () => {
                const generation = this.#liveGeneration;
                return {
                  status: await this.#send({ op: "status" }),
                  generation,
                };
              });
              if (
                current.signal.aborted ||
                epoch !== streamEpoch ||
                snapshot.generation !== this.#liveGeneration ||
                snapshot.status.channels.length === 0
              )
                return "";
              const valid = () =>
                !current.signal.aborted &&
                epoch === streamEpoch &&
                snapshot.generation === this.#liveGeneration;
              const deliver = (page: object, request?: string) =>
                this.#exclusive(async () => {
                  if (!valid()) return;
                  const result = await this.#send({
                    op: "downlinkPage",
                    page,
                    ...(request === undefined ? {} : { request }),
                  });
                  if (result.disposition === "applied")
                    this.#events.emit("work");
                  return result;
                });
              const catchUp = async () => {
                for (const scope of snapshot.status.channels) {
                  for (;;) {
                    const body = await this.#exclusive(() =>
                      valid()
                        ? this.#send({ op: "downlinkRequest", scope })
                        : Promise.resolve(undefined),
                    );
                    if (body === undefined || !valid()) return;
                    const response = await live.push(
                      "pull",
                      body,
                      current.signal,
                    );
                    const result = await deliver(JSON.parse(response), body);
                    if (
                      !result ||
                      (!result.continues && result.disposition !== "recover")
                    )
                      break;
                  }
                }
              };
              await live.stream(
                { scopes: snapshot.status.channels },
                async (page) => {
                  const result = await deliver(page);
                  if (result?.disposition === "recover") await catchUp();
                },
                current.signal,
                catchUp,
              );
              return "";
            } finally {
              current.abort();
              signal?.removeEventListener("abort", cancel);
              if (session === current) session = undefined;
            }
          },
          driverOptions,
        );
        const channels = () => {
          invalidate();
          void streaming?.wake().catch(options.onError ?? (() => {}));
        };
        this.#events.on("channels", channels);
        const wake = () => {
          void connection.wake().catch(options.onError ?? (() => {}));
        };
        this.#events.on("work", wake);
        const result = {
          ...connection,
          pause: async () => {
            invalidate();
            await Promise.all([streaming?.pause(), connection.pause()]);
          },
          resume: async () => {
            await Promise.all([streaming?.resume(), connection.resume()]);
          },
          wake: async () => {
            await Promise.all([streaming?.wake(), connection.wake()]);
          },
          close: async () => {
            this.#events.off("work", wake);
            this.#events.off("channels", channels);
            invalidate();
            await Promise.all([streaming?.close(), connection.close()]);
            if (this.#connection === result) {
              this.#connection = undefined;
              this.#invalidateDownlink = undefined;
            }
          },
        };
        this.#connection = result;
        return result;
      } finally {
        this.#connecting = false;
        finished();
      }
    }
    #runSync(transport: Transport): Promise<void> {
      if (this.#syncing) return this.#syncing;
      const run = async () => {
        await this.#exclusive(() =>
          this.#send({ op: "startSync", pushOnly: true }),
        );
        for (;;) {
          const action = await this.#exclusive(() =>
            this.#send({ op: "next" }),
          );
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
          if (!handler)
            throw Error(`Missing prerequisite handler: ${task.name}`);
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
      return this.#exclusive(() =>
        this.#send({ op: "ack", sequence, receipt }),
      );
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
  };
}
