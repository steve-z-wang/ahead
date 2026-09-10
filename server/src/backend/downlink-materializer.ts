import { BackendComponents } from "./backend-options";
import { BackendReadContext, PrincipalPull } from "./context";
import { downlinkPageSize, validateSyncId } from "./downlink-cursor";
import { LocalSyncProtocolError, LocalSyncScopeForbiddenError } from "./errors";
import { normalizeModelIdentity } from "./identity-normalizer";
import { DownlinkPage } from "./local-sync-backend";
import { SyncModelDescriptor } from "./model-binding";
import { normalizeModelState } from "./state-normalizer";
import { CompactedInvalidation } from "./storage";
import {
  DownlinkChangeEnvelope,
  decodeDownlinkRequestEnvelope,
  encodeDownlinkPageEnvelope,
} from "./json-envelope";

interface SelectedInvalidation {
  readonly row: CompactedInvalidation;
  readonly modelKey: string;
  readonly model: SyncModelDescriptor;
  readonly identity: object;
}

export interface DownlinkMaterializer {
  pull(input: PrincipalPull): Promise<DownlinkPage>;
}

export function createDownlinkMaterializer<TTx>(
  components: BackendComponents<TTx>,
): DownlinkMaterializer {
  return new DefaultDownlinkMaterializer(components);
}

class DefaultDownlinkMaterializer<TTx> implements DownlinkMaterializer {
  constructor(private readonly components: BackendComponents<TTx>) {}

  /**
   * One materialization path, for every cursor (CAP-482). Zero is a number and not a
   * control message: it selects the same `syncId > fromCursor` scan every
   * other cursor selects, so a device that rewound — a fresh install, or one
   * whose `replayDownlink` migration reset it to read server truth into a
   * shape it could not hold before — is simply served every invalidation this
   * viewer's ledger retained, materialized at today's state by the loaders.
   *
   * `LocalSyncInvalidation` is the Downlink's one source. A row that was
   * changed without an invalidation is absent from every pull, at any cursor;
   * that is a broken producer to fix, not something a pull discovers.
   */
  async pull(input: PrincipalPull): Promise<DownlinkPage> {
    if (
      typeof input.principal.userId !== "string" ||
      input.principal.userId.trim().length === 0 ||
      !(input.requestBytes instanceof Uint8Array)
    ) {
      throw new LocalSyncProtocolError("invalid authenticated Downlink call");
    }
    return this.serve(input, decodeDownlinkRequestEnvelope(input.requestBytes));
  }

  private async serve(
    input: PrincipalPull,
    cursor: { readonly scope: string; readonly afterSyncId: bigint },
  ): Promise<DownlinkPage> {
    return this.components.persistence.transactions.write(
      async (transaction) => {
        const allowed = await this.components.scopeAuthorizer.canRead(
          { transaction, viewerUserId: input.principal.userId },
          cursor.scope,
        );
        if (!allowed) throw new LocalSyncScopeForbiddenError();
        const stored =
          await this.components.persistence.storage.readDownlinkHead(
            transaction,
            cursor.scope,
          );
        const head = validateSyncId(stored, "Downlink head");
        // A cursor past the head names sync IDs this backend never issued to
        // this viewer (a swapped database, a client pointed at the wrong
        // host). Answering would emit a page that walks the cursor backwards.
        if (cursor.afterSyncId > head) {
          throw new LocalSyncProtocolError(
            "Downlink cursor is ahead of the scope head",
          );
        }
        const rows =
          await this.components.persistence.storage.scanInvalidations(
            transaction,
            {
              scope: cursor.scope,
              afterSyncId: cursor.afterSyncId,
              limit: downlinkPageSize,
            },
          );
        const selected = this.selectRows(
          rows,
          cursor.scope,
          cursor.afterSyncId,
          head,
        );
        const changes = await this.materialize(
          transaction,
          input.principal.userId,
          selected,
          cursor.scope,
        );
        const throughSyncId =
          selected.length === downlinkPageSize
            ? selected[selected.length - 1].row.syncId
            : head;
        return Object.freeze({
          bytes: encodeDownlinkPageEnvelope({
            scope: cursor.scope,
            fromSyncId: cursor.afterSyncId,
            changes,
            throughSyncId,
          }),
        });
      },
    );
  }

