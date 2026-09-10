export interface LocalSyncTransactions<TTx> {
  write<T>(work: (transaction: TTx) => Promise<T>): Promise<T>;
  readSnapshot<T>(work: (transaction: TTx) => Promise<T>): Promise<T>;
  savepoint<T>(transaction: TTx, work: () => Promise<T>): Promise<T>;
}
