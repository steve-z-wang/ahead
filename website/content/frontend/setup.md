# Set up the client

Read, watch and update local data through the generated client. TypeScript and Flutter share the same model and mutation contract, backed by the Rust engine and SQLite. Select a language above each example; Flutter examples use Dart.

Examples use the `Entry` model and `Edit` mutation from [getting started](../getting-started.md). [Generate your interfaces](../schema/define.md) before importing them.

## Set up the runtime

Packages are currently used from source. Build the native artifacts from the repository root:

```sh
bash scripts/build.sh
```

=== "TypeScript"

    The TypeScript client currently runs on Node.js 22.18 or newer. Build the native addon before importing generated code. The source package is `packages/client-js`; the example's generated `client.ts` already imports it through a relative path.

    Generate with `--client-runtime` pointing to that source package, relative to your generated directory. See the [schema guide](../schema/define.md#generate-from-a-source-checkout) for the working command.

=== "Flutter"

    Flutter uses the Dart client package. Add a local dependency to your application's `pubspec.yaml`, adjusting the path to your checkout:

    ```yaml
    dependencies:
      ahead:
        path: /absolute/path/to/ahead/packages/dart
    ```

    Run `flutter pub get`, or `dart pub get` in a Dart application. The package currently requires Dart 3.12 or newer. Generated code imports `package:ahead/ahead.dart`.

    For desktop development, `libraryPath` points to `target/debug/libahead_dart.dylib` on macOS or `libahead_dart.so` on Linux. Outside iOS it is required; on iOS, omitting it uses process-linked native symbols. Mobile packaging needs platform-specific native build/link steps; see [platform setup](platforms.md). Choose a writable application directory for the SQLite file.

## Open local storage

=== "TypeScript"

    ```ts
    import { GeneratedClient } from './generated/client.ts';

    const client = await GeneratedClient.open({ path: 'local.sqlite' });
    const entry = await client.models.entry.get({ id: 'entry-1' });
    console.log(entry?.text);
    ```

=== "Flutter"

    ```dart
    import 'generated/generated.dart';

    final client = await GeneratedClient.open(
      path: 'local.sqlite',
      libraryPath: '/absolute/path/to/ahead/target/debug/libahead_dart.dylib',
    );
    final entry = await client.models.entry.get(const EntryIdentity(id: 'entry-1'));
    print(entry?.text);
    ```

These examples open local storage without a connection. A fresh database returns null until you write local data or synchronize a channel. Use one active client per SQLite file and a separate file per signed-in user.

## Connect to your backend

Start the [tutorial backend](../getting-started.md), then open a client with a transport:

=== "TypeScript"

    ```ts
    import { GeneratedClient, httpTransport } from './generated/client.ts';

    const client = await GeneratedClient.open({
      path: 'local.sqlite',
      transport: httpTransport({
        url: 'http://127.0.0.1:4242',
        token: 'demo-user',
      }),
      connection: { onError: console.error },
    });
    await client.channels.subscribe('book:demo');
    ```

=== "Flutter"

    ```dart
    import 'dart:convert';
    import 'dart:io';
    import 'package:ahead/ahead.dart';
    import 'generated/generated.dart';

    final http = HttpClient();
    Future<String> transport(String kind, String body) async {
      final route = kind == 'push' ? 'mutations' : 'pull';
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:4242/sync/$route'),
      );
      request.headers.set('authorization', 'Bearer demo-user');
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode == 401) throw AuthenticationExpired();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Sync failed: HTTP ${response.statusCode}');
      }
      return text;
    }

    final client = await GeneratedClient.open(
      path: 'local.sqlite',
      libraryPath: '/absolute/path/to/ahead/target/debug/libahead_dart.dylib',
      transport: transport,
      onError: (error) => print(error),
    );
    await client.channels.subscribe('book:demo');
    ```

The transport forwards the supplied JSON unchanged. Replace the demo URL and token with your application's endpoint and credentials. On a physical device, localhost refers to that device; use a reachable development-server address.

TypeScript includes `httpTransport`; Flutter supplies the Dart transport function shown above. For expiring credentials, use `refreshAuth` and read the current token on each request. [Transport contracts](runtime.md#transports) explain error handling.

Subscribing wakes background sync but does not wait for initial data. The current clients use HTTP. Built-in client WebSocket integration is tracked in [issue #35](https://github.com/zanminwang/ahead/issues/35).

## Watch and write

=== "TypeScript"

    ```ts
    const stop = client.models.entry.watch({}, entries => console.log(entries), console.error);

    // After entry-1 has arrived locally:
    await client.transaction(tx => tx.mutate.edit({
      entry: { identity: { id: 'entry-1' }, values: { text: 'Draft', note: null } },
    }));
    ```

=== "Flutter"

    ```dart
    final subscription = client.models.entry.watch().listen(
      (entries) => print(entries),
      onError: (Object error) => print(error),
    );

    // After entry-1 has arrived locally:
    await client.transaction((tx) async {
      await tx.mutate.edit(
        entry: const EditEntryUpdate(
          identity: EntryIdentity(id: 'entry-1'),
          text: Present('Draft'),
          note: Present(null),
        ),
      );
    });
    ```

Watch emits an initial local result and distinct committed results. A mutation applies locally and queues the backend operation. Its return value is a local ordinal, not server confirmation. Direct writes through `tx.models` only change local storage.

In Flutter, use the watch stream with `StreamBuilder<List<Entry>>`; retain it for the view's lifetime rather than reopening a client on every build. Dart's `Present(null)` clears a nullable field; omitting the field leaves it unchanged.

## Connection and cleanup

=== "TypeScript"

    ```ts
    await client.connection!.pause();
    // Local reads and writes remain available.
    await client.connection!.resume();

    // When the owning view/application finishes:
    stop();
    await client.close();
    ```

=== "Flutter"

    ```dart
    await client.connection!.pause();
    // Local reads and writes remain available.
    await client.connection!.resume();

    // When the owner of this client finishes:
    await subscription.cancel();
    await client.close();
    http.close(force: true);
    ```

These connection calls assume you supplied a transport at open. Database/client lifetime belongs to the application; subscriptions belong to their views. Close your own HTTP client after closing Ahead.

See [Client API](client-api.md) for typed calls, [offline work and sync](sync.md) for connection/recovery behavior, and [advanced client APIs](runtime.md) for SQL, savepoints and prerequisites.
