import type {
  Acknowledged,
  Claimed,
  Head,
  HostRequest,
  Invalidation,
  Published,
  Stamped,
} from "../server/host-contract.mts";

/** A capability over the caller's Prisma interactive transaction, never an owned connection. */
export interface PrismaTransaction {
  $queryRawUnsafe<T = unknown>(sql: string, ...values: any[]): Promise<T>;
  $executeRawUnsafe(sql: string, ...values: any[]): Promise<number>;
}
const safe = (n: unknown): number => {
  const number = Number(n);
  if (!Number.isSafeInteger(number) || number < 0)
    throw new Error("Stored counter outside safe range");
  return number;
};
export class PrismaPersistence {
  readonly transaction: PrismaTransaction | undefined;
  constructor(transaction?: PrismaTransaction) {
    this.transaction = transaction;
  }
  bind(transaction: PrismaTransaction): PrismaPersistence {
    return new PrismaPersistence(transaction);
  }
  /** `Persistence.call` keeps its untyped signature; the contract is applied here. */
  call(request: Record<string, any>): Promise<unknown> {
    return this.answer(request as HostRequest);
  }
  private async answer(r: HostRequest): Promise<unknown> {
    const tx = this.transaction;
    if (!tx)
      throw new Error("PrismaPersistence must be bound to a transaction");
    switch (r.op) {
      case "claim": {
        await tx.$executeRawUnsafe(
          "INSERT INTO ahead_client (client_id, owner_id) VALUES ($1,$2) ON CONFLICT (client_id) DO NOTHING",
          r.clientId,
          r.owner,
        );
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT client_id, owner_id, sequence, receipt FROM ahead_client WHERE client_id=$1 FOR UPDATE",
          r.clientId,
        );
        if (rows.length !== 1) throw new Error("Failed to lock client");
        const row = rows[0];
        const claimed: Claimed = {
          clientId: row.client_id,
          owner: row.owner_id,
          sequence: safe(row.sequence),
          receipt: row.receipt,
        };
        return claimed;
      }
      case "saveReceipt": {
        const count = await tx.$executeRawUnsafe(
          "UPDATE ahead_client SET sequence=$3, receipt=$4 WHERE client_id=$1 AND owner_id=$2",
          r.clientId,
          r.owner,
          BigInt(r.sequence),
          r.receipt,
        );
        if (count !== 1) throw new Error("Receipt owner mismatch");
        const acknowledged: Acknowledged = null;
        return acknowledged;
      }
      case "head": {
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT head FROM ahead_channel WHERE channel=$1",
          r.channel,
        );
        const head: Head = rows.length ? safe(rows[0].head) : 0;
        return head;
      }
      case "scan": {
        // The invalidation keeps its own cursor (delivery progress); the stamp
        // is the record's current one, read in this same snapshot the loader
        // reads. A record with no metadata is a storage defect: the join is
        // kept outer so that it is reported, never dropped as a missing row.
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT i.channel, i.cursor, i.model, i.identity_key, i.identity, r.stamp FROM ahead_invalidation i LEFT JOIN ahead_record r ON r.model=i.model AND r.identity_key=i.identity_key WHERE i.channel=$1 AND i.cursor>$2 ORDER BY i.cursor LIMIT $3",
          r.channel,
          BigInt(r.after),
          r.limit,
        );
        const scanned: Invalidation[] = rows.map((row) => {
          if (row.stamp === null || row.stamp === undefined)
            throw new Error(
              `Record metadata missing for ${row.model} ${row.identity_key} on channel ${row.channel}`,
            );
          return {
            channel: row.channel,
            cursor: safe(row.cursor),
            model: row.model,
            identityKey: row.identity_key,
            identity: row.identity,
            stamp: safe(row.stamp),
          };
        });
        return scanned;
      }
      case "advanceStamp": {
        // The record row is locked by the upsert, so concurrent changes of one
        // record serialise here and never allocate the same stamp.
        const rows = await tx.$queryRawUnsafe<any[]>(
          "INSERT INTO ahead_record(model,identity_key,stamp) VALUES($1,$2,1) ON CONFLICT(model,identity_key) DO UPDATE SET stamp=ahead_record.stamp+1 RETURNING stamp",
          r.model,
          r.identityKey,
        );
        const stamped: Stamped = safe(rows[0].stamp);
        return stamped;
      }
      case "ensureStamp": {
        // Initialise at 1 only when the record has no stamp; an existing one
        // is kept as it is. The no-op update (rather than DO NOTHING plus a
        // SELECT) makes the row visible to this statement even under
        // REPEATABLE READ when another transaction initialised it after our
        // snapshot: that case surfaces as a serialization failure the runner
        // retries, instead of a SELECT that cannot see the committed row.
        const rows = await tx.$queryRawUnsafe<any[]>(
          "INSERT INTO ahead_record(model,identity_key,stamp) VALUES($1,$2,1) ON CONFLICT(model,identity_key) DO UPDATE SET stamp=ahead_record.stamp RETURNING stamp",
          r.model,
          r.identityKey,
        );
        const stamped: Stamped = safe(rows[0].stamp);
        return stamped;
      }
      case "publish": {
        // Distribution allocates only the channel cursor. The record row is
        // locked and must carry the stamp the request names: a stale one is
        // a defect of the caller's ordering, never silently re-stamped.
        const locked = await tx.$queryRawUnsafe<any[]>(
          "SELECT stamp FROM ahead_record WHERE model=$1 AND identity_key=$2 FOR UPDATE",
          r.model,
          r.identityKey,
        );
        if (locked.length !== 1)
          throw new Error(
            `Record metadata missing for ${r.model} ${r.identityKey}: publish needs its stamp first`,
          );
        const stamp = safe(locked[0].stamp);
        if (stamp !== r.stamp)
          throw new Error(
            `Publication names stamp ${r.stamp} but ${r.model} ${r.identityKey} is at stamp ${stamp}`,
          );
        const rows = await tx.$queryRawUnsafe<any[]>(
          "INSERT INTO ahead_channel(channel,head) VALUES($1,1) ON CONFLICT(channel) DO UPDATE SET head=ahead_channel.head+1 RETURNING head",
          r.channel,
        );
        const cursor = safe(rows[0].head);
        await tx.$executeRawUnsafe(
          "INSERT INTO ahead_invalidation(channel,model,identity_key,identity,cursor,stamp) VALUES($1,$2,$3,$4::jsonb,$5,$6) ON CONFLICT(channel,model,identity_key) DO UPDATE SET identity=EXCLUDED.identity,cursor=EXCLUDED.cursor,stamp=EXCLUDED.stamp",
          r.channel,
          r.model,
          r.identityKey,
          JSON.stringify(r.identity),
          BigInt(cursor),
          BigInt(stamp),
        );
        const published: Published = { cursor, stamp };
        return published;
      }
      case "savepoint":
      case "rollback":
      case "release": {
        if (!Number.isSafeInteger(r.ordinal) || r.ordinal < 1)
          throw new Error("Invalid savepoint ordinal");
        const name = `ahead_mutation_${r.ordinal}`;
        const command =
          r.op === "savepoint"
            ? "SAVEPOINT"
            : r.op === "rollback"
              ? "ROLLBACK TO SAVEPOINT"
              : "RELEASE SAVEPOINT";
        await tx.$executeRawUnsafe(`${command} ${name}`);
        const acknowledged: Acknowledged = null;
        return acknowledged;
      }
      // `handle` and `load` reach application code, never persistence. An
      // operation added to the contract without an arm here is a compile error.
      case "handle":
      case "load":
        break;
      default: {
        const unreachable: never = r;
        void unreachable;
      }
    }
    throw new Error(
      `Unsupported persistence operation ${(r as { op: string }).op}`,
    );
  }
}

