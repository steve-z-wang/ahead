import { createBackend, devAuth, type Handlers, type Loaders } from "./backend.ts";
type Tx = { rows: Map<string, object> };
export const handlers: Handlers<Tx> = {
  async createEntry({ input, notify }) { notify({ channel: "c", records: [input.entry] }); },
  editEntry: {
    async v1({ input, notify }) { notify({ channel: "c", records: [input.target] }); },
    async v2({ input, notify }) { notify({ channel: "c", records: [input.entry] }); },
  },
  async removeEntries({ input, notify }) { notify({ channel: "c", records: input.entries }); },
  async addBook({ input, notify }) { notify({ channel: "c", records: [input.book] }); },
  async addComment({ input, notify }) { notify({ channel: "c", records: [input.comment] }); },
};
export const loaders: Loaders<Tx> = {
  async entry({ ids }) { return ids.map(() => null); },
  async book({ ids }) { return ids.map(() => null); },
  async comment({ ids }) { return ids.map(() => null); },
  async counter({ ids }) { return ids.map(() => null); },
};
export const backend = createBackend<Tx>({
  database: { transaction: async (body) => body({ rows: new Map() }), persistence: () => ({ call: async () => null }) },
  authenticate: devAuth(),
  handlers,
  loaders,
  native: { validateConfig() {}, processPush: async () => "", processPull: async () => "", publish: async () => "", negotiateLive: async () => "", pullLive: async () => "", liveEvent: () => "[]", liveClose() {} },
});
