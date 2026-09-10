import { LocalSyncIdentityError } from './errors';
import { normalizeModelIdentity } from './identity-normalizer';
import { ScopeLedger } from './local-sync-backend';
import { GeneratedBackendContract, SyncModelDescriptor } from './model-binding';
import { normalizeScopes } from './scopes';
import { LocalSyncStorage } from './storage';

const maximumSignedInt64 = (1n << 63n) - 1n;

export interface ScopeLedgerOptions<TTx> {
  readonly contract: GeneratedBackendContract;
  readonly storage: LocalSyncStorage<TTx>;
  readonly registeredModels: ReadonlySet<string>;
}

export function createScopeLedger<TTx>(
  options: ScopeLedgerOptions<TTx>,
): ScopeLedger<TTx> {
  return new TransactionalScopeLedger(
    options.contract,
    options.storage,
    options.registeredModels,
  );
}

class TransactionalScopeLedger<TTx> implements ScopeLedger<TTx> {
  constructor(
    private readonly contract: GeneratedBackendContract,
    private readonly storage: LocalSyncStorage<TTx>,
    private readonly registeredModels: ReadonlySet<string>,
  ) {}

  async invalidate<TIdentity extends object>(
    transaction: TTx,
    input: Readonly<{
      model: SyncModelDescriptor<TIdentity>;
      identity: TIdentity;
      scopes: readonly string[];
    }>,
  ): Promise<void> {
    const normalized = this.normalizeIdentity(input.model, input.identity);
    const scopes = normalizeScopes(input.scopes);
    for (const scope of scopes) {
      const head = await this.storage.lockOrCreateDownlinkHead(transaction, scope);
      if (typeof head !== 'bigint' || head < 0n || head >= maximumSignedInt64) {
        throw new RangeError(
          `invalid or exhausted Downlink head for scope "${scope}"`,
        );
      }
      const syncId = head + 1n;
      await this.storage.writeDownlinkHead(transaction, scope, syncId);
      await this.storage.upsertInvalidation(
        transaction,
        Object.freeze({
          scope,
          modelKey: normalized.modelKey,
          identityKey: normalized.key,
          identityBytes: normalized.bytes,
          syncId,
        }),
      );
    }
  }

  async scopesFor<TIdentity extends object>(
    transaction: TTx,
    input: Readonly<{
      model: SyncModelDescriptor<TIdentity>;
      identity: TIdentity;
    }>,
  ): Promise<readonly string[]> {
    const normalized = this.normalizeIdentity(input.model, input.identity);
    const scopes = await this.storage.findInvalidationScopes(transaction, {
      modelKey: normalized.modelKey,
      identityKey: normalized.key,
    });
    return normalizeScopes(scopes);
  }

  private normalizeIdentity<TIdentity extends object>(
    model: SyncModelDescriptor<TIdentity>,
    identity: TIdentity,
  ) {
    const normalized = normalizeModelIdentity(this.contract, model, identity);
    if (!this.registeredModels.has(normalized.modelKey)) {
      throw new LocalSyncIdentityError(
        `Model "${normalized.model.name}" has no registered Backend loader`,
      );
    }
    return normalized;
  }
}
