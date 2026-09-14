import WebSocket from "ws";
import { httpTransport } from "./transport.mts";
import type { Transport } from "./connection.mts";

export type LiveSubscription = {
  scopes: string[];
  cursors: Record<string, number>;
};
export type LiveTransport = {
  readonly push: Transport;
  stream(
    subscription: LiveSubscription,
    apply: (page: object) => Promise<void>,
    signal: AbortSignal,
  ): Promise<void>;
};
/** Node WebSocket catch-up/streaming, with HTTP mutation push using the same credentials. */
export function websocketTransport(options: {
  url: string;
  token: string | (() => string | Promise<string>);
}): LiveTransport {
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
    stream(subscription, apply, signal) {
      return new Promise<void>((resolve, reject) => {
        let socket: WebSocket | undefined;
        let ended = false;
        let subscribed = false;
        let queued = 0;
        let tail = Promise.resolve();
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
              if (++queued > 64)
                return finish(Error("live receive queue exceeded"));
              current.pause();
              tail = tail
                .then(async () => {
                  if (ended) return;
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
                  } else {
                    if (page.type !== undefined)
                      throw Error("invalid live page");
                    await apply(page);
                  }
                })
                .catch(finish)
                .finally(() => {
                  queued--;
                  if (!ended && queued === 0) current.resume();
                });
            });
          })
          .catch(finish);
      });
    },
  };
}
