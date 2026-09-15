# End-to-end tests

Verify complete application paths through a generated client, the real backend, PostgreSQL and local SQLite. Use a small number of representative flows that can detect missing wiring or incompatible assumptions between components.

Existing entry point: [round-trip.test.mjs](../../../integration/e2e/round-trip.test.mjs), with TypeScript and Dart clients. It includes local visibility, server responses and live reconnect behavior.

After installing the prerequisites in [Running tests](running.md):

```sh
bash integration/e2e/run.sh
```

The runner builds native artifacts, generates the example APIs and starts a temporary PostgreSQL cluster. Assert user-visible state through the client, including rejected writes and resumed sync.

Device startup is separately exercised by [platform smoke tests](../../../integration/platform/README.md).

## Coverage review

Reviewed 2026-09-14; tests read, not executed. The suite runs a real backend over a temporary PostgreSQL cluster with the Node client, the Dart client and the example CLI.

| Path | Test | What it establishes | Limits |
| --- | --- | --- | --- |
| Node client → HTTP → Rust backend → Prisma → SQLite, then Dart against the same server | [round-trip.test.mjs](../../../integration/e2e/round-trip.test.mjs) first test | initial sync, offline edit visible before sync, frozen batch across restart, lost receipt converges without re-executing, rejection reported, local writes not blocked by an in-flight push, background connection with pause and resume, Dart write settles | The Node part drives the wire through the internal `syncProtocol` fixture for the first half and `connect` for the second; the Dart part writes a different record, so identical outcomes are not compared. |
| Documented CLI example | second test | offline edit stays local, syncs when online, normalized value comes back | Depends on the example's console output strings. |
| Built-in live sync in both languages | third test with [dart_live_client.dart](../../../integration/e2e/dart_live_client.dart) | multi-page catch-up (56 records), a commit during a held catch-up is not missed, watch fires, dependent pushes settle from streamed pages without polling, offline reconnect resumes from the persisted cursor, Dart repeats the flow including unsubscribe and resubscribe | Timing assertions use polling with fixed timeouts; a slow host can produce false failures rather than false passes. |
| iOS device startup | [platform smoke](../../../integration/platform/run_ios_simulator_smoke.sh) | the native library loads and the app starts on a simulator | Manual, outside the host gate. |

The suite is the only place the real TypeScript backend, the real PostgreSQL adapter and a real generated client meet. It should stay small; each of its assertions is also covered at a lower level except the wiring itself and the `backend.notify(tx, …)` shortcut used by the example server, which relies on catch-up rather than a wake ([#50](https://github.com/zanminwang/ahead/issues/50), [Notify §11](../architecture/server/engine/notify.md)).
