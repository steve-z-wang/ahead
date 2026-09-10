# model-generation

**Participants:** the `.model` definitions, the generated Dart, the generated
Backend contract and bindings, and the runtimes that execute them.

**Owns:** that the generated outputs faithfully and executably express what the
definitions declared — identities, fields, nullability, scalars, enums, lists,
relations, versions, the registry and the DDL.

**Does not own:** parser and code-generator implementation details (those are
`compiler/test/`), or anything about the wire.

```bash
conformance/tool/test.sh model-generation
```

## The shared matrix

Three emitters read one definition set, so each side can be internally
consistent and still disagree with the others. `shared-model-contract.spec.ts`
normalizes all three into one shape and compares them pairwise — the
language-neutral contract is the shared vocabulary, not the trusted answer.

| Projection | Read from |
|---|---|
| generated Dart | `dart/model_manifest.dart`, printing the assembled sync registry |
| language-neutral contract | `generated/model-contract.json` |
| generated Backend | `generatedContract` in `generated/backend/backend_contract.ts` |

```text
<Model name>: { schemaVersion, identity[], fields[] { name, type, nullable } }
type: scalar(name) | enum(name, values) | list(element scalar)
```

Models are keyed by name and fields are sorted by name: field order is not a
fact any consumer can observe — a state is a keyed object on the wire, and the
Backend emitter already sorts. Identity order is left as declared, because a
composite identity is declared in an order and that order is the declaration.
Enum values keep declaration order too.

The definitions declare **seven synced Models** — `AccountState`, `Moment`,
`ScalarSample`, `Space`, `Star`, `StarTag`, `User` — and one local-only Model,
`LocalNote`, which has no wire form and so appears in no projection.

## Evolution

`schema-evolution.spec.ts` runs the real compiler CLI twice over changed
definitions. The rule it holds is the repository's published one, and it is
about names only: a Model or a field that has once been generated may gain
company and may never leave, a rename is a removal and an addition at once, and
a refused generation leaves the previously published contract byte-for-byte on
disk. Identity, type, nullability and version evolution are not governed here —
widening the rule is a product ruling, not a test.
