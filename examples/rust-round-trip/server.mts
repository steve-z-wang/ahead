import { PrismaClient, type Prisma } from "@prisma/client";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import {
  createBackend,
  createHttpHandler,
  attachLive,
  devAuth,
  MutationRejected,
} from "../../packages/server/index.mts";
import { prisma } from "../../packages/persistence-prisma/index.mts";
export async function createExample() {
  const db = new PrismaClient();
  const generated = JSON.parse(
    await readFile(
      new URL("./generated/backend.json", import.meta.url),
      "utf8",
    ),
  );
  const schema = generated.schema;
  const config = generated;
  let calls = 0;
  const backend = createBackend<Prisma.TransactionClient>({
    config,
    database: prisma<Prisma.TransactionClient>(db),
    authenticate: devAuth(),
    principalChannel: () => "book:demo",
    authorize: async (c) => c.channel === "book:demo",
    handlers: {
      Edit: {
        1: async (ctx, args) => {
          calls++;
          const { identity, patch } = args.entry;
          if (patch.text === "reject")
            throw new MutationRejected("entry.denied");
          await ctx.transaction.entry.update({
            where: identity,
            data: {
              ...patch,
              ...(typeof patch.text === "string"
                ? { text: patch.text.trim() }
                : {}),
            },
          });
          await ctx.publish([{ model: "Entry", identity }], ["book:demo"]);
          return { channel: "book:demo" };
        },
      },
    },
    loaders: {
      Entry: {
        load: async (ctx, identities) =>
          Promise.all(
            identities.map((identity) =>
              ctx.transaction.entry.findUnique({ where: identity }),
            ),
          ),
      },
    },
  });
  const authenticate = async (req: any) =>
    req.headers.authorization === "Bearer demo-user" ? "demo-user" : null;
  const http = createServer(createHttpHandler({ backend, authenticate }));
  const closeLive = attachLive(http, { backend, authenticate });
  return {
    db,
    backend,
    http,
    schema,
    get handlerCalls() {
      return calls;
    },
    async initialize() {
      for (const sql of (
        await readFile(
          new URL(
            "../../packages/persistence-prisma/migration.sql",
            import.meta.url,
          ),
          "utf8",
        )
      )
        .split(";")
        .map((s) => s.trim())
        .filter(Boolean))
        await db.$executeRawUnsafe(sql);
      await db.$executeRawUnsafe(
        'CREATE TABLE IF NOT EXISTS "Entry" (id TEXT PRIMARY KEY,text TEXT NOT NULL,note TEXT)',
      );
      await db.$transaction(async (tx) => {
        await tx.entry.upsert({
          where: { id: "entry-1" },
          create: { id: "entry-1", text: "Hello from the server" },
          update: {},
        });
        await backend.publish(
          tx,
          [{ model: "Entry", identity: { id: "entry-1" } }],
          ["book:demo"],
        );
      });
    },
    async close() {
      await closeLive.close();
      if (http.listening)
        await new Promise<void>((resolve, reject) =>
          http.close((error) => (error ? reject(error) : resolve())),
        );
      await db.$disconnect();
    },
  };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = await createExample();
  await app.initialize();
  const port = Number(process.env.PORT ?? 4242);
  app.http.listen(port, "127.0.0.1", () =>
    console.log(`Example listening at http://127.0.0.1:${port}`),
  );
  for (const signal of ["SIGINT", "SIGTERM"] as const)
    process.once(signal, () => void app.close());
}