/** Coherent transaction snapshots with bounded PostgreSQL serialization retries. */
export function prismaTransactions<T extends PrismaTransaction>(
  client: {
    $transaction<R>(
      body: (tx: T) => Promise<R>,
      options: { isolationLevel: "RepeatableRead"; timeout: number },
    ): Promise<R>;
  },
  options: { retries?: number; timeout?: number } = {},
) {
  return async <R,>(body: (tx: T) => Promise<R>): Promise<R> => {
    for (let attempt = 0; ; attempt++) {
      try {
        return await client.$transaction(body, {
          isolationLevel: "RepeatableRead",
          timeout: options.timeout ?? 20000,
        });
      } catch (error) {
        const e = error as { code?: string; meta?: { code?: string } };
        const serialization =
          e.code === "P2034" ||
          (e.code === "P2010" &&
            (e.meta?.code === "40001" || e.meta?.code === "40P01"));
        if (!serialization || attempt >= (options.retries ?? 3)) throw error;
      }
    }
  };
}

/** Bundle the transaction runner and the persistence factory for `createBackend({ database })`. */
export function prisma<T extends PrismaTransaction>(
  client: Parameters<typeof prismaTransactions<T>>[0],
  options: { retries?: number; timeout?: number } = {},
) {
  return {
    transaction: prismaTransactions<T>(client, options),
    persistence: (tx: T) => new PrismaPersistence(tx),
  };
}
