import type { LocalSyncBackend } from 'local-sync-backend';
import { createLocalSyncBackend } from 'local-sync-backend';
import { generatedContract } from '../../generated/backend/backend_contract';
import { InMemoryLocalSyncPersistence } from './in-memory-persistence';
import type { InMemoryTx } from './in-memory-transactions';
import { conformanceModels } from './model-bindings';
import {
  conformancePrincipalScope,
  conformanceScopeAuthorizer,
  conformanceScopesForModel,
} from './scopes';
import {
  conformanceMutationContract,
  conformanceMutationResolvers,
  conformanceRejectionTranslator,
} from './mutation-resolvers';

export interface ConformanceHost {
  readonly backend: LocalSyncBackend<InMemoryTx>;
  readonly persistence: InMemoryLocalSyncPersistence;
}

/**
 * The Conformance host: real Framework, real generated contract, fake storage.
 * There is no second copy of any sync algorithm here. Passing an existing
 * `persistence` builds a fresh backend over rows that are already there, which
 * is what surviving a restart looks like from the storage side.
 */
export function createConformanceHost(
  options: { readonly persistence?: InMemoryLocalSyncPersistence } = {},
): ConformanceHost {
  const persistence = options.persistence ?? new InMemoryLocalSyncPersistence();
  let backend: LocalSyncBackend<InMemoryTx> | null = null;
  const { bindings, store } = conformanceModels(() => {
    if (backend === null) {
      throw new Error('ScopeLedger used before the backend was created');
    }
    return backend.scopeLedger;
  }, conformanceScopesForModel);
  backend = createLocalSyncBackend({
    contract: generatedContract,
    models: bindings,
    mutationContract: conformanceMutationContract,
    mutations: conformanceMutationResolvers(store),
    translateRejection: conformanceRejectionTranslator,
    persistence,
    scopeAuthorizer: conformanceScopeAuthorizer,
    principalScope: conformancePrincipalScope,
  });
  return { backend, persistence };
}
