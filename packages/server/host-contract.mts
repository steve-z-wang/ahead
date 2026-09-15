/**
 * The host operation contract, mirroring `crates/server/src/host.rs`.
 *
 * Hand-written: the two languages have no shared code generator today, so
 * `fixtures/protocol/host-operations.json` is what keeps them in step. A change
 * on either side belongs in the fixture too, and the round-trip tests
 * (`crates/server/tests/host_contract.rs`,
 * `integration/persistence/server/host-contract.test.mjs`) fail on a one-sided one.
 *
 * This types what exists today. It adds no failure result and changes no
 * transaction semantics; #95 may extend `handle`, `rollback` and `load` later.
 */

/** Lock this client's row and report its last accepted batch. */
export type ClaimRequest = { op: "claim"; owner: string; clientId: string };
/** Record the receipt for an accepted batch. */
export type SaveReceiptRequest = {
  op: "saveReceipt";
  owner: string;
  clientId: string;
  sequence: number;
  receipt: string;
};
/** The channel's current head cursor. */
export type HeadRequest = { op: "head"; channel: string };
/** Invalidation rows after `after`, at most `limit` of them, in cursor order. */
export type ScanRequest = {
  op: "scan";
  channel: string;
  after: number;
  limit: number;
};
/** Open the savepoint that isolates one mutation. */
export type SavepointRequest = { op: "savepoint"; ordinal: number };
/** Undo one mutation's effects back to its savepoint. */
export type RollbackRequest = { op: "rollback"; ordinal: number };
/** Discard one mutation's savepoint, keeping its effects. */
export type ReleaseRequest = { op: "release"; ordinal: number };
/** Run one mutation's handler. `arguments` carries the decoded slots verbatim. */
export type HandleRequest = {
  op: "handle";
  name: string;
  version: number;
  arguments: Record<string, unknown>;
  owner: string;
  ordinal: number;
};
/** Load the current state of these identities for this channel. */
export type LoadRequest = {
  op: "load";
  model: string;
  identities: Record<string, unknown>[];
  owner: string;
  channel: string;
};
/** Invalidate one record on one channel and allocate its cursor and stamp. */
export type PublishRequest = {
  op: "publish";
  channel: string;
  model: string;
  identity: Record<string, unknown>;
  identityKey: string;
};

export type HostRequest =
  | ClaimRequest
  | SaveReceiptRequest
  | HeadRequest
  | ScanRequest
  | SavepointRequest
  | RollbackRequest
  | ReleaseRequest
  | HandleRequest
  | LoadRequest
  | PublishRequest;

export type HostOperation = HostRequest["op"];

/** The subset a [Persistence] answers: everything that is not application code. */
export type PersistenceRequest = Exclude<
  HostRequest,
  HandleRequest | LoadRequest
>;

/** The answer to an operation whose only answer is "done". */
export type Acknowledged = null;
/** The answer to `claim`. */
export type Claimed = {
  clientId: string;
  owner: string;
  sequence: number;
  receipt: string | null;
};
/** The answer to `head`: a bare counter. */
export type Head = number;
/** One row of the answer to `scan`. */
export type Invalidation = {
  channel: string;
  cursor: number;
  model: string;
  identity: Record<string, unknown>;
  identityKey: string;
  stamp: number;
};
/** The answer to `publish`. */
export type Published = { cursor: number; stamp: number };
/** The answer to `handle`: a settlement channel or a rejection code, never both. */
export type Handled = { channel: string } | { rejection: string };
/** The answer to `load`: one entry per identity, `null` for a record the channel cannot see. */
export type Loaded = (Record<string, unknown> | null)[];

/** The answer each operation owes, keyed by `op`. */
export type HostResponse = {
  claim: Claimed;
  saveReceipt: Acknowledged;
  head: Head;
  scan: Invalidation[];
  savepoint: Acknowledged;
  rollback: Acknowledged;
  release: Acknowledged;
  handle: Handled;
  load: Loaded;
  publish: Published;
};

/**
 * Every operation, checked against the union in both directions: a missing key
 * and an extra one are both compile errors here.
 */
const OPERATIONS: Record<HostOperation, true> = {
  claim: true,
  saveReceipt: true,
  head: true,
  scan: true,
  savepoint: true,
  rollback: true,
  release: true,
  handle: true,
  load: true,
  publish: true,
};

export const HOST_OPERATIONS: readonly HostOperation[] = Object.keys(
  OPERATIONS,
) as HostOperation[];
