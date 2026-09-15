# End-to-end tests

Verify complete application paths through a generated client, the real backend, PostgreSQL and local SQLite. Use a small number of representative flows that can detect missing wiring or incompatible assumptions between components.

Existing entry points: [round-trip.test.mjs](../../../integration/e2e/round-trip.test.mjs), with TypeScript and Dart clients, covering local visibility, server responses and live reconnect behavior; and [parity.test.mjs](../../../integration/e2e/parity.test.mjs), which runs one script through the Node client and the Dart client ([parity_client.dart](../../../integration/e2e/parity_client.dart)) against the same server and requires identical local state.

After installing the prerequisites in [Running tests](running.md):

```sh
bash integration/e2e/run.sh
```

The runner builds native artifacts, generates the example APIs and starts a temporary PostgreSQL cluster. Assert user-visible state through the client, including rejected writes and resumed sync.

Next review: identify which full paths need a release gate and which cases are better isolated in component or integration tests. Extend the parity script only when a runtime-specific behavior (value conversion, error surfacing, session logic) is at stake; engine rules belong in the Rust suites. Device startup is separately exercised by [platform smoke tests](../../../integration/platform/README.md).

## Coverage review

Reviewed 2026-09-14; tests read, not executed. The suite runs a real backend over a temporary PostgreSQL cluster with the Node client, the Dart client and the example CLI.

| Path | Test | What it establishes | Limits |
| --- | --- | --- | --- |
| Node client → HTTP → Rust backend → Prisma → SQLite, then Dart against the same server | [round-trip.test.mjs](../../../integration/e2e/round-trip.test.mjs) first test | initial sync, offline edit visible before sync, frozen batch across restart, lost receipt converges without re-executing, rejection reported, local writes not blocked by an in-flight push, background connection with pause and resume, Dart write settles | The Node part drives the wire through the internal `syncProtocol` fixture for the first half and `connect` for the second; the Dart part writes a different record, so identical outcomes are not compared. |
| Documented CLI example | second test | offline edit stays local, syncs when online, normalized value comes back | Depends on the example's console output strings. |
| Built-in live sync in both languages | third test with [dart_live_client.dart](../../../integration/e2e/dart_live_client.dart) | multi-page catch-up (56 records), a commit during a held catch-up is not missed, watch fires, dependent pushes settle from streamed pages without polling, offline reconnect resumes from the persisted cursor, Dart repeats the flow including unsubscribe and resubscribe | Timing assertions use polling with fixed timeouts; a slow host can produce false failures rather than false passes. |
| One script, two runtimes: catch-up, an accepted edit, a rejected edit, a direct local create | [parity.test.mjs](../../../integration/e2e/parity.test.mjs) with [parity_client.dart](../../../integration/e2e/parity_client.dart) | before each runtime the server is reseeded (entry-1 back to its initial text, published on the channel), so both start from the same authoritative state; each runtime records the value it saw after catch-up and after the accepted edit, and those are asserted per runtime (seeded value, then the server-normalized `parity`) before the rejected edit; then the Node and Dart dumps (records, pending, before images, channels, rejections, per-record status of the edited and the local-only record) must be deep-equal, and the final outcomes are checked against the script | Cursors and client ids are excluded because two clients legitimately differ there. Both runtimes use one backend and one PostgreSQL database with a reseed between runs, not two isolated databases. Checked once by hand: a Dart run that kept the old authoritative text after settling fails the parity comparison. The Rust engine is shared, so this proves the host-side session logic and value handling agree, not the engine twice; a Rust-native third runner is not built. Verified 2026-09-14 by `bash integration/e2e/run.sh`. |
| iOS device startup | [platform smoke](../../../integration/platform/run_ios_simulator_smoke.sh) | the native library loads and the app starts on a simulator | Manual, outside the host gate. |

The suite is the only place the real TypeScript backend, the real PostgreSQL adapter and a real generated client meet. It should stay small; each of its assertions is also covered at a lower level except the wiring itself and the `backend.notify(tx, …)` shortcut used by the example server, which relies on catch-up rather than a wake ([Notify §11](../architecture/server/engine/notify.md)).
