import {
  type AuthenticatedPrincipal,
  type MutationSettlement,
  type ScopeAuthorizer,
} from 'local-sync-backend';
import type { InMemoryTx } from './in-memory-transactions';

export const conformanceUserId = '1c1a5f4e-2b3c-4d5e-8f90-a1b2c3d4e5f6';
export const conformanceSpaceId = 'f0e1d2c3-b4a5-4968-8778-695a4b3c2d1e';
export const conformanceDeniedBookId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
export const conformanceBookAId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
export const conformanceBookBId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
export const conformanceBookAMomentId = '11111111-1111-4111-8111-111111111111';
export const conformanceBookBNoteId = '22222222-2222-4222-8222-222222222222';

export const conformanceUserScope = `User:${conformanceUserId}`;
export const conformanceSpaceScope = `Space:${conformanceSpaceId}`;
export const conformanceDeniedBookScope = `Book:${conformanceDeniedBookId}`;
export const conformanceBookAScope = `Book:${conformanceBookAId}`;
export const conformanceBookBScope = `Book:${conformanceBookBId}`;

export const conformanceScopeAuthorizer: ScopeAuthorizer<InMemoryTx> = {
  async canRead(_context, scope): Promise<boolean> {
    return (
      scope === conformanceUserScope ||
      scope === conformanceSpaceScope ||
      scope === conformanceBookAScope ||
      scope === conformanceBookBScope
    );
  },
};

export function conformancePrincipalScope(
  _principal: AuthenticatedPrincipal,
): string {
  return conformanceUserScope;
}

// Keep one identity in one stream: scalar samples exercise the second scope;
// every other fixture Model preserves the original User-scoped scenarios.
export function conformanceScopesForModel(
  model: string,
  identity: Readonly<Record<string, unknown>>,
): readonly string[] {
  if (model === 'Moment' && identity.id === conformanceBookAMomentId) {
    return [conformanceBookAScope];
  }
  if (model === 'LocalNote' && identity.id === conformanceBookBNoteId) {
    return [conformanceBookBScope];
  }
  return model === 'ScalarSample'
    ? [conformanceSpaceScope]
    : [conformanceUserScope];
}

export function conformanceSettlementForModel(
  model: string,
  identity: Readonly<Record<string, unknown>>,
): MutationSettlement {
  return Object.freeze({ scope: conformanceScopesForModel(model, identity)[0]! });
}
