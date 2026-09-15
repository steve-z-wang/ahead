import { httpTransport } from "../client-js/transport.mts";
import type { ServerOptions, ServerConnection } from "../client-js/live.mts";

/** The native WebSocket API has no pause/resume; overflow recovers from Rust's durable cursor. */
interface Socket {
  onopen: (() => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onerror: ((event: { message?: string }) => void) | null;
  onclose: ((event: { code: number; reason?: string }) => void) | null;
  send(data: string): void;
  close(): void;
}
type SocketConstructor = new (
  url: string,
  protocols: string[],
  options: { headers: Record<string, string> },
) => Socket;

export function createServerConnection(
  options: ServerOptions,
  SocketClass = globalThis.WebSocket as unknown as SocketConstructor,
): ServerConnection {
  const base = new URL(options.url.replace(/\/$/, "") + "/sync/live");
  base.protocol =
    base.protocol === "https:" || base.protocol === "wss:" ? "wss:" : "ws:";
  const http = new URL(options.url);
  http.protocol =
    http.protocol === "https:" || http.protocol === "wss:" ? "https:" : "http:";
  return {
    push: httpTransport({
      ...options,
      url: http.toString().replace(/\/$/, ""),
    }),
    stream(subscription, apply, signal, catchUp) {
      return new Promise<void>((resolve, reject) => {
        let socket: Socket | undefined;
        let ended = false;
        let subscribed = false;
        let processing = false;
        let recovery = false;
        const pages: object[] = [];
        const finish = (error?: unknown) => {
          if (ended) return;
          ended = true;
          pages.length = 0;
          signal.removeEventListener("abort", cancel);
          if (socket) {
            socket.onopen =
              socket.onmessage =
              socket.onerror =
              socket.onclose =
                null;
            try {
              socket.close();
            } catch {
              /* The connection may already be closed. */
            }
          }
          if (error === undefined) resolve();
          else reject(error);
        };
        const cancel = () => finish();
        const drain = async () => {
          if (processing || ended) return;
          processing = true;
          try {
            while (!ended && (recovery || pages.length)) {
              if (recovery) {
                recovery = false;
                await catchUp();
              } else await apply(pages.shift()!);
            }
          } catch (error) {
            finish(error);
          } finally {
            processing = false;
          }
        };
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
            socket = new SocketClass(base.toString(), [], {
              headers: { authorization: `Bearer ${token}` },
            });
            socket.onopen = () => {
              if (ended) return;
              try {
                socket!.send(
                  JSON.stringify({ type: "subscribe", ...subscription }),
                );
              } catch (error) {
                finish(error);
              }
            };
            socket.onerror = (event) =>
              finish(Error(event.message ?? "live connection failed"));
            socket.onclose = (event) =>
              finish(
                Error(`live disconnected: ${event.code} ${event.reason ?? ""}`),
              );
            socket.onmessage = (event) => {
              if (ended) return;
              try {
                if (
                  typeof event.data !== "string" ||
                  event.data.length > 8 * 1024 * 1024
                )
                  throw Error("invalid live message");
                const page = JSON.parse(event.data);
                if (!subscribed) {
                  if (
                    !page ||
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
                  if (
                    !page ||
                    typeof page !== "object" ||
                    Array.isArray(page) ||
                    page.type !== undefined
                  )
                    throw Error("invalid live page");
                  if (pages.length === 64) {
                    pages.length = 0;
                    recovery = true;
                  }
                  pages.push(page);
                }
                void drain();
              } catch (error) {
                finish(error);
              }
            };
          })
          .catch(finish);
      });
    },
  };
}
