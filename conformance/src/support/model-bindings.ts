import {
  LocalSyncMutationRejected,
  type BackendReadContext,
  type BackendWriteContext,
  type ScopeLedger,
  type SyncModelDescriptor,
} from 'local-sync-backend';
import {
  generatedContract,
  type GeneratedBackendModelBindings,
} from '../../generated/backend/backend_contract';
import type { DatabaseState, StoredRow } from './in-memory-database';
import type { InMemoryTx } from './in-memory-transactions';

/**
 * A caption that says this is what a deterministic rejection is for. A create
 * carrying it and an update setting it are both refused, so a client can be
 * refused an edit to a row the server already has.
 */
export const rejectedCaption = 'reject-me';
export const rejectionCode = 'conformance.rejected';

type Row = Record<string, unknown>;

export function conformanceRows(
  transaction: InMemoryTx,
  model: string,
): Map<string, StoredRow> {
  return rows(transaction, model);
}

export function conformanceIdentityKey(
  descriptor: SyncModelDescriptor,
  identity: Row,
): string {
  return identityKey(descriptor, identity);
}

function rows(
  transaction: InMemoryTx,
  model: string,
): Map<string, StoredRow> {
  const existing = transaction.state.rows.get(model);
  if (existing !== undefined) return existing;
  const created = new Map<string, StoredRow>();
  transaction.state.rows.set(model, created);
  return created;
}

function identityKey(
  descriptor: SyncModelDescriptor,
  identity: Row,
): string {
  return descriptor.identityFields
    .map((field) => String(identity[field]))
    .join('\u0000');
}

/**
 * One shape for every Model: the Framework already knows each Model's fields,
 * so a per-Model copy of this would only be a copy.
 *
 * The read half is the Model binding the Framework asks for. The write half is
 * the reference host's OWN store — since CAP-444 a binding carries no writes,
 * because a write is an act, and the resolvers reach rows through here.
 */
function binding(
  descriptor: SyncModelDescriptor,
  scopeLedger: () => ScopeLedger<InMemoryTx>,
  scopesForModel: (model: string, identity: Row) => readonly string[],
) {
  const model = descriptor.name;

  async function publish(
    context: BackendWriteContext<InMemoryTx>,
    identity: Row,
  ): Promise<void> {
    await scopeLedger().invalidate(context.transaction, {
      model: descriptor,
      identity,
      scopes: scopesForModel(model, identity),
    });
  }

  const write = {
      async create(
        context: BackendWriteContext<InMemoryTx>,
        identity: Row,
        data: Row,
      ): Promise<void> {
        if (data.caption === rejectedCaption) {
          throw new LocalSyncMutationRejected(rejectionCode);
        }
        rows(context.transaction, model).set(identityKey(descriptor, identity), {
          state: { ...identity, ...data },
          viewers: [context.actorUserId],
        });
        await publish(context, identity);
      },

      async update(
        context: BackendWriteContext<InMemoryTx>,
        identity: Row,
        patch: Row,
      ): Promise<void> {
        const key = identityKey(descriptor, identity);
        if (patch.caption === rejectedCaption) {
          throw new LocalSyncMutationRejected(rejectionCode);
        }
        const stored = rows(context.transaction, model).get(key);
        if (stored === undefined) {
          throw new LocalSyncMutationRejected('conformance.missing');
        }
        rows(context.transaction, model).set(key, {
          state: { ...stored.state, ...patch },
          viewers: stored.viewers,
        });
        await publish(context, identity);
      },

      async delete(
        context: BackendWriteContext<InMemoryTx>,
        identity: Row,
      ): Promise<void> {
        const key = identityKey(descriptor, identity);
        await scopeLedger().invalidate(context.transaction, {
          model: descriptor,
          identity,
          scopes: scopesForModel(model, identity),
        });
        rows(context.transaction, model).delete(key);
      },
  };

  const read = {
      async forViewer(
        context: BackendReadContext<InMemoryTx>,
        identities: readonly Row[],
      ): Promise<readonly (Row | null)[]> {
        return identities.map((identity) => {
          const stored = rows(context.transaction, model).get(
            identityKey(descriptor, identity),
          );
          if (stored === undefined) return null;
          return stored.viewers.includes(context.viewerUserId)
            ? stored.state
            : null;
        });
      },
  };

  return { read, write };
}

/** Every Model's row store, by the same key the generated contract uses. */
export type ConformanceModelStore = Record<
  string,
  ReturnType<typeof binding>['write']
>;

function conformanceBindings(
  scopeLedger: () => ScopeLedger<InMemoryTx>,
  scopesForModel: (model: string, identity: Row) => readonly string[],
): Record<string, ReturnType<typeof binding>> {
  const built: Record<string, ReturnType<typeof binding>> = {};
  for (const [key, descriptor] of Object.entries(generatedContract.models)) {
    built[key] = binding(
      descriptor as unknown as SyncModelDescriptor,
      scopeLedger,
      scopesForModel,
    );
  }
  return built;
}

/**
 * The reads the Framework binds, and the writes the resolvers use — built
 * together because they share one row map per Model.
 */
export function conformanceModels(
  scopeLedger: () => ScopeLedger<InMemoryTx>,
  scopesForModel: (model: string, identity: Row) => readonly string[],
): {
  bindings: GeneratedBackendModelBindings<InMemoryTx>;
  store: ConformanceModelStore;
} {
  const built = conformanceBindings(scopeLedger, scopesForModel);
  const bindings: Record<string, unknown> = {};
  const store: ConformanceModelStore = {};
  for (const [key, value] of Object.entries(built)) {
    bindings[key] = { read: value.read };
    store[key] = value.write;
  }
  return {
    bindings: bindings as unknown as GeneratedBackendModelBindings<InMemoryTx>,
    store,
  };
}

export function conformanceModelBindings(
  scopeLedger: () => ScopeLedger<InMemoryTx>,
  scopesForModel: (model: string) => readonly string[],
): GeneratedBackendModelBindings<InMemoryTx> {
  return conformanceModels(scopeLedger, scopesForModel).bindings;
}
