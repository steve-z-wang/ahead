# Scheduling

## 1. Introduction and Goals

Scheduling answers one question per lane: should the host run a cycle now, wait, or stay idle? Putting that decision in Rust keeps retry policy identical across languages; the host only supplies the clock, entropy, timers and the network call.

## 3. Context and Scope

Interface to Rust, per lane (`push` or `live`): events `start`, `stop`, `pause`, `resume`, `wake`, `success`, `failure`, and the query `next` → `idle` | `sync` | `wait {millis}` ([Bindings](../../../sdks/bindings.md), command `connection`). Interface to the application: `Client.connect(server, {onError, refreshAuth})` → `{pause, resume, wake, close}`.

## 5. Building Block View

The Rust `ConnectionDriver` holds six fields: running, paused, dirty, in flight, attempt count and the time the next attempt is due. `next` returns `sync` only when the lane is running, not paused, has nothing in flight and is dirty; `wait` while a retry is due in the future; `idle` otherwise. A successful completion clears the attempt count and leaves the lane clean; a failure marks it dirty and schedules the next attempt at 250 ms doubling per attempt, capped at 30 s, with ±20 % jitter from host entropy. `wake` marks the lane dirty without interrupting a cycle in flight.

The host loop in each SDK polls `next`, runs the lane's body when told to sync, reports the outcome, and otherwise sleeps until the timer fires or a wake arrives. An epoch counter makes a wake that lands while a decision is being made take effect instead of being lost.

Code: [client/connection.rs](../../../../../../crates/client/src/connection.rs); host loops in [client-js/connection.mts](../../../../../../packages/client-js/connection.mts) (`startConnection`) and [dart/connection.dart](../../../../../../packages/dart/lib/src/connection.dart) (`RuntimeConnection`).

## 6. Runtime View

`pause` aborts the lane's in-flight request, tells Rust to pause, waits for the running body to finish, and wakes the loop so it observes the paused state; a failure caused by the abort is reported as success so no backoff is scheduled. `resume` clears the pause and marks the lane dirty. `close` stops the loop, aborts requests and detaches; controls on a closed connection are no-ops, so a stale handle cannot affect a replacement.

On failure the host calls `onError`. If the failure was a 401 (an error with `status: 401` in TypeScript, `AuthenticationExpired` in Dart) and the application supplied `refreshAuth`, it is called before `failure` is reported; concurrent 401s on both lanes share one refresh.

## 10. Quality Requirements

- **Backoff is bounded and a wake never busy-loops or gets lost.** Evidence: unit tests in [client/connection.rs](../../../../../../crates/client/src/connection.rs); [connection.test.mjs](../../../../../../integration/bindings/client-js/connection.test.mjs) `wake arriving during idle decision cannot be lost`; [dart/test/connection_test.dart](../../../../../../packages/dart/test/connection_test.dart).
- **Close abandons a network call that never resolves and reports neither success nor failure; closed controls are inert.** Evidence: the remaining tests in those two files.
- **The two lanes have independent lifecycle and retry state.** Evidence: [bindings/common/tests/session.rs](../../../../../../bindings/common/tests/session.rs) `live_and_push_drivers_have_independent_lifecycle_and_retry_state`.
- **A failed auth refresh is retried on the next attempt.** Evidence: [live.test.mjs](../../../../../../integration/bindings/client-js/live.test.mjs) `client retries upgrade authentication and survives failed refresh`; the Dart equivalent in [live_test.dart](../../../../../../packages/dart/test/live_test.dart).

Tests read, not executed.
