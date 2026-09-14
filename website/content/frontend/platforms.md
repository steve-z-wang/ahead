# Supported platforms

Savoia clients use the native Rust engine and SQLite. Building the application package and validating it on the target platform are separate steps.

| Platform | Available support |
| --- | --- |
| macOS and Linux | TypeScript on Node.js and Dart: native builds, SQLite and HTTP round-trip tests are verified |
| iOS | Flutter native linking/build setup is available; FFI, SQLite and app-restart runtime validation is not complete |
| Android | Runtime and device validation is not complete |
| Browser | Native client bindings do not provide browser/WASM support |
| Windows | Not verified |

## Desktop setup

Build the native libraries with `bash scripts/build.sh`. TypeScript uses the Node addon. Dart takes an explicit `libraryPath`: `target/debug/libsavoia_dart.dylib` on macOS or `target/debug/libsavoia_dart.so` on Linux. See [client setup](setup.md) for language-specific examples.

## Flutter native integration

On iOS, link the Rust static library into the application and retain the native symbols. Dart then uses `DynamicLibrary.process()` when `libraryPath` is omitted. A desktop dynamic library cannot be used as a mobile build artifact.

The repository includes a simulator integration harness. It requires Xcode and a usable installed iOS runtime:

```sh
bash integration/platform/run_ios_simulator_smoke.sh
```

The harness builds the native library and Flutter app, creates a disposable simulator, and checks local writes, queued mutations, close/reopen and app restart. It removes only the simulator it creates. Passing the build alone does not establish that all runtime checks pass.

## Verification

`bash scripts/test.sh` runs the macOS/Linux host checks with real SQLite, native bindings and a disposable PostgreSQL backend. Platform-specific simulator checks run separately. See [testing](../contributing/testing.md) for the full workflow.
