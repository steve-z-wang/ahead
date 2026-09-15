# Compiler tests

Verify that accepted schemas produce the intended descriptors and APIs, and invalid schemas fail with useful diagnostics. See [Compiler architecture](../../architecture/compiler/README.md).

[Existing tests](../../../../crates/compiler/tests) cover parsing and validation, mutation history, CLI output and emitter content.

```sh
cargo test -p ahead-compiler --locked
```

Add a small schema fixture with an assertion on the resulting descriptor, generated output or diagnostic. When the claim is that generated code typechecks or runs, use [SDK integration tests](../integration/bindings.md) as well.

Next review: map individual compiler requirements to assertions, especially error locations and generated-language negative cases.
