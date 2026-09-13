import { PrismaClient, type Prisma } from "@prisma/client";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import {
  createBackend,
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
    handlers: {
      async edit({ input, tx, notify }) {
        calls++;
        const { identity, patch } = input.entry;
        if (patch.text === "reject") throw new MutationRejected("entry.denied");
        await tx.entry.update({
          where: identity,
          data: {
            ...patch,
            ...(typeof patch.text === "string"
              ? { text: patch.text.trim() }
              : {}),
          },
        });
        notify({ channel: "book:demo", records: [input.entry] });
      },
    },
    loaders: {
      async entry({ ids, tx }) {
        return Promise.all(
          ids.map((identity) => tx.entry.findUnique({ where: identity })),
        );
      },
    },
  });
  let server: Awaited<ReturnType<typeof backend.listen>> | undefined;
  return {
    db,
    backend,
    async listen(port: number) {
      server = await backend.listen({ port });
      return server;
    },
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
        await backend.notify(tx, {
          channel: "book:demo",
          records: [{ model: "Entry", identity: { id: "entry-1" } }],
        });
      });
    },
    async close() {
      if (server) await server.close();
      await db.$disconnect();
    },
  };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const app = await createExample();
  await app.initialize();
  const port = Number(process.env.PORT ?? 4242);
  const started = await app.listen(port);
  console.log(`Example listening at ${started.url}`);
  for (const signal of ["SIGINT", "SIGTERM"] as const)
    process.once(signal, () => void app.close());
}
