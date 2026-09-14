import WebSocket from "ws";
import { httpTransport } from "./transport.mts";
import type { Transport } from "./connection.mts";

export type LiveSubscription = {
  scopes: string[];
};
type ServerConnection = {
  readonly push: Transport;
  stream(
    subscription: LiveSubscription,
    apply: (page: object) => Promise<void>,
    signal: AbortSignal,
    catchUp: () => Promise<void>,
  ): Promise<void>;
};
export type ServerOptions = {
  url: string;
  token: string | (() => string | Promise<string>);
};
/** Internal sockets and HTTP adapter for one server connection. */
export function createServerConnection(
  options: ServerOptions,
): ServerConnection {
  const base = new URL(options.url.replace(/\/$/, "") + "/sync/live");
  base.protocol =
    base.protocol === "https:" || base.protocol === "wss:" ? "wss:" : "ws:";
  const http = new URL(options.url);
  http.protocol =
    http.protocol === "wss:" || http.protocol === "https:" ? "https:" : "http:";
  return {
    push: httpTransport({
      ...options,
      url: http.toString().replace(/\/$/, ""),
    }),
    stream(subscription, apply, signal, catchUp) {
      return new Promise<void>((resolve, reject) => {
        let socket: WebSocket | undefined;
        let ended = false;
        let subscribed = false;
        const pages: object[] = [];
        let processing = false;
        let recovery = false;
        const drain = async () => {
          if (processing || ended) return;
          processing = true;
          socket?.pause();
          try {
            while (!ended && (recovery || pages.length)) {
              if (recovery) {
                recovery = false;
                await catchUp();
              } else {
                await apply(pages.shift()!);
              }
            }
          } catch (error) {
            finish(error);
          } finally {
            processing = false;
            if (!ended) socket?.resume();
          }
        };
        const finish = (error?: unknown) => {
          if (ended) return;
          ended = true;
          signal.removeEventListener("abort", cancel);
          // terminate also cancels an upgrade still in progress. Keep the error listener
          // installed until close, since ws emits an error when terminating CONNECTING.
          socket?.terminate();
          if (error === undefined) resolve();
          else reject(error);
        };
        const cancel = () => finish();
        signal.addEventListener("abort", cancel, { once: true });
        if (signal.aborted) return cancel();
        void Promise.resolve()
          .then(() =>
            typeof options.token === "function"
              ? options.token()
              : options.token,
          )
          .then((token) => {
            if (ended) return;
            socket = new WebSocket(base, {
              headers: { authorization: `Bearer ${token}` },
              maxPayload: 8 * 1024 * 1024,
            });
            const current = socket;
            current.on("error", (error) => finish(error));
            current.on("unexpected-response", (_request, response) => {
              response.resume();
              finish(
                Object.assign(Error(`live failed: ${response.statusCode}`), {
                  status: response.statusCode,
                }),
              );
            });
            current.on("close", (code, reason) =>
              finish(Error(`live disconnected: ${code} ${reason}`)),
            );
            current.on("open", () => {
              if (ended) return current.terminate();
              current.send(
                JSON.stringify({ type: "subscribe", ...subscription }),
              );
            });
            current.on("message", (data) => {
              if (ended) return;
              try {
                const page = JSON.parse(data.toString());
                if (!subscribed) {
                  if (
                    page.type !== "subscribed" ||
                    !Array.isArray(page.scopes) ||
                    JSON.stringify([...page.scopes].sort()) !==
                      JSON.stringify([...subscription.scopes].sort()) ||
                    page.rejections?.length !== 0
                  )
                    throw Error("invalid live subscription acknowledgement");
                  subscribed = true;
                  recovery = true;
                } else {
                  if (page.type !== undefined) throw Error("invalid live page");
                  if (pages.length === 64) {
                    // Keep the in-flight HTTP request alive. Its completion advances
                    // the durable cursor even under sustained incoming traffic.
                    pages.length = 0;
                    recovery = true;
                  }
                  pages.push(page);
                }
                void drain();
              } catch (error) {
                finish(error);
              }
            });
          })
          .catch(finish);
      });
    },
  };
}
