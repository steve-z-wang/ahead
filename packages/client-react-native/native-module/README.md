# `@ahead/native`

Reusable iOS Expo module for Ahead's Rust client carrier.

The Expo module is named `AheadNative` and exposes:

```ts
interface AheadNativeModule {
  clientCall(request: string): Promise<string>;
  databasePath(name: string): Promise<string>;
}
```

`clientCall` runs on a dedicated serial queue. It resolves with the serialized,
unwrapped `RuntimeHost` result and rejects carrier or runtime errors.
`databasePath` accepts one basename and returns a stable path in the app's
Application Support directory, creating that directory when needed.

The pod's prepare step builds the Apple Silicon simulator slice. Run
`bash scripts/build-ios.sh simulator` directly to rebuild it. The device slice
is configured with `bash scripts/build-ios.sh device`, but remains unverified
until it is built and exercised on a device.
