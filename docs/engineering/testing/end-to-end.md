# End-to-end tests

Verify complete application paths through a generated client, the real backend, PostgreSQL and local SQLite. Use a small number of representative flows that can detect missing wiring or incompatible assumptions between components.

Existing entry point: [round-trip.test.mjs](../../../integration/e2e/round-trip.test.mjs), with TypeScript and Dart clients. It includes local visibility, server responses and live reconnect behavior.

After installing the prerequisites in [Running tests](running.md):

```sh
bash integration/e2e/run.sh
```

The runner builds native artifacts, generates the example APIs and starts a temporary PostgreSQL cluster. Assert user-visible state through the client, including rejected writes and resumed sync.

Next review: identify which full paths need a release gate and which cases are better isolated in component or integration tests. Device startup is separately exercised by [platform smoke tests](../../../integration/platform/README.md).
