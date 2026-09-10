import { LocalSyncMutationRejected } from 'local-sync-backend';
import {
  generatedMutations,
  type LocalSyncMutations,
} from '../../generated/backend/backend_contract';
import type { ConformanceModelStore } from './model-bindings';
import type { InMemoryTx } from './in-memory-transactions';
import { conformanceSettlementForModel } from './scopes';

/**
 * One resolver per declared act (CAP-439) — the reference host's half of the
 * named write surface.
 *
 * Slot fields arrive fully typed, so nothing here switches on an operation or
 * unpacks a container. The resolvers write through the host's own row store —
 * a Model binding carries reads alone since CAP-444 — which is the point: the
 * payload is the client's optimistic guess at the act, and the business the
 * name triggers is the server's own.
 */

/** A tag label the host refuses, so an act can be refused whole. */
export const rejectedTagLabel = 'reject-me';

/** A refusal a service throws bare, translated once at wiring (CAP-441). */
export class ConformanceRefusal extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export function conformanceRejectionTranslator(error: unknown): string | null {
  return error instanceof ConformanceRefusal ? error.code : null;
}

/**
 * The row the host writes on its own — no operation in the request names it,
 * and it still reaches the client. The Dart journey knows the same literal.
 */
export const conformanceSideEffectLinkId =
  'e7c9a1b2-3d4e-4f50-8617-2839a4b5c6d7';

export function conformanceMutationResolvers(
  models: ConformanceModelStore,
): LocalSyncMutations<InMemoryTx> {
  const renameSpace: LocalSyncMutations<InMemoryTx>['renameSpace']['v1'] =
    async (context, { space }) => {
      if (Object.keys(space.patch).some((field) => field !== 'name')) {
        throw new LocalSyncMutationRejected('rename_space.not_allowed');
      }
      await models.space.update(context, space.identity, space.patch);
      return conformanceSettlementForModel('Space', space.identity);
    };
  return {
    captureMoment: {
      v1: async (context, { moment, tags, star }) => {
        await models.moment.create(context, moment.identity, moment.data);
        if (moment.data.caption === rejectedTagLabel) {
          throw new ConformanceRefusal('capture_moment.not_allowed');
        }
        for (const tag of tags) {
          if (tag.data.label === rejectedTagLabel) {
            // Thrown bare: the resolver knows the refusal, not the wire code.
            throw new ConformanceRefusal('capture_moment.not_allowed');
          }
          await models.starTag.create(context, tag.identity, tag.data);
        }
        await models.star.create(context, star.identity, star.data);

        // The server is authoritative and unconstrained by the payload: this row
        // has no operation in the request, and it still reaches the client.
        await models.momentLink.create(
          context,
          { id: conformanceSideEffectLinkId },
          { sourceId: moment.identity.id, targetId: moment.identity.id },
        );
      },
    },

    reviseMoment: {
      v1: async (context, { moment, removedTags, addedTags, star }) => {
        // Declaration order is execution order: the removals run before the
        // additions because the schema says so.
        await models.moment.update(context, moment.identity, moment.patch);
        for (const tag of removedTags) {
          await models.starTag.delete(context, tag.identity);
        }
        for (const tag of addedTags) {
          await models.starTag.create(context, tag.identity, tag.data);
        }
        if (star !== null) {
          await models.star.delete(context, star.identity);
        }
      },
    },

    // One `(Model, op)` pair, two acts: the name is the whole of the
    // difference, and each resolver accepts only what its act means.
    renameSpace: { v1: renameSpace, v2: renameSpace },

    deleteSpace: {
      v1: async (context, { space }) => {
        await models.space.delete(context, space.identity);
      },
    },

    // The seeding acts. A contract's fixture is written through the same one
    // door as anything else (CAP-444), so the families every wire scenario
    // stands on need acts of their own — one operation each, and no business
    // beyond the write they name.
    registerUser: {
      v1: async (context, { user }) => {
        await models.user.create(context, user.identity, user.data);
      },
    },

    createSpace: {
      v1: async (context, { space }) => {
        await models.space.create(context, space.identity, space.data);
      },
    },

    saveAccountState: {
      v1: async (context, { accountState }) => {
        await models.accountState.create(
          context,
          accountState.identity,
          accountState.data,
        );
      },
    },

    writeMoment: {
      v1: async (context, { moment }) => {
        await models.moment.create(context, moment.identity, moment.data);
        return conformanceSettlementForModel('Moment', moment.identity);
      },
    },

    discardMoment: {
      v1: async (context, { moment }) => {
        await models.moment.delete(context, moment.identity);
      },
    },

    recordSample: {
      v1: async (context, { sample }) => {
        await models.scalarSample.create(context, sample.identity, sample.data);
      },
    },

    reviseSample: {
      v1: async (context, { sample }) => {
        await models.scalarSample.update(
          context,
          sample.identity,
          sample.patch,
        );
      },
    },

    keepMoment: {
      v1: async (context, { star }) => {
        await models.star.create(context, star.identity, star.data);
      },
    },

    // The mixed act: its `note` slot is local and filtered out of the
    // contract, so this argument type carries the `moment` slot alone — the
    // server has no notion the note exists. Refusing the caption is what
    // lets a journey prove the note rolls back with the act.
    // The same Model a client also writes with `localSync.write`: nothing
    // about LocalNote says which, because a Model says nothing about
    // replication (CAP-488).
    publishNote: {
      v1: async (context, { note }) => {
        await models.localNote.create(context, note.identity, note.data);
        return conformanceSettlementForModel('LocalNote', note.identity);
      },
    },

    captionWithNote: {
      v1: async (context, { moment }) => {
        if (moment.patch.caption === rejectedTagLabel) {
          throw new ConformanceRefusal('caption_with_note.not_allowed');
        }
        await models.moment.update(context, moment.identity, moment.patch);
      },
    },

    recaptionWithNote: {
      v1: async (context, { moment }) => {
        if (moment.patch.caption === rejectedTagLabel) {
          throw new ConformanceRefusal('recaption_with_note.not_allowed');
        }
        await models.moment.update(context, moment.identity, moment.patch);
      },
    },

    unstar: {
      v1: async (context, { star }) => {
        await models.star.delete(context, star.identity);
      },
    },
  };
}

export const conformanceMutationContract = generatedMutations;
