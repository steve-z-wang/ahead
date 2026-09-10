import {
  PrincipalPull,
  PrincipalSubscription,
  PrincipalUpload,
} from './context';
import { SyncModelDescriptor } from './model-binding';

export interface ScopeLedger<TTx> {
  invalidate<TIdentity extends object>(
    transaction: TTx,
    input: Readonly<{
      model: SyncModelDescriptor<TIdentity>;
      identity: TIdentity;
      scopes: readonly string[];
    }>,
  ): Promise<void>;
  scopesFor<TIdentity extends object>(
    transaction: TTx,
    input: Readonly<{
      model: SyncModelDescriptor<TIdentity>;
      identity: TIdentity;
    }>,
  ): Promise<readonly string[]>;
}

export interface DownlinkPage {
  readonly bytes: Uint8Array;
}

export interface LocalSyncBackend<TTx> {
  readonly scopeLedger: ScopeLedger<TTx>;
  upload(input: PrincipalUpload): Promise<Uint8Array>;
  pullDownlink(input: PrincipalPull): Promise<DownlinkPage>;
  subscribeDownlink(
    input: PrincipalSubscription & {
      readonly signal: AbortSignal;
      readonly onListening?: () => void;
      readonly waitForCommit?: boolean;
    },
  ): AsyncGenerator<DownlinkPage>;
  close(): Promise<void>;
}
