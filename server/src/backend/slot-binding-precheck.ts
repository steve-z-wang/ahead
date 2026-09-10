import { LocalSyncMutationRejected, machineName } from './errors';
import { MutationDescriptor, SyncModelShape } from './model-binding';

/**
 * The act-internal consistency check slot bindings declare (spec
 * 2026-08-16-slot-bindings), at the trust boundary.
 *
 * The wire is a claim, not a fact — the client's own verifier disciplines
 * only the client — so before a resolver runs, every bound CREATE row is held
 * against the identity of the row in the slot it binds. Creates only, and
 * that scope is the wire's, not taste's: a delete carries identity alone and
 * an update's patch does not contain bound fields, so there is nothing here
 * to check for them — their relationships are verified where they always
 * were, in the resolver, against the database.
 *
 * A mismatch settles as `<mutation>.invalid`: an act that contradicts itself
 * is a malformed envelope, refused whole before anything executes.
 */
export function precheckSlotBindings(
  descriptor: MutationDescriptor,
  mutationKey: string,
  arguments_: Readonly<Record<string, unknown>>,
  models: Readonly<Record<string, SyncModelShape>>,
): void {
  for (const slot of descriptor.slots) {
    const bindings = slot.bindings;
    if (bindings === undefined || slot.operation !== 'create') continue;
    for (const binding of bindings) {
      const parent = arguments_[binding.slot];
      // The bound slot is single-cardinality by construction, so its decoded
      // argument is one operation object carrying an identity.
      const expected = identityValues(parent, models, descriptor, binding.slot);
      const rows =
        slot.cardinality === 'list'
          ? (arguments_[slot.name] as readonly unknown[])
          : arguments_[slot.name] === null
            ? []
            : [arguments_[slot.name]];
      for (const row of rows) {
        const operation = row as {
          readonly identity: Record<string, unknown>;
          readonly data: Record<string, unknown>;
        };
        for (let index = 0; index < binding.fields.length; index += 1) {
          const field = binding.fields[index];
          const actual =
            field in operation.identity
              ? operation.identity[field]
              : operation.data[field];
          if (actual === expected[index]) continue;
          throw new LocalSyncMutationRejected(
            `${machineName(mutationKey)}.invalid`,
            `mutation "${descriptor.name}" slot "${slot.name}" names a ` +
              `different "${binding.slot}" than the act carries`,
          );
        }
      }
    }
  }
}

/// The bound slot's row identity, in its Model's identity-field order — the
/// order the binding's fields were declared against.
///
/// The referents are certain: capture validated every binding at option time
/// (the bound slot exists, is single-cardinality, and its Model's identity
/// arity matches the binding's fields), so a missing slot or Model here is
/// impossible for a captured contract.
function identityValues(
  parent: unknown,
  models: Readonly<Record<string, SyncModelShape>>,
  descriptor: MutationDescriptor,
  slotName: string,
): readonly unknown[] {
  const parentSlot = descriptor.slots.find((slot) => slot.name === slotName)!;
  const model = Object.values(models).find(
    (candidate) => candidate.name === parentSlot.model,
  )!;
  const identity = (parent as { readonly identity: Record<string, unknown> })
    .identity;
  return model.identityFields.map((field) => identity[field]);
}
