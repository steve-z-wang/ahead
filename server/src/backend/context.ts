export interface BackendWriteContext<TTx> {
  readonly transaction: TTx;
  readonly actorUserId: string;
}

export interface BackendReadContext<TTx> {
  readonly transaction: TTx;
  readonly viewerUserId: string;
  /** The exact ledger being materialized; loaders keep rows scope-aligned. */
  readonly scope: string;
}

export interface AuthenticatedPrincipal {
  readonly userId: string;
}

export interface ScopeAuthorizer<TTx> {
  canRead(
    context: { readonly transaction: TTx; readonly viewerUserId: string },
    scope: string,
  ): Promise<boolean>;
}

export interface PrincipalCall {
  readonly principal: AuthenticatedPrincipal;
  readonly requestBytes: Uint8Array;
}

export type PrincipalUpload = PrincipalCall;
export type PrincipalPull = PrincipalCall;
export type PrincipalSubscription = PrincipalCall;
