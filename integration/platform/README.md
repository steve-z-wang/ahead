# Platform verification

macOS arm64 Node and Dart are exercised by the complete host gate. Simulator checks are separate because they require Xcode and a usable installed iOS runtime.

```sh
bash integration/platform/run_ios_simulator_smoke.sh
```

The current harness targets an installed iOS 18.x runtime and an iPhone 16 simulator. It builds `lfs-dart` as an arm64 simulator static library, force-links the native symbols into a Flutter app, and creates a disposable simulator. Dart uses `DynamicLibrary.process()` with no explicit library path. The harness checks direct writes, queued mutations, frozen bytes, close/reopen, and then a complete app terminate/relaunch. Each SDK step is bounded and writes a stage marker. The script deletes only the simulator it created.

## Observed on 2026-09-10

- Rust `aarch64-apple-ios-sim` static library build passed.
- Flutter analysis and simulator app build passed.
- The linked debug library exported `lfs_call` and `lfs_free`.
- Actual iOS FFI/SQLite/restart validation **did not pass**. A fresh iOS 18.5 simulator booted and the app installed, but launch produced no console output and no first Dart `main()` stage marker within the bounded wait. The observed failure is between CoreSimulator launch and the Dart entrypoint; this does not prove a native SDK defect or prove successful FFI loading.
- A separate iOS 26.5 disposable simulator stalled during first-boot migration. No iOS 26.5 runtime success is claimed.
- All disposable simulators were removed. The pre-existing user simulator was left untouched.
- Android SDK/emulator and physical-device validation are unavailable on this host. No Android support claim is made from the Rust source alone.

The [macOS/Linux CI run for code commit 92bf410](https://github.com/steve-z-wang/local-first-state/actions/runs/34555679980) passed the complete host gate, real Node/Dart/PostgreSQL HTTP end-to-end tests, optimized builds and native binding smoke on both fresh runners. This does not extend the result to iOS or Android. See the [implementation ledger](../../docs/implementation-progress.md) for the detailed coverage.
