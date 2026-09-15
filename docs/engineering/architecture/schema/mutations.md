# Mutations

## 1. Introduction and Goals

A mutation is a named, server-visible write. The schema fixes the shape of its operations so both runtimes decode it identically, and gives it a version so that mutations queued under an older schema keep executing after the schema moves on. Without the version, a client that was offline during a deploy would push operations the server can no longer interpret.

## 3. Context and Scope

A mutation is declared as a set of *slots*, each binding a name to one operation on one model:

```
mutation AddComment {
  book    Book.create
  comment Comment.create(book: book)[]     // list slot, bound to the parent slot
  @@version(2)
  @@sequence(after: [Rename(book: comment.book)])
}
```

The compiled descriptor `{name, version, slots, sequence}` goes to the client as `schema.clientPolicies` and to the server as every retained version with an input snapshot ([Compiler / Generate](../compiler/generate.md)). On the wire an instance is `{name, version, operations:[{model, op, identity, values?}]}` ([Protocol / Push](../protocol/push.md)). Generated builders produce that shape; the server's decoder consumes it; the client's dependency derivation reads the policies.

## 5. Building Block View

**Slots.** `op` is `create`, `update` or `delete`. An update may list the fields it is allowed to patch, `Entry.update<title, note>`; without a list it may patch every non-identity field. A slot is single by default, optional with `?`, or a list with `[]`.

**Bindings.** `(relation: parentSlot)` ties a create slot to a single parent slot of the relation's target model. The server checks that each child's foreign key equals the parent's identity, so a client cannot attach a child to a parent it did not create in the same mutation.

**Version and sequence.** `@@version(n)` defaults to 1. `@@sequence(after: [Target(targetSlot: sourceSlot.path)])` declares that an instance waits for earlier queued instances of `Target` whose slot holds the record the path resolves to; how that becomes a dependency is described in [Dependencies](../client/engine/push/dependencies.md).

**Decoding on the server.** Operations are matched to slots in order by `(model, op)`; a list slot consumes every consecutive match. Failures have stable codes: an unknown mutation, a wrong shape, a missing required create field or an empty patch is `mutation.invalid`; a known field outside the allowed patch fields is `<name>.not_allowed`; a binding mismatch is `<name>.invalid` ([Server Push](../server/engine/push.md)).

**History.** Each version's input (the models and enums its slots touch, its requirements and its sequence) is snapshotted. A version may not decrease and a retained mutation may not disappear. Changing the input at the same version is refused unless the change is compatible: patch fields and enum values may grow, existing fields must be identical, and a model a `create` slot targets may not gain a non-nullable field, because old clients would send creates without it ([Compiler / Validate](../compiler/validate.md)).

Code: parsing and checks in [compiler/lib.rs](../../../../crates/compiler/src/lib.rs); history in [compiler/history.rs](../../../../crates/compiler/src/history.rs); server decoding in [server/lib.rs](../../../../crates/server/src/lib.rs) (`decode`); client policies in [client/policies.rs](../../../../crates/client/src/policies.rs).

## 6. Runtime View

Changing a mutation's input requires `@@version(n+1)`. The compiler keeps the previous snapshot, the server keeps a `nameVn` handler for it, and the client keeps its policy, so instances queued before the upgrade still decode. A batch that names a known mutation with an unregistered version is refused before any handler runs.

## 10. Quality Requirements

- **Slot shapes, bindings and sequences that do not resolve are refused at compile time.** Evidence: [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) `schema_and_mutations`, `relationships_bindings_and_dependency_metadata`, `rejects_dependency_typos`.
- **An incompatible input change at the same version is refused, a compatible one accepted, and old inputs are retained.** Evidence: [compiler/tests/history.rs](../../../../crates/compiler/tests/history.rs); [compiler/tests/cli.rs](../../../../crates/compiler/tests/cli.rs) `cli_retains_history_and_does_not_overwrite_on_break`.
- **The server decodes known fields, ignores unknown ones, and refuses disallowed patches and binding mismatches with stable codes.** Evidence: [server/tests/runtime.rs](../../../../crates/server/tests/runtime.rs).

Tests read, not executed.

## 11. Risks and Technical Debt

**Potential risk: adjacent slots with the same model and operation decode greedily.** *Condition:* a list slot is followed by another slot of the same model and operation, as in `RemoveEntries { entries Entry.delete[] maybe Entry.delete? }`. *Consequence:* the list slot takes every matching operation and the second slot can never receive one; the compiler does not warn. *Evidence:* `decode` in [server/lib.rs](../../../../crates/server/src/lib.rs); the shape appears in [fixtures/compiler/example.model](../../../../fixtures/compiler/example.model). **To confirm:** whether such declarations should be refused.

**Problem: `Model.update<>` compiles but never succeeds.** Its generated input is an empty patch, which the server refuses as `mutation.invalid`. *Evidence:* `data.is_empty()` in `decode`; [compiler/tests/compiler.rs](../../../../crates/compiler/tests/compiler.rs) compiles `Parent.update<>`.
