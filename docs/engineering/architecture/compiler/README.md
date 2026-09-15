# Compiler

The compiler is a three-stage pipeline over `.model` files: [Parse](parse.md) produces declarations, [Validate](validate.md) checks them against the rules both runtimes enforce and against the previous published schema, and [Generate](generate.md) writes the runtime descriptors and the typed code for each language. Each stage is one module with a typed boundary: `parse` returns `Declarations`, `validate` returns `Validated`, and `generate` renders descriptors and code from it; `compile` chains the three.

- [Parse](parse.md) — Convert schema text into structured definitions.
- [Validate](validate.md) — Check types, references and mutations in the parsed definitions.
- [Generate](generate.md) — Produce runtime descriptors and typed SDK interfaces from validated definitions.
