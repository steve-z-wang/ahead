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
