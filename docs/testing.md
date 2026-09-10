# Testing

Run `./tool/gate.sh` from the root, or call it by absolute path from another
working directory. It resolves all paths inside this repository.

The gate checks compiler and client formatting, analysis and unit tests;
installs and builds the TypeScript server; regenerates conformance bindings;
runs server unit tests, conformance analysis/build, the dispatcher checks, all
five contracts, and framework independence checks.

| Contract | What it proves |
|---|---|
| [model-generation](../conformance/model-generation/) | Generated declarations faithfully represent the schema |
| [server-client-protocol](../conformance/server-client-protocol/) | Real Dart/TypeScript HTTP and WebSocket agreement |
| [client-storage-contract](../conformance/client-storage-contract/) | Database adapter semantics |
| [server-persistence-contract](../conformance/server-persistence-contract/) | Server persistence port semantics |
| [end-to-end-sync](../conformance/end-to-end-sync/) | Whole sync promises read back from SQLite |

```bash
./conformance/tool/test.sh --list
./conformance/tool/test.sh model-generation
./conformance/tool/test.sh all
```

Each runner prepares its dependencies and generated fixtures when invoked alone.
The in-memory server adapter is a test fixture. A production persistence adapter
must pass the server persistence contract in the consuming application's suite.

Place an assertion beside a package when that package alone can prove it. Use
model-generation when generated declarations matter, protocol tests when the
answer is on the wire, and end-to-end tests when the answer is in client storage.
The example executes selected existing journeys and asserts their results; it
introduces no alternate synchronization implementation.
