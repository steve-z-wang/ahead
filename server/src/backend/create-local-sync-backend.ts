import {
  LocalSyncBackendOptions,
  validateBackendOptions,
} from './backend-options';
import { createDownlinkMaterializer } from './downlink-materializer';
import { createDownlinkSubscriptions } from './downlink-subscription';
import { LocalSyncBackend } from './local-sync-backend';
import { createScopeLedger } from './scope-ledger';
import { createUplinkExecutor } from './uplink-executor';

export function createLocalSyncBackend<TTx>(
  options: LocalSyncBackendOptions<TTx>,
): LocalSyncBackend<TTx> {
  const components = validateBackendOptions(options);
  const scopeLedger = createScopeLedger({
    contract: components.contract,
    storage: components.persistence.storage,
    registeredModels: new Set(Object.keys(components.models)),
  });
  const uplink = createUplinkExecutor(components);
  const downlink = createDownlinkMaterializer(components);
  const subscriptions = createDownlinkSubscriptions({
    contract: components.contract,
    materializer: downlink,
    committedChanges: components.persistence.committedChanges,
  });
  let closePromise: Promise<void> | null = null;

  return Object.freeze({
    scopeLedger,
    upload: uplink.execute.bind(uplink),
    pullDownlink: downlink.pull.bind(downlink),
    subscribeDownlink: subscriptions.subscribe.bind(subscriptions),
    close(): Promise<void> {
      if (closePromise === null) {
        subscriptions.close();
        closePromise = Promise.resolve().then(() =>
          components.persistence.committedChanges.close(),
        );
      }
      return closePromise;
    },
  });
}
