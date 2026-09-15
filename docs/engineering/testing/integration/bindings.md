# SDK and binding tests

Verify that generated APIs and native calls preserve types, values, errors, callbacks and resource ownership. Link engine behavior to its existing tests; exercise it here when crossing the boundary introduces a distinct failure mode.

Existing entry points are [common binding tests](../../../../bindings/common/tests), [JavaScript tests](../../../../integration/bindings/client-js), [Dart tests](../../../../packages/dart/test) and [generated API fixtures](../../../../integration/generated-api).

After the prerequisites and native build in [Running tests](../running.md):

```sh
node --test integration/bindings/client-js/*.test.mjs
bash integration/generated-api/verify.sh
```

The generated API runner checks TypeScript positive and negative cases, analyzes Dart, and executes generated clients. Dart native tests also need the library-path environment described in the running guide.

Next review: negative type coverage per language, callback failures, native lifetimes and shared cross-language scenarios. A shared Rust engine alone does not establish SDK equivalence.

## Coverage review

Reviewed 2026-09-14; tests read, not executed, except where a row records a verified run. Verified 2026-09-14: `bash integration/persistence/transaction-probe/run.sh` passed (12 tests) over the probe build.

| Behavior | Existing tests | Coverage | Gap and next step |
| --- | --- | --- | --- |
| Command contract: session isolation, closed handles, transport actions, lanes, dispositions ([Bindings](../../architecture/sdks/bindings.md)) | [session.rs](../../../../bindings/common/tests/session.rs) | covered | The `transaction_closed` and `client transaction active` refusals are exercised implicitly; a direct assertion is cheap. |
| Transaction semantics across the boundary: unawaited calls, caught failures, overlapping and unawaited savepoints, late callbacks ([Typed API / Client](../../architecture/sdks/typed-api/client.md)) | [transaction.test.mjs](../../../../integration/bindings/client-js/transaction.test.mjs); Dart [client_test.dart](../../../../packages/dart/test/client_test.dart) `Dart callbacks read their writes, rollback and reopen through native Rust` | covered in both languages | The Dart test bundles rollback, forgotten call, duplicate create, savepoint confinement, late child, reopen and closed-handle into one test; a failure will not name the clause. Consider splitting when it is next touched. |
| Async host callbacks inside a Prisma transaction; rollback on Rust error, dispose, timeout, concurrent transactions | [transaction-bridge.test.mjs](../../../../integration/bindings/node/transaction-bridge.test.mjs) | covered for the probe build | These tests drive `runProbe` through the fixture [transaction-session.mjs](../../../../integration/bindings/node/transaction-session.mjs) over `ahead-node-probe.node`, built by `node bindings/node/build.mjs --probe` in [transaction-probe/run.sh](../../../../integration/persistence/transaction-probe/run.sh). The normal addon has no probe API. Unique to the probe: dispose during an awaited callback, transaction timeout, a synchronous callback throw, and a deferred-constraint commit failure. Already proven on the production path by [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs): rollback on a Rust or handler error (`unknown error rolls back entire batch…`), unawaited work (`pending unawaited publication prevents outer transaction commit`), caught failures (`external transaction binding retains swallowed publication failure…`), concurrent transactions (`repeatable-read runner keeps head, scan, and loader coherent…`). Do not cite the probe tests for `createBackend` behavior. |
| Generated TypeScript: positives run against native Rust, negatives fail to compile | [test.ts](../../../../integration/generated-api/test.ts), [native.mts](../../../../integration/generated-api/native.mts), [verify.sh](../../../../integration/generated-api/verify.sh) | covered | none |
| Generated Dart: positives run against native Rust; a failed open closes the isolate | [generated_test.dart](../../../../integration/generated-api/generated_test.dart), [failed_open.dart](../../../../integration/generated-api/failed_open.dart) | covered (positives) | No Dart negative-compilation fixture. |
| Dart requires `libraryPath` outside iOS; close is idempotent and waits for connect | [client_test.dart](../../../../packages/dart/test/client_test.dart) | covered | none |
| `runPrerequisites` in Dart | none | missing | The TypeScript runner is tested; add the Dart equivalent of [prerequisite.test.mjs](../../../../integration/bindings/client-js/prerequisite.test.mjs). |
| Identical state across Rust, TypeScript and Dart for one script | none; [fixtures/scenarios](../../../../fixtures/scenarios) are prose | missing | Decide whether a cross-language runner is worth building; the shared engine makes divergence unlikely but the session logic is duplicated per language ([Live session](../../architecture/client/connection/controller/live-session.md)). |
| Server errors cross as `{code, message, details?}`; classification never depends on wording ([Bindings](../../architecture/sdks/bindings.md)) | [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs) `push_refusals_carry_stable_codes_and_run_no_handler`, `malformed_requests_and_blank_owners_are_refused_with_codes`, `host_failures_keep_their_message_under_the_host_code`; [runtime.test.mjs](../../../../integration/persistence/server/runtime.test.mjs) `HTTP classifies native failures by code, not message wording; unknown codes fall back to 500` | covered | Client-direction errors remain messages by design (Bindings §11). |
