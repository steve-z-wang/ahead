# Compiler

The compiler is a three-stage pipeline over `.model` files: [Parse](parse.md) produces declarations, [Validate](validate.md) checks them against the rules both runtimes enforce and against the previous published schema, and [Generate](generate.md) writes the runtime descriptors and the typed code for each language. The first two stages are separate functions in separate modules, `parse` and `validate`; `compile` is their composition. Generate has no module of its own: its descriptors are assembled at the end of `validate` and its emitters live in `emit`.

- [Parse](parse.md) — Convert schema text into structured definitions.
- [Validate](validate.md) — Check types, references and mutations in the parsed definitions.
- [Generate](generate.md) — Produce runtime descriptors and typed SDK interfaces from validated definitions.
