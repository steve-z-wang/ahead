/** M0 probe only. Framework/business model names are fixture data, not a final SDK API. */
export interface ProbeTransaction {
  frameworkProbe: {
    create(args: {data: {id: string}}): Promise<unknown>;
    count(): Promise<number>;
  };
}
export interface ProbeResult {
  observed: number;
  callbackCount: number;
  /** UTF-8 operation bytes plus fixed-width u32 callback results; excludes ABI overhead. */
  payloadBytes: number;
  elapsedMicros: number;
}
export declare class TransactionProbe {
  constructor(tx: ProbeTransaction, options?: {beforeCallback?: (operation: string) => Promise<void>});
  run(id: string, options?: {failAfterWrite?: boolean}): Promise<ProbeResult>;
  assertCommittable(): void;
  close(): void;
}
export declare function committedResult<Tx extends ProbeTransaction, T>(
  transactionRunner: (body: (tx: Tx) => Promise<T>) => Promise<T>,
  body: (tx: Tx) => Promise<T>,
): Promise<T>;
