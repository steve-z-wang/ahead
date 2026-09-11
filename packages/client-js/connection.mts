export type Transport = (
  kind: string,
  body: string,
  signal?: AbortSignal,
) => Promise<string>;
export type ConnectionOptions = {
  onError?: (error: unknown) => void;
  refreshAuth?: () => Promise<void>;
};
export type Connection = {
  pause(): Promise<void>;
  resume(): Promise<void>;
  wake(): Promise<void>;
  close(): Promise<void>;
};
/** Host timers/network only. Rust decides when work/retries are eligible. */
export async function startConnection(
  control: (event: string) => Promise<any>,
  sync: (transport: Transport) => Promise<void>,
  transport: Transport,
  options: ConnectionOptions = {},
): Promise<Connection> {
  let epoch = 0;
  let stopped = false;
  let paused = false;
  let active: Promise<void> | undefined;
  let awaken: (() => void) | undefined;
  let abort = new AbortController();
  const notify = () => {
    epoch++;
    awaken?.();
    awaken = undefined;
  };
  const wait = (millis?: number) =>
    new Promise<void>((resolve) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      awaken = () => {
        if (timer !== undefined) clearTimeout(timer);
        resolve();
      };
      if (millis !== undefined)
        timer = setTimeout(() => {
          awaken = undefined;
          resolve();
        }, millis);
    });
  const request: Transport = async (kind, body) => {
    if (stopped || paused || abort.signal.aborted)
      throw Error("connection_paused_or_closed");
    const signal = abort.signal;
    return new Promise<string>((resolve, reject) => {
      const cancel = () => reject(Error("connection_closed"));
      signal.addEventListener("abort", cancel, { once: true });
      Promise.resolve()
        .then(() => transport(kind, body, signal))
        .then(resolve, reject)
        .finally(() => signal.removeEventListener("abort", cancel));
    });
  };
  await control("start");
  const loop = async () => {
    while (!stopped) {
      const observed = epoch;
      const action = await control("next");
      if (stopped) return;
      if (action.type === "sync") {
        try {
          abort = new AbortController();
          active = sync(request);
          await active;
          if (!stopped) await control("success");
        } catch (error) {
          if (stopped) return;
          if (paused) {
            await control("success");
            continue;
          }
          options.onError?.(error);
          if (
            (error as { status?: number })?.status === 401 &&
            options.refreshAuth
          ) {
            try {
              await options.refreshAuth();
            } catch (refreshError) {
              options.onError?.(refreshError);
            }
          }
          if (!stopped) await control("failure");
        } finally {
          active = undefined;
        }
      } else {
        if (observed !== epoch) continue;
        await wait(action.type === "wait" ? action.millis : undefined);
      }
    }
  };
  void loop().catch((error) => {
    if (!stopped) options.onError?.(error);
  });
  return {
    async pause() {
      if (stopped) return;
      paused = true;
      abort.abort();
      await control("pause");
      await active?.catch(() => {});
      notify();
    },
    async resume() {
      if (stopped) return;
      paused = false;
      await control("resume");
      notify();
    },
    async wake() {
      if (stopped) return;
      await control("wake");
      notify();
    },
    async close() {
      if (stopped) return;
      stopped = true;
      abort.abort();
      notify();
      await control("stop");
    },
  };
}