  private selectRows(
    rows: readonly CompactedInvalidation[],
    scope: string,
    afterSyncId: bigint,
    head: bigint,
  ): readonly SelectedInvalidation[] {
    if (!Array.isArray(rows) || rows.length > downlinkPageSize) {
      throw new Error(
        "LocalSync storage returned an invalid invalidation page",
      );
    }
    let previous = afterSyncId;
    return rows.map((row) => {
      const syncId = validateSyncId(row.syncId, "invalidation sync ID");
      if (row.scope !== scope || syncId <= previous || syncId > head) {
        throw new Error(
          "LocalSync storage returned an invalid invalidation order",
        );
      }
      previous = syncId;
      const model = this.components.contract.models[row.modelKey];
      if (model === undefined) {
        throw new Error(
          "LocalSync storage returned an unknown Model invalidation",
        );
      }
      // Storage naming a Model this Backend registered no loader for is an
      // invariant defect, never a state to skip: the row was claimed by a
      // Scope Ledger write that should itself have been refused (CAP-488).
      if (this.components.models[row.modelKey] === undefined) {
        throw new Error(
          "LocalSync storage returned an invalidation for an unregistered Model",
        );
      }
      const identity = decodeStoredIdentity(row.identityBytes);
      const normalized = normalizeModelIdentity(
        this.components.contract,
        model,
        identity,
      );
      if (normalized.key !== row.identityKey) {
        throw new Error("LocalSync storage returned a noncanonical identity");
      }
      return Object.freeze({
        row,
        modelKey: row.modelKey,
        model,
        identity: normalized.value,
      });
    });
  }

  private async materialize(
    transaction: TTx,
    viewerUserId: string,
    selected: readonly SelectedInvalidation[],
    scope: string,
  ): Promise<readonly DownlinkChangeEnvelope[]> {
    const groups = new Map<string, SelectedInvalidation[]>();
    for (const item of selected) {
      const group = groups.get(item.modelKey);
      if (group === undefined) groups.set(item.modelKey, [item]);
      else group.push(item);
    }
    const resultByRow = new Map<CompactedInvalidation, unknown>();
    const context: BackendReadContext<TTx> = Object.freeze({
      transaction,
      viewerUserId,
      scope,
    });
    for (const [modelKey, group] of groups) {
      const model = group[0].model;
      const identities = Object.freeze(group.map((item) => item.identity));
      const binding = this.components.models[modelKey];
      await binding.read.prepareForViewer?.(
        context,
        identities as readonly never[],
      );
      const values = await callReadForwarder(model.forward.read, [
        binding,
        context,
        identities,
      ]);
      if (!Array.isArray(values) || values.length !== group.length) {
        throw new Error("LocalSync Model read returned a misaligned result");
      }
      values.forEach((value, index) => {
        if (
          value !== null &&
          (typeof value !== "object" || Array.isArray(value))
        ) {
          throw new Error("LocalSync Model read returned an invalid state");
        }
        resultByRow.set(group[index].row, value);
      });
    }
    // Absence is the whole signal: a row the viewer may no longer read leaves
    // exactly as a deleted one does, and the client's cascade keys off that.
    return Object.freeze(
      selected.map((item) => {
        const state = resultByRow.get(item.row);
        return Object.freeze({
          syncId: item.row.syncId,
          model: item.model.name,
          identity: item.identity,
          state:
            state === null
              ? null
              : normalizeModelState(item.model, state as object),
        });
      }),
    );
  }
}

function decodeStoredIdentity(bytes: Uint8Array): unknown {
  if (!(bytes instanceof Uint8Array)) {
    throw new Error("LocalSync storage returned invalid identity bytes");
  }
  try {
    return JSON.parse(Buffer.from(bytes).toString("utf8"));
  } catch {
    throw new Error("LocalSync storage returned invalid identity bytes");
  }
}

async function callReadForwarder(
  forwarder: (...arguments_: never[]) => Promise<unknown>,
  arguments_: readonly unknown[],
): Promise<unknown> {
  const call = forwarder as unknown as (
    ...values: readonly unknown[]
  ) => Promise<unknown>;
  return call(...arguments_);
}
