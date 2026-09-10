import { CommittedChanges } from './committed-changes';
import { LocalSyncStorage } from './storage';
import { LocalSyncTransactions } from './transactions';

export interface LocalSyncPersistence<TTx> {
  readonly transactions: LocalSyncTransactions<TTx>;
  readonly storage: LocalSyncStorage<TTx>;
  readonly committedChanges: CommittedChanges;
}
