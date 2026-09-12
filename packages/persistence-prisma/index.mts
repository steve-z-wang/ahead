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
  async call(r: Record<string, any>): Promise<unknown> {
    const tx = this.transaction;
    if (!tx)
      throw new Error("PrismaPersistence must be bound to a transaction");
    switch (r.op) {
      case "claim": {
        await tx.$executeRawUnsafe(
          "INSERT INTO otter_client (client_id, owner_id) VALUES ($1,$2) ON CONFLICT (client_id) DO NOTHING",
          r.clientId,
          r.owner,
        );
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT client_id, owner_id, sequence, request_hash, receipt FROM otter_client WHERE client_id=$1 FOR UPDATE",
          r.clientId,
        );
        if (rows.length !== 1) throw new Error("Failed to lock client");
        const row = rows[0];
        return {
          clientId: row.client_id,
          owner: row.owner_id,
          sequence: safe(row.sequence),
          hash: row.request_hash,
          receipt: row.receipt,
        };
      }
      case "saveReceipt": {
        const count = await tx.$executeRawUnsafe(
          "UPDATE otter_client SET sequence=$3, request_hash=$4, receipt=$5 WHERE client_id=$1 AND owner_id=$2",
          r.clientId,
          r.owner,
          BigInt(r.sequence),
          r.hash,
          r.receipt,
        );
        if (count !== 1) throw new Error("Receipt owner mismatch");
        return null;
      }
      case "head": {
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT head FROM otter_channel WHERE channel=$1",
          r.channel,
        );
        return rows.length ? safe(rows[0].head) : 0;
      }
      case "scan": {
        const rows = await tx.$queryRawUnsafe<any[]>(
          "SELECT channel, cursor, model, identity_key, identity FROM otter_invalidation WHERE channel=$1 AND cursor>$2 ORDER BY cursor LIMIT $3",
          r.channel,
          BigInt(r.after),
          r.limit,
        );
        return rows.map((row) => ({
          channel: row.channel,
          cursor: safe(row.cursor),
          model: row.model,
          identityKey: row.identity_key,
          identity: row.identity,
        }));
      }
      case "publish": {
        const rows = await tx.$queryRawUnsafe<any[]>(
          "INSERT INTO otter_channel(channel,head) VALUES($1,1) ON CONFLICT(channel) DO UPDATE SET head=otter_channel.head+1 RETURNING head",
          r.channel,
        );
        const cursor = safe(rows[0].head);
        await tx.$executeRawUnsafe(
          "INSERT INTO otter_invalidation(channel,model,identity_key,identity,cursor) VALUES($1,$2,$3,$4::jsonb,$5) ON CONFLICT(channel,model,identity_key) DO UPDATE SET identity=EXCLUDED.identity,cursor=EXCLUDED.cursor",
          r.channel,
          r.model,
          r.identityKey,
          JSON.stringify(r.identity),
          BigInt(cursor),
        );
        return cursor;
      }
      case "savepoint":
      case "rollback":
      case "release": {
        if (!Number.isSafeInteger(r.ordinal) || r.ordinal < 1)
          throw new Error("Invalid savepoint ordinal");
        const name = `otter_mutation_${r.ordinal}`;
        const command =
          r.op === "savepoint"
            ? "SAVEPOINT"
            : r.op === "rollback"
              ? "ROLLBACK TO SAVEPOINT"
              : "RELEASE SAVEPOINT";
        await tx.$executeRawUnsafe(`${command} ${name}`);
        return null;
      }
      default:
        throw new Error(`Unsupported persistence operation ${r.op}`);
    }
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
