import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { stdin, stdout } from "node:process";
import { GeneratedClient, httpTransport } from "./generated/client.ts";
const client = await GeneratedClient.open({
  path: resolve(process.env.OTTER_DATABASE ?? "example-client.sqlite"),
});
await client.subscribe("book:demo");
const transport = httpTransport({
  url: process.env.OTTER_URL ?? "http://127.0.0.1:4242",
  token: "demo-user",
});
const show = async () => console.log(await client.readEntry({ id: "entry-1" }));
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
        await client.edit({
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
