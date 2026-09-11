import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { stdin, stdout } from "node:process";
import { Client } from "../../packages/client-js/index.mts";
import { schema, GeneratedClient } from "./generated/generated.ts";
const client = await Client.open({
  path: resolve(process.env.LFS_DATABASE ?? "example-client.sqlite"),
  schema,
  owner: "demo-user",
});
const model = new GeneratedClient(client);
await client.subscribe("book:demo");
const transport = async (kind: string, body: string) => {
  const response = await fetch(
    `${process.env.LFS_URL ?? "http://127.0.0.1:4242"}/sync/${kind === "push" ? "mutations" : "pull"}`,
    {
      method: "POST",
      headers: {
        authorization: "Bearer demo-user",
        "content-type": "application/json",
      },
      body,
    },
  );
  if (!response.ok) throw Error(await response.text());
  return response.text();
};
const show = async () => console.log(await model.readEntry({ id: "entry-1" }));
const terminal = createInterface({ input: stdin, output: stdout });
console.log(
  "Commands: sync | edit TEXT | show | status | quit. Edits are local until sync.",
);
try {
  for (;;) {
    const line = await terminal.question("> ");
    try {
      if (line === "quit") break;
      if (line === "sync") {
        await client.sync(transport);
        await show();
      } else if (line.startsWith("edit ")) {
        await model.edit({
          entry: {
            identity: { id: "entry-1" },
            values: { text: line.slice(5) },
          },
        });
        await show();
      } else if (line === "show") await show();
      else if (line === "status") console.log(await client.status());
    } catch (error) {
      console.error(String(error));
    }
  }
} finally {
  terminal.close();
  await client.close();
}
