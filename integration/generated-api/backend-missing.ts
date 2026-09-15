import type { Handlers } from "./backend.ts";
type Tx = { rows: Map<string, object> };
export const handlers: Handlers<Tx> = {
  async createEntry({ publish }) { publish({ channel: "c" }); },
  editEntry: {
    async v1({ publish }) { publish({ channel: "c" }); },
    async v2({ input, publish }) { publish({ channel: "c", records: [input.entry] }); },
  },
  async removeEntries({ publish }) { publish({ channel: "c" }); },
  async addBook({ publish }) { publish({ channel: "c" }); },
};
