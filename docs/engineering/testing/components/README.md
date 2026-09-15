# Component tests

Verify the behavior owned by a component. Use its architecture document to identify rules and failure conditions, rather than reproducing implementation steps in the test.

- [Schema](schema.md) — Descriptor validity and model rules.
- [Protocol](protocol.md) — Shared message encoding and validation.
- [Compiler](compiler.md) — Source validation and generated output.
- [Client](client.md) — Local state and sync engine rules.
- [Server](server.md) — Backend processing rules.

Cross-component sync behavior belongs in [Simulation](../simulation/README.md); real-boundary requirements belong in [Integration](../integration/README.md).
