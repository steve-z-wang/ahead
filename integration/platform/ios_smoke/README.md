# iOS SDK smoke app

This internal Flutter harness tests the local-first-state Dart facade against process-linked Rust and SQLite. Run it through `../run_ios_simulator_smoke.sh` from the repository root as documented in the [platform README](../README.md).

The first launch writes a local row, queues an optimistic edit, freezes it and verifies close/reopen. A second app launch compares the persisted row and exact frozen request. Stage/result files are written inside the app's temporary directory; each SDK step has a timeout. Temporary storage is sufficient for this controlled restart test, but applications should use an application-support database path for durable user data.

This is a test harness, not the public example or a claim of verified iOS runtime support. Current results and limitations are recorded in the parent README.
