import type { Handlers } from "./backend.ts";
type Tx = { rows: Map<string, object> };
export const handlers: Handlers<Tx> = {
  async createEntry({ input, notify }) { notify({ channel: "c", records: [input.entry] }); },
  editEntry: {
    async v1({ input, notify }) { notify({ channel: "c", records: [input.target] }); },
    async v2({ input, notify }) { notify({ channel: "c", records: [input.entry] }); },
  },
  async removeEntries({ input, notify }) { notify({ channel: "c", records: input.entries }); },
  async addBook({ input, notify }) { notify({ channel: "c", records: [input.book] }); },
};
